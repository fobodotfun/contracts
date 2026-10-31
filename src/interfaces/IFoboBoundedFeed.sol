// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "./IAggregatorV3.sol";

/// @notice FoboBoundedFeed: a Chainlink feed with its answer bounded, read in its place by FoboLimitOrders (setPayToken).
///         Spec: packages/contracts/README.md §15.
interface IFoboBoundedFeed is IAggregatorV3 {
    error ZeroAddress();
    /// @notice minAnswer must be positive and below maxAnswer.
    error BadBounds();
    /// @notice The source's latest answer is outside [minAnswer, maxAnswer]: an aggregator pinned at its floor or
    ///         ceiling, or a broken one.
    error AnswerOutOfRange(int256 answer);
    /// @notice The source's latest answer moved more than maxJumpBps from the round before it.
    error AnswerJumped(int256 previous, int256 answer);

    /// @notice The feed whose answers are forwarded.
    function source() external view returns (IAggregatorV3);
    /// @notice The lowest and highest answer passed through, in the source's decimals.
    function minAnswer() external view returns (int256);
    function maxAnswer() external view returns (int256);
    /// @notice The most the answer may move from the previous round, in basis points of that round; 0 = not checked.
    function maxJumpBps() external view returns (uint256);
}
