//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DEXSDeploy} from "../../script/DEXSDeploy.s.sol";
import {DEXSEngine} from "../../src/DEXSEngine.sol";
import {DEXStablecoin} from "../../src/DEXStablecoin.sol";
import {NetworkConfig} from "../../script/NetworkConfig.s.sol";
import {ERC20MockWETH} from "@openzeppelin/contracts/mocks/ERC20MockWETH.sol";

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

    uint256 public constant COLLATERAL_AMOUNT = 1 ether;
    uint256 public constant STARTING_ETH_COLLATERAL_ALICE = 10 ether;

    function setUp() external {
        deployer = new DEXSDeploy();
        (stablecoin, engine, networkConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = networkConfig.activeNetworkProfiler();
        ERC20MockWETH(weth).mint(ALICE, STARTING_ETH_COLLATERAL_ALICE);
    }

    //TODO: make it network agnostic
    function testConvertToUsdc() public {
        uint256 ethAmountInWei = 15e18; // mocking ET price 1000$ >> total eth amount $ must be 15000$
        uint256 usdExpectedValue = 15000e18;
        uint256 usdActualValue = engine.convertToUsdc(weth, ethAmountInWei);
        assertEq(usdExpectedValue, usdActualValue);
    }

    function testRevertWhenCollateralIsZero() public {
        vm.startPrank(ALICE);
        //first the engine must have some collateral
        // ERC20MockWETH(weth).approve(address(engine), COLLATERAL_AMOUNT);
        vm.expectRevert(DEXSEngine.DEXSEngine_NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}
