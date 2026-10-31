// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// Local chains and tests only: an ETH/USD feed (Chainlink AggregatorV3 interface) its owner sets by hand. Deploy.s.sol
/// deploys it on chain 31337 when ETH_USD_FEED is unset, at ETH_USD; production uses a real feed (ETH_USD_FEED). Tests
/// also use it as an L2 sequencer uptime feed (answer 0 = up, 1 = down; startedAt reads as updatedAt).
contract MockEthUsdFeed is IAggregatorV3 {
    error NotOwner();

    address public immutable owner;
    uint8 public immutable decimals;
    // AggregatorV3's description() getter: the interface fixes the name
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant description = "ETH / USD";

    struct Round {
        int256 answer;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _answeredInRound;
    /// Every round set so far, by id, for getRoundData (FoboBoundedFeed reads the round before the latest)
    mapping(uint80 => Round) internal _rounds;

    constructor(uint8 _decimals, int256 answer) {
        owner = msg.sender;
        decimals = _decimals;
        setAnswer(answer);
    }

    /// A new round with this answer, updated now.
    function setAnswer(int256 answer) public {
        if (msg.sender != owner) revert NotOwner();
        _roundId++;
        (_answer, _updatedAt, _answeredInRound) = (answer, block.timestamp, _roundId);
        _rounds[_roundId] = Round(answer, block.timestamp, _roundId);
    }

    /// Any round data, as a broken or stale feed would report it.
    function setRound(uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound) external {
        if (msg.sender != owner) revert NotOwner();
        (_roundId, _answer, _updatedAt, _answeredInRound) = (roundId, answer, updatedAt, answeredInRound);
        _rounds[roundId] = Round(answer, updatedAt, answeredInRound);
    }

    /// Forgets a round, as a Chainlink proxy has none from before its current phase.
    function forgetRound(uint80 roundId) external {
        if (msg.sender != owner) revert NotOwner();
        delete _rounds[roundId];
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }

    /// A round set before, else Chainlink's own revert for one it never had.
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[roundId];
        require(r.updatedAt != 0 || r.answer != 0, "No data present");
        return (roundId, r.answer, r.updatedAt, r.updatedAt, r.answeredInRound);
    }
}
