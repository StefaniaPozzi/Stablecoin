//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract ERC20MockFailingTransfer is ERC20Burnable, Ownable {
    constructor(address sender) ERC20("DEXStablecoin", "DEXS") {
        _mint(sender, 10000e18);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        return false;
    }
}
