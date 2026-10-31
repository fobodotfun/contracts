// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IFoboBoundedFeed} from "./interfaces/IFoboBoundedFeed.sol";

/// @title FoboBoundedFeed
/// @notice A Chainlink feed, forwarded unchanged except that an answer outside [minAnswer, maxAnswer], or one that
///         moved more than maxJumpBps from the round before it, reverts instead of pricing a fill. FoboLimitOrders
///         already refuses a stale answer (maxPriceAge) and a sequencer outage; it took any positive number for the
///         price, so an aggregator pinned at its own min or max (what Chainlink's aggregators do when the market leaves
///         their configured range), or one that printed a wild round, would fill orders at that number. The bounds are
///         the fix a single feed allows: Robinhood Chain has one ETH/USD feed, so there is no second source to compare
///         against, and a wide range around any plausible price with a per-round jump limit refuses exactly the two
///         failures a wrong answer takes (a flat line at the edge, a spike) without ever refusing a real market. Set in
///         FoboLimitOrders with setPayToken(token, thisFeed, maxPriceAge, false, true); the burner's USD-peg check reads
///         ethUsd() through the same path. Spec: packages/contracts/README.md §15.
/// @dev No owner and nothing settable: the bounds are the deployment. To change them, deploy another and point
///      setPayToken at it. Staleness is not checked here (FoboLimitOrders does, against updatedAt as forwarded).
contract FoboBoundedFeed is IFoboBoundedFeed {
    uint256 internal constant BPS = 10_000;

    IAggregatorV3 public immutable source;
    int256 public immutable minAnswer;
    int256 public immutable maxAnswer;
    uint256 public immutable maxJumpBps;

    /// @param _minAnswer lowest answer passed through (positive; a zero or negative answer is also out of range)
    /// @param _maxAnswer highest answer passed through
    /// @param _maxJumpBps most the answer may move from the previous round, in basis points of it; 0 = not checked
    constructor(IAggregatorV3 _source, int256 _minAnswer, int256 _maxAnswer, uint256 _maxJumpBps) {
        if (address(_source) == address(0)) revert ZeroAddress();
        if (_minAnswer <= 0 || _maxAnswer <= _minAnswer) revert BadBounds();
        source = _source;
        minAnswer = _minAnswer;
        maxAnswer = _maxAnswer;
        maxJumpBps = _maxJumpBps;
    }

    function decimals() external view returns (uint8) {
        return source.decimals();
    }

    function description() external view returns (string memory) {
        return source.description();
    }

    /// @notice The source's latest round, as it reports it, unless the answer is out of range (AnswerOutOfRange) or
    ///         moved more than maxJumpBps from the previous round's positive answer (AnswerJumped). The previous round
    ///         is roundId - 1 on the source; a Chainlink proxy has none right after a phase change (the aggregator
    ///         behind it changed, and round ids restart), so a missing one is not an error: that round is only checked
    ///         against the range.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = source.latestRoundData();
        if (answer < minAnswer || answer > maxAnswer) revert AnswerOutOfRange(answer);
        if (maxJumpBps != 0 && roundId != 0) {
            try source.getRoundData(roundId - 1) returns (uint80, int256 previous, uint256, uint256, uint80) {
                if (previous > 0) {
                    uint256 move = uint256(answer > previous ? answer - previous : previous - answer);
                    if (move * BPS > uint256(previous) * maxJumpBps) revert AnswerJumped(previous, answer);
                }
            } catch {
                // no previous round on the source (a phase boundary): nothing to compare with
            }
        }
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return source.getRoundData(_roundId);
    }
}
