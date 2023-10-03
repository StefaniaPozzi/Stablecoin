//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DEXStablecoin
 * @author Stefania Pozzi
 * Collaterall: ETH, BTC
 * Minting-burning: Algorithmic (DEXSEngine)
 * Relative stability: USD
 */

contract DEXStablecoin is ERC20Burnable, Ownable {
    error DEXStablecoin_BurningNegativeAmount();
    error DEXStablecoin_NotEnoughBurnableTokens();
    error DEXStablecoin_TryingToMintToAddressZero();
    error DEXStablecoin_MintingNegativeAmount();

    constructor() ERC20("DEXStablecoin", "DEXS") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DEXStablecoin_BurningNegativeAmount();
        }
        if (balance < _amount) {
            revert DEXStablecoin_NotEnoughBurnableTokens();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) public onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DEXStablecoin_TryingToMintToAddressZero();
        }
        if (_amount <= 0) {
            revert DEXStablecoin_MintingNegativeAmount();
        }
        _mint(_to, _amount);
        return true;
    }
}
