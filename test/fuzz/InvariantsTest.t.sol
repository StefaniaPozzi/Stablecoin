//SPDX-License-Identifier:MIT

pragma solidity 0.8.18;

/**
 * Which are the properties that always hold true?
 * 1. DEXS must always be less than collateral
 * 2. Getters must never revert
 */

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DEXSDeploy} from "../../script/DEXSDeploy.s.sol";
import {DEXSEngine} from "../../src/DEXSEngine.sol";
import {DEXStablecoin} from "../../src/DEXStablecoin.sol";
import {NetworkConfig} from "../../script/NetworkConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Handler} from "../../test/fuzz/Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DEXSDeploy deployer;
    DEXSEngine engine;
    DEXStablecoin stablecoin;
    NetworkConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        DEXSDeploy deployer = new DEXSDeploy();
        (stablecoin, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkProfiler();
        handler = new Handler (engine, stablecoin);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreDEXSThanCollateral() public view {
        uint256 totalSupply = stablecoin.totalSupply();
        uint256 totalCollateralWeth = IERC20(weth).balanceOf(address(engine)); //amount of weth sent to the engine
        uint256 totalCollateralWbtc = IERC20(wbtc).balanceOf(address(engine));
        uint256 totalCollateralWethInUSD = engine.tokenToUsd(weth, totalCollateralWeth);
        uint256 totalCollateralWbtcInUSD = engine.tokenToUsd(wbtc, totalCollateralWbtc);
        uint256 totalCollateral = totalCollateralWethInUSD + totalCollateralWbtcInUSD;

        assert(totalCollateral > totalSupply);
    }
}
