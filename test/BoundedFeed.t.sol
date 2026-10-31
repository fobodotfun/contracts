// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FoboBoundedFeed} from "../src/FoboBoundedFeed.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IFoboBoundedFeed} from "../src/interfaces/IFoboBoundedFeed.sol";
import {IFoboLimitOrders} from "../src/interfaces/IFoboLimitOrders.sol";
import {MockEthUsdFeed} from "../script/MockEthUsdFeed.sol";
import {LimitOrdersBase} from "./LimitOrders.t.sol";

/// FoboBoundedFeed alone: a sane answer passes through untouched, a pinned or wild one reverts, a missing previous
/// round is not an error, and the bounds are checked at deploy.
contract BoundedFeedTest is Test {
    int256 constant MIN = 100e8;
    int256 constant MAX = 100_000e8;
    uint256 constant JUMP = 5_000; // 50%
    MockEthUsdFeed source;
    FoboBoundedFeed bounded;

    function setUp() public {
        vm.warp(1_700_000_000);
        source = new MockEthUsdFeed(8, 2_600e8);
        bounded = new FoboBoundedFeed(IAggregatorV3(address(source)), MIN, MAX, JUMP);
    }

    function _latest(IAggregatorV3 f) internal view returns (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) {
        return f.latestRoundData();
    }

    /// Everything the source reports comes back as is: round id, answer, both timestamps, answeredInRound, decimals,
    /// description.
    function test_passesThroughUnchanged() public {
        source.setRound(7, 2_650e8, vm.getBlockTimestamp() - 5, 6);
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) = _latest(IAggregatorV3(address(bounded)));
        (uint80 r0, int256 a0, uint256 s0, uint256 u0, uint80 air0) = _latest(IAggregatorV3(address(source)));
        assertEq(r, r0);
        assertEq(a, a0);
        assertEq(s, s0);
        assertEq(u, u0);
        assertEq(air, air0);
        assertEq(bounded.decimals(), 8);
        assertEq(bounded.description(), "ETH / USD");
        assertEq(address(bounded.source()), address(source));
        assertEq(bounded.minAnswer(), MIN);
        assertEq(bounded.maxAnswer(), MAX);
        assertEq(bounded.maxJumpBps(), JUMP);
        (uint80 gr, int256 ga,,,) = bounded.getRoundData(7);
        assertEq(gr, 7);
        assertEq(ga, 2_650e8);
    }

    /// An aggregator pinned at its floor or ceiling, or printing zero or a negative number, is refused with the answer;
    /// the bounds themselves pass (checked with the jump limit off, since reaching them from $2,600 is a jump).
    function test_pinnedAnswerReverts() public {
        FoboBoundedFeed noJump = new FoboBoundedFeed(IAggregatorV3(address(source)), MIN, MAX, 0);
        source.setAnswer(MIN - 1);
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, MIN - 1));
        noJump.latestRoundData();
        source.setAnswer(MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, MAX + 1));
        noJump.latestRoundData();
        source.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, int256(0)));
        noJump.latestRoundData();
        source.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, int256(-1)));
        noJump.latestRoundData();
        source.setAnswer(MIN);
        (, int256 a,,,) = noJump.latestRoundData();
        assertEq(a, MIN);
        source.setAnswer(MAX);
        (, a,,,) = noJump.latestRoundData();
        assertEq(a, MAX);
        // the range is checked before the jump: a pinned answer reports as out of range even when it is also a jump
        source.setAnswer(2_600e8);
        source.setAnswer(MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, MAX + 1));
        bounded.latestRoundData();
    }

    /// A move of more than maxJumpBps from the previous round reverts with both answers; exactly the bound, or less,
    /// passes, either way.
    function test_jumpAboveTheBoundReverts() public {
        source.setAnswer(3_900e8); // +50%: on the bound
        (, int256 a,,,) = bounded.latestRoundData();
        assertEq(a, 3_900e8);
        source.setAnswer(3_900e8); // a flat round: the bound now applies from 3,900
        source.setAnswer(5_851e8); // +50.03%
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerJumped.selector, int256(3_900e8), int256(5_851e8)));
        bounded.latestRoundData();
        source.setRound(20, 2_600e8, vm.getBlockTimestamp(), 20);
        source.setAnswer(1_300e8); // -50%: on the bound
        (, a,,,) = bounded.latestRoundData();
        assertEq(a, 1_300e8);
        source.setAnswer(1_300e8);
        source.setAnswer(649e8); // -50.08%
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerJumped.selector, int256(1_300e8), int256(649e8)));
        bounded.latestRoundData();
        // with the jump limit off, any move inside the range passes
        FoboBoundedFeed noJump = new FoboBoundedFeed(IAggregatorV3(address(source)), MIN, MAX, 0);
        (, a,,,) = noJump.latestRoundData();
        assertEq(a, 649e8);
    }

    /// No previous round (a proxy right after a phase change), a previous round with no positive answer, or round id 0:
    /// only the range is checked.
    function test_missingPreviousRoundIsNotAnError() public {
        source.setRound(50, 2_600e8, vm.getBlockTimestamp(), 50); // round 49 was never set
        (, int256 a,,,) = bounded.latestRoundData();
        assertEq(a, 2_600e8);
        source.setRound(51, 9_000e8, vm.getBlockTimestamp(), 51); // round 50 exists: +246% is a jump
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerJumped.selector, int256(2_600e8), int256(9_000e8)));
        bounded.latestRoundData();
        source.forgetRound(50);
        (, a,,,) = bounded.latestRoundData();
        assertEq(a, 9_000e8);
        source.setRound(60, -5, vm.getBlockTimestamp(), 60);
        source.setRound(61, 2_600e8, vm.getBlockTimestamp(), 61); // the previous answer is not positive: no ratio
        (, a,,,) = bounded.latestRoundData();
        assertEq(a, 2_600e8);
        source.setRound(0, 2_600e8, vm.getBlockTimestamp(), 0);
        (, a,,,) = bounded.latestRoundData();
        assertEq(a, 2_600e8);
    }

    function test_constructorChecks() public {
        vm.expectRevert(IFoboBoundedFeed.ZeroAddress.selector);
        new FoboBoundedFeed(IAggregatorV3(address(0)), MIN, MAX, JUMP);
        vm.expectRevert(IFoboBoundedFeed.BadBounds.selector);
        new FoboBoundedFeed(IAggregatorV3(address(source)), 0, MAX, JUMP);
        vm.expectRevert(IFoboBoundedFeed.BadBounds.selector);
        new FoboBoundedFeed(IAggregatorV3(address(source)), MIN, MIN, JUMP);
        new FoboBoundedFeed(IAggregatorV3(address(source)), MIN, MAX, 0);
    }
}

/// FoboBoundedFeed in front of FoboLimitOrders' ETH feed (setPayToken): a fill at a sane price works, a fill with the
/// source pinned reverts with the feed's error, and FoboBurner's USD-peg check (limitOrders.ethUsd()) reads through it.
contract BoundedFeedLimitOrdersTest is LimitOrdersBase {
    FoboBoundedFeed bounded;

    function setUp() public override {
        super.setUp();
        bounded = new FoboBoundedFeed(IAggregatorV3(address(feed)), 100e8, 100_000e8, 5_000);
        limitOrders.setPayToken(ETH, IAggregatorV3(address(bounded)), FEED_MAX_AGE, false, true);
    }

    function test_fillsThroughTheBoundedFeed() public {
        assertEq(limitOrders.ethUsd(), ETH_USD, "the same price as before");
        address o = _user("owner");
        uint256 id = _placeBuy(o, kumo, 1 ether, 1e18, 0);
        _fill(id, 0.25 ether, 0);
        // the source pins at its floor: the fill is refused by the bounds, not priced at $100
        feed.setAnswer(100e8 - 1);
        _expectFillRevert(
            id, 0.25 ether, 0, abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, int256(100e8 - 1))
        );
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, int256(100e8 - 1)));
        limitOrders.ethUsd();
        // a wild round: refused too
        feed.setAnswer(2_600e8);
        feed.setAnswer(6_000e8);
        _expectFillRevert(
            id, 0.25 ether, 0, abi.encodeWithSelector(IFoboBoundedFeed.AnswerJumped.selector, int256(2_600e8), int256(6_000e8))
        );
        // back to a sane series: fills again; staleness still FoboLimitOrders' own check
        feed.setAnswer(2_600e8);
        feed.setAnswer(2_600e8);
        _fill(id, 0.25 ether, 0);
        vm.warp(vm.getBlockTimestamp() + FEED_MAX_AGE + 1);
        _expectFillRevert(id, 0.25 ether, 0, IFoboLimitOrders.FeedPriceStale.selector);
        // a broken feed never locks escrow
        vm.prank(o);
        limitOrders.cancel(id, o);
    }

    /// FoboBurner's USD-pegged route values its ETH leg with limitOrders.ethUsd(): the bounded feed's answer, and the
    /// bounded feed's refusal.
    function test_burnerPegReadsThroughTheBoundedFeed() public {
        _usdSetup(); // USDY bought in its snipe window: the burn share sits in FoboBurner as USD claims
        PoolKey[] memory path = new PoolKey[](1);
        path[0] = usdKey;
        burner.setRoute(address(usd), path, true);
        assertGt(_burnerOwed(usdKey.currency1), 30e6, "USD claims to spend");
        vm.prank(burnKeeper, burnKeeper);
        (uint256 ethIn,) = burner.buybackAndBurn(address(usd), 30e6, 0, 0);
        assertApproxEqRel(ethIn, uint256(30 ether) / 2_600, 0.002e18, "the USD leg at the pool's price, on peg");
        vm.roll(vm.getBlockNumber() + 1);
        feed.setAnswer(100e8 - 1);
        vm.prank(burnKeeper, burnKeeper);
        vm.expectRevert(abi.encodeWithSelector(IFoboBoundedFeed.AnswerOutOfRange.selector, int256(100e8 - 1)));
        burner.buybackAndBurn(address(usd), 30e6, 0, 0);
    }
}
