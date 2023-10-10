//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Mock} from "./AggregatorV3Mock.sol";

contract ERC20MockPricePlummeting is ERC20Burnable, Ownable {
    address aggregator;

    constructor(address _aggregator) ERC20("DEXStablecoin", "DEXS") {
        aggregator = _aggregator;
    }

    function burn(uint256 _amount) public override onlyOwner {
        AggregatorV3Mock(aggregator).updateAnswer(0);
        super.burn(_amount);
    }

    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        _mint(to, amount);
        return true;
    }
}
