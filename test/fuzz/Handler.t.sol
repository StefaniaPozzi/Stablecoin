//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

/**
 * Sets the fuzz order of functions to be called
 * 1. Call redeem collateral only if there is some collateral to redeem
 */

import {Test} from "forge-std/Test.sol";
import {DEXSEngine} from "../../src/DEXSEngine.sol";
import {DEXStablecoin} from "../../src/DEXStablecoin.sol";

contract Handler is Test {
    DEXSEngine engine;
    DEXStablecoin stablecoin;
    address weth;
    address wbtc;

    constructor(DEXSEngine _engine, DEXStablecoin _stablecoin) {
        engine = _engine;
        stablecoin = _stablecoin;
        address[] memory tokens = engine.getCollateralTokens();
        weth = tokens[0];
        wbtc = tokens[1];
    }
    //the params are going to be randomised

    function depositCollateral(address token, uint256 amount) public {
        engine.depositCollateral(token, amount);
    }

    function _getCollateralFromSeed(uint256 seed) private view returns (address) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
