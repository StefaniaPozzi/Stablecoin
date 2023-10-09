//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DEXSDeploy} from "../../script/DEXSDeploy.s.sol";
import {DEXSEngine} from "../../src/DEXSEngine.sol";
import {DEXStablecoin} from "../../src/DEXStablecoin.sol";
import {NetworkConfig} from "../../script/NetworkConfig.s.sol";
import {ERC20MockWETH} from "@openzeppelin/contracts/mocks/ERC20MockWETH.sol";
import {ERC20MockDUMMY} from "@openzeppelin/contracts/mocks/ERC20MockDUMMY.sol";
import {ERC20MockFailingMint} from "../mocks/ERC20MockFailingMint.sol";
import {ERC20MockFailingTransfer} from "../mocks/ERC20MockFailingTransfer.sol";
import {ERC20MockPricePlummeting} from "../mocks/ERC20MockPricePlummeting.sol";
import {AggregatorV3Mock} from "../mocks/AggregatorV3Mock.sol";

contract DEXSTest is Test {
    DEXSEngine public engine;
    DEXStablecoin public stablecoin;
    NetworkConfig public networkConfig;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    DEXSDeploy private deployer;

    address public ALICE = makeAddr("alice");
    address public LIQUIDATOR = makeAddr("bob");

    uint256 public constant COLLATERAL_AMOUNT_ETH = 1 ether;
    uint256 public constant SAFE_MINTING_DEXS_USDWEI = 500e18; //USD WEI

    uint256 public constant PRECISION8 = 1e8;
    uint256 public constant PRECISION10 = 1e10;
    uint256 public constant PRECISION18 = 1e18;
    uint256 public constant ORIGINAL_ETH_PRICE = 1000e18;
    int256 public constant PLUMMETED_ETH_PRICE = 18e8;

    address[] public tokenAddressesTest;
    address[] public priceFeedAddressesTest;

    event DEXSEngine_CollateralAdded(address indexed user, address indexed token, uint256 indexed amount);
    event DEXSEngine_CollateralRedeemed(
        address indexed from, address indexed to, address indexed token, uint256 amount
    );

    function setUp() external {
        deployer = new DEXSDeploy();
        (stablecoin, engine, networkConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = networkConfig.activeNetworkProfiler();
        if (block.chainid == 31337) {
            vm.deal(ALICE, COLLATERAL_AMOUNT_ETH);
        }
        ERC20MockWETH(weth).mint(ALICE, COLLATERAL_AMOUNT_ETH);
    }

    function setUp_Constructor(bool isSync) public returns (DEXSEngine) {
        tokenAddressesTest.push(wbtc);
        if (isSync) {
            tokenAddressesTest.push(weth);
        }
        priceFeedAddressesTest.push(btcUsdPriceFeed);
        priceFeedAddressesTest.push(ethUsdPriceFeed);
        return new DEXSEngine(tokenAddressesTest, priceFeedAddressesTest, address(stablecoin));
    }

    modifier depositCollateral() {
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH); //engine can spend ALICE's tokens
        engine.depositCollateral(weth, COLLATERAL_AMOUNT_ETH);
        _;
        vm.stopPrank();
    }

    modifier mintHalfCollateral() {
        vm.startPrank(ALICE);
        uint256 dexToMint = engine.tokenToUsd(weth, SAFE_MINTING_DEXS_USDWEI);
        engine.mintDEXS(dexToMint);
        _;
        vm.stopPrank();
    }

    modifier depositAndMintHalfCollateral() {
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH);
        engine.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, SAFE_MINTING_DEXS_USDWEI);
        _;
        vm.stopPrank();
    }

    modifier depositAndmintHalfCollateralSetLiquidator() {
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH);
        engine.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, SAFE_MINTING_DEXS_USDWEI);
        vm.stopPrank();
        ERC20MockWETH(weth).mint(LIQUIDATOR, COLLATERAL_AMOUNT_ETH);
        vm.startPrank(LIQUIDATOR);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH); //the collateral contract allows the engine to use the collateral
        engine.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, SAFE_MINTING_DEXS_USDWEI);
        stablecoin.approve(address(engine), SAFE_MINTING_DEXS_USDWEI);
        _;
    }

    function testConstructorRevertIfTokenLengthDiffersFromPriceFeedLength() public {
        vm.expectRevert(DEXSEngine.DEXSEngine_TokensPriceFeedArrayMismatched.selector);
        setUp_Constructor(false);
    }

    function testConstructor_FillsInStateVariables() public view {
        address stablecoinFromEngine = engine.getStablecoinAddress();
        assert(stablecoinFromEngine == address(stablecoin));
    }

    function testConstructor_PriceFeedIsFilled() public {
        //set up 1: deploy the constructor inside the test
        DEXSEngine engineTest = setUp_Constructor(true);
        address priceFeedTest = engineTest.getPriceFeed(wbtc);
        assert(btcUsdPriceFeed == priceFeedTest);
    }

    function testConstructor_IsSupportedCollateral() public view {
        //set up 2 -> use the deployed contract from the deployer
        address[] memory supportedCollateral = engine.getSupportedCollateral();
        assert(supportedCollateral[0] == weth);
        assert(supportedCollateral[1] == wbtc);
    }

    function testDepositCollateral_RevertWhenCollateralIsZero() public {
        vm.startPrank(ALICE);
        vm.expectRevert(DEXSEngine.DEXSEngine_NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testDepositCollateral_RevertIfUnapprovedCollateral() public {
        ERC20MockDUMMY dummyToken = new ERC20MockDUMMY(ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(DEXSEngine.DEXSEngine_TokenNotSupportedAsCollateral.selector);
        engine.depositCollateral(address(dummyToken), 1);
    }

    //TODO reentrancy test

    function testDepositCollateral_CollateralSuccesfullyDeposited() public depositCollateral {
        uint256 userBalance = stablecoin.balanceOf(ALICE);
        assertEq(userBalance, 0);
    }

    function ethWeiToEth8Decimals(uint256 ethWei) public returns (uint256 decimals) {
        decimals = ethWei / PRECISION10; //wei is e18, the results are always in 8 decimals precision
    }

    function testDepositCollateral_AccountInfoAfterDepositing() public depositCollateral {
        (uint256 dexs, uint256 collateralUSD) = engine.getAccountInformation(ALICE);
        uint256 usdToToken = engine.usdToToken(collateralUSD, weth);
        assertEq(dexs, 0);
        assertEq(COLLATERAL_AMOUNT_ETH, usdToToken);
    }

    function testDepositCollateral_emitsEventWhenDeposit() public {
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH); //engine can spend ALICE's tokens
        //the order is important (after approve)
        vm.expectEmit(true, true, false, false, address(engine));
        emit DEXSEngine_CollateralAdded(ALICE, weth, COLLATERAL_AMOUNT_ETH);
        engine.depositCollateral(weth, COLLATERAL_AMOUNT_ETH);
        vm.stopPrank();
    }

    function testDepositCollateral_TransferFailed() public {}

    function testMintDEXS_MintsCorrectly() public depositAndMintHalfCollateral {
        uint256 expectedUsdOrDscMinted = 500e18;
        uint256 actualUsdOrDscMinted = engine.getUsdMinted(ALICE);
        assertEq(expectedUsdOrDscMinted, actualUsdOrDscMinted);
    }

    function testMintDEXS_RevertsIfHealthFactorIsbroken() public {
        vm.startPrank(ALICE);
        uint256 dexToMint = engine.tokenToUsd(weth, COLLATERAL_AMOUNT_ETH) / PRECISION10;
        // the result was given in WEI: we want to get 8 decimal precision for DEXS and $
        vm.expectRevert(DEXSEngine.DEXSEngine_HealthFactorIsBelowThreshold.selector);
        engine.mintDEXS(dexToMint);
        vm.stopPrank();
    }

    function testMintDEXS_RevertsIfMintFails() public {
        tokenAddressesTest = [weth];
        priceFeedAddressesTest = [ethUsdPriceFeed];
        ERC20MockFailingMint erc20FailingMock = new ERC20MockFailingMint();
        DEXSEngine engineMock = new DEXSEngine(tokenAddressesTest, priceFeedAddressesTest, address(erc20FailingMock));
        erc20FailingMock.transferOwnership(address(engineMock)); //ownable!

        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engineMock), COLLATERAL_AMOUNT_ETH); // pretending alice is depositing some collateral
        vm.expectRevert(DEXSEngine.DEXSEngine_MintFailed.selector);
        engineMock.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, SAFE_MINTING_DEXS_USDWEI);
        vm.stopPrank();
    }

    function testMintDEXS_RevertsIfMintingZeroDexs() public {
        vm.expectRevert(DEXSEngine.DEXSEngine_NeedsMoreThanZero.selector);
        engine.mintDEXS(0);
    }

    /*
    * -------------------------------------------------------- 2. REDEEM & BURN COLLATERAL -------------------------------------------------------- *
    */
    //first test must always be the succesfull frame
    function testBurn_SuccesfullyBurnDEXS() public depositAndMintHalfCollateral {
        uint256 startingUserDEXSAmount = stablecoin.balanceOf(ALICE);
        stablecoin.approve(address(engine), startingUserDEXSAmount); // NOT CLEAR stablecoin has to approve the burning amount -> otherwise ERROR ERC20: insufficient allowance
        engine.burnDEXS(startingUserDEXSAmount);
        uint256 endingUserDEXSAmount = stablecoin.balanceOf(ALICE);
        assertEq(endingUserDEXSAmount, 0);
    }

    function testBurn_RevertIfAmountIsZero() public depositAndMintHalfCollateral {
        vm.expectRevert(DEXSEngine.DEXSEngine_NeedsMoreThanZero.selector);
        engine.burnDEXS(0);
    }

    function testBurn_RevertIfAmountExceedMintedDEXS() public depositAndMintHalfCollateral {
        vm.expectRevert();
        engine.burnDEXS(COLLATERAL_AMOUNT_ETH);
    }

    function testRedeem_RedeemsCorrectly() public depositCollateral {
        engine.redeemCollateral(weth, COLLATERAL_AMOUNT_ETH);
        uint256 endingUserCollateral = engine.getCollateralDeposited(ALICE, weth);
        uint256 endingUserWethBalance = ERC20MockWETH(weth).balanceOf(ALICE);
        assertEq(endingUserCollateral, 0); //engine does not have more ALICE eth
        assertEq(endingUserWethBalance, COLLATERAL_AMOUNT_ETH); //the money go all back inside the weth contract
    }

    //redeem can fail if we want to withdraw the locked collateral
    function testRedeem_RevertIfTransferFails() public {
        ERC20MockFailingTransfer stablecoinMocked = new ERC20MockFailingTransfer(ALICE);
        tokenAddressesTest = [address(stablecoinMocked)];
        priceFeedAddressesTest = [ethUsdPriceFeed];
        DEXSEngine engineMocked = new DEXSEngine(tokenAddressesTest, priceFeedAddressesTest, address(stablecoinMocked));
        stablecoinMocked.transferOwnership(address(engineMocked)); //the engine contract, not this test contract is now the owner of
        vm.startPrank(ALICE);
        ERC20MockFailingTransfer(address(stablecoinMocked)).approve(address(engineMocked), COLLATERAL_AMOUNT_ETH);
        engineMocked.depositCollateral(address(stablecoinMocked), COLLATERAL_AMOUNT_ETH);
        vm.expectRevert(DEXSEngine.DEXSEngine_TransferFailed.selector);
        engineMocked.redeemCollateral(address(stablecoinMocked), COLLATERAL_AMOUNT_ETH);
        vm.stopPrank();
    }

    function testRedeem_RevertIfAmountIsZero() public {
        vm.startPrank(ALICE);
        vm.expectRevert(DEXSEngine.DEXSEngine_NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    /*
    * -------------------------------------------------------- 3. LIQUIDATION -------------------------------------------------------- *
    */

    /**
     * Price plummeting simulation: eth value will fluctuate from 1000e18 $WEI to 0 $WEI to 18 $WEI
     */
    function testLiquidation_NotImprovingUserHealthFactor() public {
        //usual arranging when we want to simulate an even that happens inside the token methods
        //1. Invent the token with problems
        //2. Feed a new engine with it
        //3. Transfer ownership of the sick token to the new engine contract
        ERC20MockPricePlummeting stablecoinMock = new ERC20MockPricePlummeting(ethUsdPriceFeed);
        tokenAddressesTest = [weth];
        priceFeedAddressesTest = [ethUsdPriceFeed];
        DEXSEngine engineMock = new DEXSEngine(tokenAddressesTest, priceFeedAddressesTest, address(stablecoinMock));
        stablecoinMock.transferOwnership(address(engineMock));

        //the user deposits and mints as always
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engineMock), COLLATERAL_AMOUNT_ETH); //first alice says that the spender can spend her money on her behalf, then she deposit
        engineMock.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, COLLATERAL_AMOUNT_ETH / 2); //TODO
        vm.stopPrank();

        //the liquidator gets some weth, deposits and mints
        ERC20MockWETH(weth).mint(LIQUIDATOR, COLLATERAL_AMOUNT_ETH);

        vm.startPrank(LIQUIDATOR);
        ERC20MockWETH(weth).approve(address(engineMock), COLLATERAL_AMOUNT_ETH * 2);
        engineMock.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH * 2, COLLATERAL_AMOUNT_ETH);

        //the liquidator's health factor will be broken if the price plummets again
        AggregatorV3Mock(ethUsdPriceFeed).updateAnswer(18e8); //this will trigger the revert

        vm.expectRevert(DEXSEngine.DEXSEngine_HealthFactorNotImproved.selector);
        engineMock.liquidate(weth, ALICE, SAFE_MINTING_DEXS_USDWEI); //adjust
        vm.stopPrank();
    }

    function testLiquidation_RevertIfHealthFactorIsValid() public depositAndmintHalfCollateralSetLiquidator {
        vm.expectRevert(DEXSEngine.DEXSEngine_CannotLiquidate.selector);
        engine.liquidate(weth, ALICE, SAFE_MINTING_DEXS_USDWEI);
    }

    function setUpLiquidation() public {
        //AlICE mints when weth == 1000$
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH);
        engine.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, SAFE_MINTING_DEXS_USDWEI);
        vm.stopPrank();

        //BOB mints when weth == 500$
        int256 plummetingEthPrice = 500e8;
        AggregatorV3Mock(ethUsdPriceFeed).updateAnswer(plummetingEthPrice);
        ERC20MockWETH(weth).mint(LIQUIDATOR, COLLATERAL_AMOUNT_ETH * 2);

        vm.startPrank(LIQUIDATOR);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH * 2); //the weth contract allows the engine to use the minted weth
        engine.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH * 2, SAFE_MINTING_DEXS_USDWEI);
        stablecoin.approve(address(engine), SAFE_MINTING_DEXS_USDWEI); //the stablecoin contract allows the engine to use the minted dexs
        vm.stopPrank();
    }

    function testLiquidation_SuccesfulLiquidation() public {
        setUpLiquidation();
        vm.startPrank(LIQUIDATOR);
        engine.liquidate(weth, ALICE, SAFE_MINTING_DEXS_USDWEI);
        vm.stopPrank();
    }

    function testLiquidation_HealthFactorImproves() public {}

    function testLiquidation_UserHealthFactorPlummets() public {
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT_ETH);
        engine.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, SAFE_MINTING_DEXS_USDWEI);
        uint256 originalHealthFactor = engine.healthFactor(ALICE);
        console.log("1--", originalHealthFactor); //1000e18
        vm.stopPrank();

        //BOB mints with weth == 12$ -> COLLATERAL_AMOUNT_ETH = 12*1e18
        //he has good Health Factor, alice does not
        int256 plummetingEthPrice = 12e8;
        AggregatorV3Mock(ethUsdPriceFeed).updateAnswer(plummetingEthPrice);
        uint256 plummetedHealthFactor = engine.healthFactor(ALICE);
        console.log("2--", plummetedHealthFactor);

        assertGt(originalHealthFactor, plummetedHealthFactor);
    }

    /*
    * -------------------------------------------------------- 4. UTILS & STATE -------------------------------------------------------- *
    */

    function testUtils_CollaterlUSD() public depositCollateral {
        uint256 collateralUSD = engine.getCollateralUSDWEI(ALICE);
        assertEq(ORIGINAL_ETH_PRICE, collateralUSD);
    }

    //TODO: make it network agnostic
    function testUtils_TokenToUsd() public {
        // mocking ET price 1000$ >> total eth amount $ must be 1000$
        uint256 usdExpectedWEI = 1000e18;
        uint256 usdActualValueWEI = engine.tokenToUsd(weth, COLLATERAL_AMOUNT_ETH);
        assertEq(usdExpectedWEI, usdActualValueWEI);
    }

    function testUtils_UsdToTokenT() public {
        uint256 tokenExpectedWEI = 1 * PRECISION18; //mocking eth price 1000$
        uint256 tokenActualWEI = engine.usdToToken(1 * ORIGINAL_ETH_PRICE, engine.getWethAddress());
        assertEq(tokenExpectedWEI, tokenActualWEI);
    }

    function testUtils_HealthFactorWithoutMinting() public depositCollateral {
        uint256 actualHealthFactor = engine.healthFactor(ALICE);
        console.log(actualHealthFactor);
        assertEq(actualHealthFactor, type(uint256).max);
    }

    function testUtils_AccountInformationDepositAndMint() public depositAndMintHalfCollateral {
        (uint256 dexsOwned, uint256 collateralUSDWEI) = engine.getAccountInformation(ALICE);
        console.log(dexsOwned);
        console.log(collateralUSDWEI);
    }

    function testUtils_AccountInformationDeposit() public depositCollateral {
        (uint256 dexsOwned, uint256 collateralUSDWEI) = engine.getAccountInformation(ALICE);
        console.log(dexsOwned);
        console.log(collateralUSDWEI);
    }

    //this is not ok
    function testUtils_HealthFactorCalculationIs1e18() public depositAndMintHalfCollateral {
        uint256 healthFactorExpected = 1e18; //1000e18 (500e18) USD == 1e18 (5e17) ether
        uint256 healthFactorActual = engine.healthFactor(ALICE);
        assertEq(healthFactorActual, healthFactorExpected); //NOT CLEAR
    }

    function testUtils_TokenToUSDChangesWithPrice() public depositAndMintHalfCollateral {
        assertEq(engine.tokenToUsd(weth, COLLATERAL_AMOUNT_ETH), ORIGINAL_ETH_PRICE);
        uint256 expectedPlummetedPrice = 18e18;
        AggregatorV3Mock(ethUsdPriceFeed).updateAnswer(PLUMMETED_ETH_PRICE);
        assertEq(engine.tokenToUsd(weth, COLLATERAL_AMOUNT_ETH), expectedPlummetedPrice);
    }

    function testUtils_UsdToTokenChangesWithPrice() public {
        //todo
    }

    function testUtils_AccountInfoChangesWithPrice() public depositAndMintHalfCollateral {
        (uint256 dexsOwned, uint256 collateralUSDWEIBefore) = engine.getAccountInformation(ALICE);
        AggregatorV3Mock(ethUsdPriceFeed).updateAnswer(PLUMMETED_ETH_PRICE);
        uint256 collateralUSDWEIAfterExpected = uint256(PLUMMETED_ETH_PRICE) * PRECISION10;
        (, uint256 collateralUSDWEIAfter) = engine.getAccountInformation(ALICE);
        assertEq(collateralUSDWEIBefore, ORIGINAL_ETH_PRICE); //1000e18
        assertEq(collateralUSDWEIAfter, collateralUSDWEIAfterExpected); //18e18
        assertEq(dexsOwned, SAFE_MINTING_DEXS_USDWEI); //5e17
    }

    function testUtils_getWethAddressEqualsNetworkAddress() public {
        address wethAddress = engine.getWethAddress();
        console.log(wethAddress);
        console.log(weth);
        assertEq(wethAddress, weth);
    }
}
