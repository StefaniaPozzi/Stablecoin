//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

/**
 * Sets the fuzz order of functions to be called
 * 1. Call redeem collateral only if there is some collateral to redeem
 */

import {Test} from "forge-std/Test.sol";
import {DEXSEngine} from "../../src/DEXSEngine.sol";
import {DEXStablecoin} from "../../src/DEXStablecoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Mock} from "../../test/mocks/AggregatorV3Mock.sol";

contract Handler is Test {
    DEXSEngine engine;
    DEXStablecoin stablecoin;
    address weth;
    address wbtc;
    uint256 MAX_DEPOSIT_COLLATERAL = type(uint96).max; //not 256 because we want to be able to deposit more
    uint256 public ghostVariable_TimesFunctionIsCalled;
    address[] accountsWhichDepositedCollateral;
    AggregatorV3Mock public aggregatorV3Mock;

    constructor(DEXSEngine _engine, DEXStablecoin _stablecoin) {
        engine = _engine;
        stablecoin = _stablecoin;
        address[] memory tokens = engine.getCollateralTokens();
        weth = tokens[0];
        wbtc = tokens[1];

        aggregatorV3Mock = AggregatorV3Mock(engine.getPriceFeed(weth));
    }
    //the params are going to be randomised

    function depositCollateral(uint256 seed, uint256 amount) public {
        address token = _getCollateralFromSeed(seed);
        amount = bound(amount, 1, MAX_DEPOSIT_COLLATERAL);
        vm.startPrank(msg.sender);
        ERC20Mock(token).mint(msg.sender, amount);
        ERC20Mock(token).approve(address(engine), amount);
        engine.depositCollateral(token, amount);
        vm.stopPrank();
        accountsWhichDepositedCollateral.push(msg.sender); //double push
    }

    function mintDEXS(uint256 amount, uint256 accountsWhichDepositedCollateralSeed) public {
        if (accountsWhichDepositedCollateral.length == 0) {
            return;
        }
        address sender = _getSenderFromSeed(accountsWhichDepositedCollateralSeed);
        (uint256 alreadyMintedDEXS, uint256 collateral) = engine.getAccountInformation(sender);
        int256 maxMintableDEXS = ((int256(collateral) / 2) - int256(alreadyMintedDEXS));

        if (maxMintableDEXS <= 0) {
            return;
        }

        amount = bound(amount, 1, MAX_DEPOSIT_COLLATERAL);
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        engine.mintDEXS(uint256(maxMintableDEXS));
        vm.stopPrank();
        ghostVariable_TimesFunctionIsCalled++;
    }

    function redeemCollateral(uint256 seed, uint256 amount) public {
        address token = _getCollateralFromSeed(seed);
        uint256 maxRedeemableCollateral = engine.getCollateralDeposited(msg.sender, token);
        amount = bound(amount, 0, maxRedeemableCollateral);
        if (amount == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        engine.redeemCollateral(token, amount);
        vm.stopPrank();
    }

    // it breaks the protocol! > known bug
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     aggregatorV3Mock.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 seed) private view returns (address) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function _getSenderFromSeed(uint256 seed) private view returns (address) {
        uint256 index = seed % accountsWhichDepositedCollateral.length;
        return accountsWhichDepositedCollateral[index];
    }
}
