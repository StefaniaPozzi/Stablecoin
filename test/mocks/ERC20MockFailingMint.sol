//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ERC20MockFailingMint is ERC20Burnable, Ownable {
    error DecentralizedStablecoin_AddressNotValid();

    constructor() ERC20("DEXStablecoin", "DEXS") {}

    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        if (to == address(0)) {
            revert DecentralizedStablecoin_AddressNotValid();
        }
        _mint(to, amount);
        return false;
    }
}
