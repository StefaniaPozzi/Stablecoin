//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DEXSDeploy} from "../../script/DEXSDeploy.s.sol";
import {DEXSEngine} from "../../src/DEXSEngine.sol";
import {DEXStablecoin} from "../../src/DEXStablecoin.sol";
import {NetworkConfig} from "../../script/NetworkConfig.s.sol";
import {ERC20MockWETH} from "@openzeppelin/contracts/mocks/ERC20MockWETH.sol";
import {ERC20MockDUMMY} from "@openzeppelin/contracts/mocks/ERC20MockDUMMY.sol";
import {ERC20MockFailing} from "../mocks/ERC20MockFailing.sol";

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

    uint256 public constant COLLATERAL_AMOUNT_ETH = 1 ether;
    uint256 public constant STARTING_COLLATERAL_ETH_ALICE = 1 ether;
    uint256 public constant ETHPRICEinUSDWEI = 1000e18;
    uint256 public constant PRECISION8 = 1e8;
    uint256 public constant PRECISION10 = 1e10;
    uint256 public constant PRECISION18 = 1e18;

    address[] public tokenAddressesTest;
    address[] public priceFeedAddressesTest;

    event DEXSEngine_CollateralAdded(address indexed user, address indexed token, uint256 indexed amount);

    function setUp() external {
        deployer = new DEXSDeploy();
        (stablecoin, engine, networkConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = networkConfig.activeNetworkProfiler();
        if (block.chainid == 31337) {
            vm.deal(ALICE, STARTING_COLLATERAL_ETH_ALICE);
        }
        ERC20MockWETH(weth).mint(ALICE, STARTING_COLLATERAL_ETH_ALICE);
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
        vm.stopPrank();
        _;
    }

    modifier mintHalfCollateral() {
        vm.startPrank(ALICE);
        uint256 dexToMint = engine.tokenToUsd(weth, COLLATERAL_AMOUNT_ETH) / PRECISION10;
        // the result was given in WEI: we want to get 8 decimal precision for DEXS and $
        engine.mintDEXS(dexToMint / 2);
        vm.stopPrank();
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
        assertEq(STARTING_COLLATERAL_ETH_ALICE, usdToToken);
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

    function testMintDEXS_MintsCorrectly() public depositCollateral mintHalfCollateral {
        uint256 expectedUsdOrDscMinted = 500e8; // to be inside the safe threshold (1/4)
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

    function testMintDEXS_RevertsIfMintfails() public {
        tokenAddressesTest = [weth];
        priceFeedAddressesTest = [ethUsdPriceFeed];
        ERC20MockFailing erc20FailingMock = new ERC20MockFailing();
        DEXSEngine engineMock = new DEXSEngine(tokenAddressesTest, priceFeedAddressesTest, address(erc20FailingMock));
        erc20FailingMock.transferOwnership(address(engineMock)); //ownable!

        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engineMock), COLLATERAL_AMOUNT_ETH); // pretending alice is depositing some collateral
        vm.expectRevert(DEXSEngine.DEXSEngine_MintFailed.selector);
        engineMock.depositCollateralAndMint(weth, COLLATERAL_AMOUNT_ETH, 100e18);
        vm.stopPrank();
    }

    function testMintDEXS_RevertsIfMintingZeroDexs() public {
        vm.expectRevert(DEXSEngine.DEXSEngine_NeedsMoreThanZero.selector);
        engine.mintDEXS(0);
    }

    /*
    * -------------------------------------------------------- 4. UTILS & STATE -------------------------------------------------------- *
    */

    function testUtils_CollaterlUSD() public depositCollateral {
        uint256 collateralUSD = engine.getCollateralUSDWEI(ALICE);
        assertEq(ETHPRICEinUSDWEI, collateralUSD);
    }

    //TODO: make it network agnostic
    function testUtils_TokenToUsd() public {
        // mocking ET price 1000$ >> total eth amount $ must be 1000$
        uint256 usdExpectedWEI = 1000e18;
        uint256 usdActualValueWEI = engine.tokenToUsd(weth, COLLATERAL_AMOUNT_ETH);
        assertEq(usdExpectedWEI, usdActualValueWEI);
    }

    function testUtils_UsdToToken() public {
        uint256 tokenExpectedWEI = 1 * PRECISION18; //mocking eth price 1000$
        uint256 tokenActualWEI = engine.usdToToken(1 * ETHPRICEinUSDWEI, weth);
        assertEq(tokenExpectedWEI, tokenActualWEI);
    }

    function testUtils_HealthFactorWithoutMinting() public depositCollateral {
        uint256 actualHealthFactor = engine.healthFactor(ALICE);
        assertEq(actualHealthFactor, type(uint256).max);
    }

    function testUtils_AccountInformation() public depositCollateral mintHalfCollateral {
        (uint256 dexsOwned, uint256 collateralUSDWEI) = engine.getAccountInformation(ALICE);
        console.log(dexsOwned);
        console.log(collateralUSDWEI);
    }

    function testUtils_HealthFactorCalculator() public depositCollateral mintHalfCollateral {
        (uint256 dexsOwned, uint256 collateralUSDWEI) = engine.getAccountInformation(ALICE);
        uint256 reducedMinimumCollateralActual = collateralUSDWEI / 2;
        uint256 reducedMinimumCollateralExpected = 500e18;
        uint256 healthFactorExpected = 1e18;
        uint256 healthFactorActual = engine.healthFactor(ALICE);
        assertEq(reducedMinimumCollateralActual, reducedMinimumCollateralExpected);
        assertEq(healthFactorActual, healthFactorExpected);
    }
}
