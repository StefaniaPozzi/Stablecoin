//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

/**
 * @title OracleLin
 * @author Stefania Pozzi
 *
 * @notice checks if the Chainlink Oracle Price Feed for stale data
 * If the price is stale, the function will revert and make DEXSEngine unusable by design
 *
 * //
 */
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


library OracleLib {
    uint256 private constant TIMEOUT = 2 hours; // in seconds. We give more time than its heartbeat (1h)

    error OracleLib__StalePrice();

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 passedTimeFromLastPriceFeed = block.timestamp - updatedAt;
        if (passedTimeFromLastPriceFeed > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
