// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of Chainlink's AggregatorV3Interface FoboLimitOrders reads (an ETH/USD feed: Chainlink, or any feed
///         with the same interface), plus description(), which the deploy script checks on Chainlink's Robinhood feed.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
