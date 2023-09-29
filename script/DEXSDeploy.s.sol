//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Script, console} from "forge-std/Script.sol";
import {DEXSEngine} from "../src/DEXSEngine.sol";
import {DEXStablecoin} from "../src/DEXStablecoin.sol";
import {NetworkConfig} from "../script/NetworkConfig.s.sol";

contract DEXSDeploy is Script {
    address[] public tokenAddresses;
    address[] public priceFeeAddresses;

    function run() external returns (DEXStablecoin, DEXSEngine, NetworkConfig) {
        NetworkConfig networkConfig = new NetworkConfig();

        (address ethUsdPriceFeed, address btcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            networkConfig.activeNetworkProfiler();
        tokenAddresses = [weth, wbtc];
        priceFeeAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];
        vm.startBroadcast(deployerKey);
        DEXStablecoin dexstablecoin = new DEXStablecoin();
        DEXSEngine dexsengine = new DEXSEngine(tokenAddresses, priceFeeAddresses, address(dexstablecoin));
        dexstablecoin.transferOwnership(address(dexsengine));
        vm.stopBroadcast();

        return (dexstablecoin, dexsengine, networkConfig);
    }
}
