//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Script, console} from "forge-std/Script.sol";
import {ERC20MockWETH} from "@openzeppelin/contracts/mocks/ERC20MockWETH.sol";
import {ERC20MockWBTC} from "@openzeppelin/contracts/mocks/ERC20MockWBTC.sol";
import {AggregatorV3Mock} from "../test/mocks/AggregatorV3Mock.sol";

contract NetworkConfig is Script {
    uint8 public constant DECIMALS = 8;
    int256 public constant BTC_USD_PRICE = 2000e8;
    int256 public constant ETH_USD_PRICE = 1000e8;

    struct NetworkProfiler {
        address ethUsdPriceFeed;
        address btcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    NetworkProfiler public activeNetworkProfiler;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkProfiler = getSepoliaNetworkProfiler();
        } else {
            activeNetworkProfiler = getOrCreatAnvilProfiler();
        }
    }

    function getSepoliaNetworkProfiler() public view returns (NetworkProfiler memory) {
        return NetworkProfiler({
            ethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            btcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY_METAMASK")
        });
    }

    function getOrCreatAnvilProfiler() public returns (NetworkProfiler memory) {
        if (activeNetworkProfiler.ethUsdPriceFeed != address(0)) {
            return activeNetworkProfiler;
        }
        vm.startBroadcast();

        AggregatorV3Mock btcPriceFeed = new AggregatorV3Mock(DECIMALS, BTC_USD_PRICE);
        AggregatorV3Mock ethPriceFeed = new AggregatorV3Mock(DECIMALS, ETH_USD_PRICE);
        ERC20MockWETH wethMock = new ERC20MockWETH(msg.sender);
        ERC20MockWBTC wbtcMock = new ERC20MockWBTC(msg.sender);
        vm.stopBroadcast();

        return NetworkProfiler({
            ethUsdPriceFeed: address(ethPriceFeed),
            btcUsdPriceFeed: address(btcPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            deployerKey: vm.envUint("PRIVATE_KEY_ANVIL")
        });
    }

    function getActiveNetworkProfiler() external returns (NetworkProfiler memory) {
        return activeNetworkProfiler;
    }
}
