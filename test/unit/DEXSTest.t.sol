//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DEXSDeploy} from "../../script/DEXSDeploy.s.sol";
import {DEXSEngine} from "../../src/DEXSEngine.sol";
import {DEXStablecoin} from "../../src/DEXStablecoin.sol";
import {NetworkConfig} from "../../script/NetworkConfig.s.sol";
import {ERC20MockWETH} from "@openzeppelin/contracts/mocks/ERC20MockWETH.sol";
import {ERC20MockDUMMY} from "@openzeppelin/contracts/mocks/ERC20MockDUMMY.sol";

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

    uint256 public constant COLLATERAL_AMOUNT = 10e18;
    uint256 public constant STARTING_ETH_COLLATERAL_ALICE = 10e18;

    address[] public tokenAddressesTest;
    address[] public priceFeedAddressesTest;

    function setUp() external {
        deployer = new DEXSDeploy();
        (stablecoin, engine, networkConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = networkConfig.activeNetworkProfiler();
        if (block.chainid == 31337) {
            vm.deal(ALICE, STARTING_ETH_COLLATERAL_ALICE);
        }
        ERC20MockWETH(weth).mint(ALICE, STARTING_ETH_COLLATERAL_ALICE);
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

    modifier depositCollateral_deposit() {
        vm.startPrank(ALICE);
        ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT); //engine can spend ALICE's tokens
        engine.depositCollateral(weth, COLLATERAL_AMOUNT);
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

    //TODO: make it network agnostic

    function testConversion_TokenToUsdc() public {
        uint256 ethWEI = 15e18; // mocking ET price 1000$ >> total eth amount $ must be 15000$
        uint256 usdExpectedWEI = 15000e18;
        uint256 usdActualValueWEI = engine.tokenToUsd(weth, ethWEI);
        assertEq(usdExpectedWEI, usdActualValueWEI);
    }

    function testConversion_UsdToToken() public {
        uint256 dollarWEI = 1000e18; // let's convert 10$
        uint256 tokenExpectedWEIWith8DecimalsPrecision = 1; //mocking eth price 1000$
        uint256 tokenActualWEI = engine.usdToToken(dollarWEI, weth);
        assertEq(tokenExpectedWEIWith8DecimalsPrecision, tokenActualWEI);
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

    function testDepositCollateral_CollateralSuccesfullyDeposited() public depositCollateral_deposit {
        uint256 userBalance = stablecoin.balanceOf(ALICE);
        assertEq(userBalance, 0);
    }

    function testDepositCollateral_AccountInfoAfterDepositing() public depositCollateral_deposit {
        (uint256 dexs, uint256 collateralUSD) = engine.getAccountInformation(ALICE);
        assertEq(dexs, 0);
        assertEq(STARTING_ETH_COLLATERAL_ALICE, engine.usdToToken(collateralUSD, weth));
    }
}
