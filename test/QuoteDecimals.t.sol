// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {Ticks} from "../src/libraries/Ticks.sol";
import {MAX_TRANCHE_OFFSET} from "../src/libraries/Curve.sol";
import {StartTick} from "../script/StartTick.sol";
import {FoboBase} from "./Fobo.t.sol";

/// A stablecoin-like quote with any decimals, which can be paused (every transfer reverts) or freeze one account (its
/// transfers revert), like USDG on Robinhood Chain, and optionally takes a fee on every transfer (what the owner's
/// review must refuse).
contract MockQuote is ERC20 {
    uint8 internal immutable _decimals;
    uint256 public feeBps;
    bool public paused;
    mapping(address => bool) public frozen;

    constructor(uint8 decimals_, uint256 feeBps_) ERC20("Mock USD", "MUSD") {
        _decimals = decimals_;
        feeBps = feeBps_;
        _mint(msg.sender, 1e15 * 10 ** decimals_); // a quadrillion units
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setFrozen(address who, bool f) external {
        frozen[who] = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "paused");
        require(!frozen[from] && !frozen[to], "frozen");
        if (feeBps != 0 && from != address(0)) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// Quotes with any number of decimals (USDG on Robinhood Chain has 6): the start band is set at the raw-unit tick
/// (tokens per quote in raw units, so a 6-decimal $1 quote starts ~391,500 instead of ~115,140), the factory stores the
/// decimals it read, and every pool mechanic (launch, dev buy, snipe window, raises, buybacks, exits, claims, revenue)
/// holds on such a pair. Attack check: a paused quote only blocks its own pairs' trades, a frozen payee's payout stays owed, a
/// fee-on-transfer quote's dev buy reverts (why allowing one is a review step). Limit orders on such pairs:
/// LimitOrders.t.sol (USDY).
/// Allowing a $1 quote with any decimals and launching on it (QuoteDecimalsTest, BurnerTest).
abstract contract QuoteBase is FoboBase {
    using PoolIdLibrary for PoolKey;

    uint256 constant USD_E8 = 1e8; // $1

    /// A $1 quote with `decimals` decimals, allowed with its band around the $10k start at that price
    function _allowQuote(uint8 decimals, uint256 feeBps) internal returns (MockQuote q, int24 mid) {
        q = new MockQuote(decimals, feeBps);
        mid = StartTick.forQuote(USD_E8, decimals);
        factory.setQuoteBand(address(q), mid - BAND_HALF, mid + BAND_HALF);
        factory.setQuoteAllowed(address(q), true);
    }

    /// `who` holds `amount` whole units of `q`, approved for the router and the factory
    function _fund(MockQuote q, address who, uint256 amount) internal {
        q.transfer(who, amount * 10 ** q.decimals());
        vm.startPrank(who);
        q.approve(address(router), type(uint256).max);
        q.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    /// `creator` launches `name` on `q` at `tick` with a dev buy of `dev` tokens
    function _launchOn(MockQuote q, address creator, string memory name, string memory ticker, uint256 dev, int24 tick)
        internal
        returns (address token, PoolKey memory k)
    {
        bytes32 s = _saltAfter(creator, address(q), name, ticker);
        vm.prank(creator);
        (token,) = factory.launch{value: FEE}(
            _signedBy(startSignerKey, creator, address(q), name, ticker, s, dev, tick, vm.getBlockTimestamp() + 1 hours)
        );
        k = hook.keyFor(address(q), token);
    }
}

contract QuoteDecimalsTest is QuoteBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- allowlisting and the band

    /// Any decimals() from MIN_QUOTE_DECIMALS up is accepted and stored (fewer is refused, below); the tick each decimals'
    /// $10k start lands on is the 18-decimal one shifted by (18 - d) decades of ticks, and it is a tick createPool accepts.
    function test_anyDecimalsAllowedAndStored() public {
        _launchFobo();
        uint8[3] memory decs = [uint8(18), 8, 6];
        int24[3] memory ticks = [int24(115_140), 345_420, 391_500]; // ceil to the 60-tick grid
        for (uint256 i; i < decs.length; i++) {
            (MockQuote q, int24 mid) = _allowQuote(decs[i], 0);
            (bool allowed, int24 lo, int24 hi, uint8 d) = factory.quotes(address(q));
            assertTrue(allowed);
            assertEq(d, decs[i], "decimals stored");
            assertEq(mid, ticks[i], "the $10k start at $1");
            assertEq(hi - lo, factory.MAX_START_BAND());
            assertGe(lo, Ticks.MIN_START_TICK);
            assertLt(hi, TickMath.MAX_TICK - Ticks.SPACING);
            // every tranche top (mid - topOff) stays above MIN_TICK, with room to raise above the start
            assertGt(mid - MAX_TRANCHE_OFFSET, Ticks.MIN_TICK);
        }
        // the 18-decimal case is the ETH one Deploy.s.sol uses
        assertEq(StartTick.forEthUsd(2600), StartTick.forQuote(2600e8, 18));
        assertEq(StartTick.forEthUsd(2600), FOBO_TICK);
        // disallowing keeps the decimals it read
        (MockQuote six,) = _allowQuote(6, 0);
        factory.setQuoteAllowed(address(six), false);
        (bool ok,,, uint8 d6) = factory.quotes(address(six));
        assertFalse(ok);
        assertEq(d6, 6);
    }

    /// The curve of a quote with fewer decimals sits at a higher tick, where its liquidity is far below v4's per-tick cap
    /// (half of it is the floor band's headroom): the liquidity bound (MIN_START_TICK) is never the problem for them.
    function test_fewerDecimalsFitTheLiquidityCap() public pure {
        uint256 half = Pool.tickSpacingToMaxLiquidityPerTick(60) / 2;
        uint256 at18 = _curveLiquidity(StartTick.forQuote(USD_E8, 18));
        uint256 at6 = _curveLiquidity(StartTick.forQuote(USD_E8, 6));
        uint256 at0 = _curveLiquidity(StartTick.forQuote(USD_E8, 0));
        assertLe(at18, half);
        assertLt(at6, at18 / 1e5, "12 decades higher: ~1e6 less liquidity");
        assertLt(at0, at6);
        // the lowest band a $1 quote can be given is still inside the bound: ~25 decimals would be the first to fail
        assertGe(StartTick.forQuote(USD_E8, 24) - BAND_HALF, Ticks.MIN_START_TICK);
        assertLt(StartTick.forQuote(USD_E8, 26) - BAND_HALF, Ticks.MIN_START_TICK);
    }

    /// A start priced for 18 decimals is out of a 6-decimal quote's band (and the reverse): the signer must price the
    /// start in the quote's decimals.
    function test_bandIsInRawUnits() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        (MockQuote six, int24 mid) = _allowQuote(6, 0);
        address alice = _user("alice");
        _fund(six, alice, 1_000_000);
        int24 tick18 = StartTick.forQuote(USD_E8, 18);
        bytes32 s = _saltAfter(alice, address(six), "Neko", "NEKO");
        _expectLaunchRevert(
            alice,
            _signedBy(
                startSignerKey, alice, address(six), "Neko", "NEKO", s, 0, tick18, vm.getBlockTimestamp() + 1 hours
            ),
            IFoboFactory.StartOutOfBand.selector
        );
        (int24 lo, int24 hi) = factory.startTickRange(address(six));
        assertEq(lo, mid - BAND_HALF);
        assertEq(hi, mid + BAND_HALF);
        _launchOn(six, alice, "Neko", "NEKO", 0, mid);
    }

    // ---------------------------------------------------------------- a 6-decimal pair's life

    /// Launch on a 6-decimal $1 quote with the full 5% dev buy: it costs what the curve says in that quote (~$598 with
    /// the tax, in 6-decimal units), the snipe window's burn share goes to FoboBurner as claims of the quote, the
    /// creator's fee is owed in the quote (never paid in the swap), the floor rises, the creator claims, and everyone
    /// exits above the floor.
    function test_sixDecimalPairLaunchTradeRaiseExit() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        (MockQuote usd, int24 mid) = _allowQuote(6, 0);
        Currency cq = Currency.wrap(address(usd));
        address alice = _user("alice");
        address bob = _user("bob");
        _fund(usd, alice, 10_000);
        _fund(usd, bob, 100_000);

        uint256 a0 = usd.balanceOf(alice);
        (address neko, PoolKey memory k) = _launchOn(usd, alice, "Neko", "NEKO", 50_000_000e18, mid);
        uint256 paid = a0 - usd.balanceOf(alice);
        // 35% of supply from a $10k start: 5% costs 3500 x 50 / 300 = $583.33, grossed up by the 2.5% tax = $598.29;
        // the start tick rounds up the 60-tick grid, so the mcap (and the cost) is up to 0.6% under that
        assertApproxEqRel(paid, 598_290_000, 0.007e18, "the dev buy in 6-decimal units");
        assertLt(paid, 598_290_000);
        assertEq(FoboToken(neko).balanceOf(alice), 50_000_000e18);
        assertEq(usd.balanceOf(address(factory)), 0, "nothing stuck in the factory");

        // snipe window: bob buys at second 0 (90% tax); 40% of it goes to FoboBurner (its claims), 60% vests
        _approve(bob, neko);
        uint256 team0 = hook.teamOwed(cq);
        uint256 burn0 = _burnerOwed(cq);
        vm.recordLogs();
        _swap(bob, k, true, -int256(uint256(1_000e6)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 taxPaid;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != IFoboHook.TaxPaid.selector) continue;
            (,, uint256 toFloor, uint256 toCreator, uint256 toTeam, uint256 toBurn) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256));
            uint256 tax = toFloor + toCreator + toTeam + toBurn;
            taxPaid = tax;
            assertEq(toBurn, tax * 40 / 100, "40% to the $FOBO burn");
            assertEq(toCreator + toTeam, 0, "the snipe window pays no creator or team");
            assertEq(toFloor, tax - toBurn);
        }
        assertEq(taxPaid, 900e6, "90% of a 1,000 USD buy");
        assertEq(_burnerOwed(cq) - burn0, 360e6, "FoboBurner holds it as claims of the 6-decimal quote");
        assertEq(hook.teamOwed(cq), team0, "nothing to the team");

        // after the window: the creator's 0.6% is owed in the quote, not paid in the swap
        vm.warp(vm.getBlockTimestamp() + 61);
        a0 = usd.balanceOf(alice);
        (,, uint256 owed0,,) = _pool(k);
        _swap(bob, k, true, -int256(uint256(10_000e6)), 0);
        assertEq(usd.balanceOf(alice), a0, "nobody is paid in a swap");
        (, uint256 pot, uint256 creatorOwed,,) = _pool(k);
        assertEq(creatorOwed - owed0, 10_000e6 * 6 / 1000, "0.6% of the trade owed to the creator");
        assertGt(pot, 0);

        // the next block's first swap raises the floor
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 11 minutes); // the snipe pot has vested too
        (int24 f0,,,,) = _pool(k);
        _swap(bob, k, true, -int256(uint256(1_000e6)), 0);
        (int24 f1,,,, uint128 band) = _pool(k);
        assertLt(f1, f0, "the floor rose");
        assertGt(band, 0);

        // the creator claims its USD (the raise's swap added its 0.6% too)
        (,, creatorOwed,,) = _pool(k);
        hook.claimCreator(k, alice);
        assertEq(usd.balanceOf(alice) - a0, creatorOwed, "claimed in the quote");
        (,, creatorOwed,,) = _pool(k);
        assertEq(creatorOwed, 0);

        // everyone exits in one sell each, above the floor
        address[] memory us = new address[](2);
        us[0] = alice;
        us[1] = bob;
        _dumpAll(k, us);
        assertLe(_tick(k), f1 + 60);
        assertGt(usd.balanceOf(bob), 100_000e6 - 11_000e6 - 1_000e6, "bob got most of his quote back");
    }

    /// A buyback on a 6-decimal pair: a sniper's floor share vests after he sold back, the band can't go under the price
    /// with all of it, so the raise buys back and burns tokens and lifts the price (BoughtBack), and the floor still
    /// absorbs every circulating token.
    function test_sixDecimalBuyback() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        (MockQuote usd, int24 mid) = _allowQuote(6, 0);
        address alice = _user("alice");
        address eve = _user("eve");
        address bob = _user("bob");
        _fund(usd, alice, 10_000);
        _fund(usd, eve, 1_000_000);
        _fund(usd, bob, 1_000_000);
        (address neko, PoolKey memory k) = _launchOn(usd, alice, "Neko", "NEKO", 0, mid);
        _approve(eve, neko);
        _approve(bob, neko);
        // eve snipes at second 0 (90% tax, 60% of it vesting into the floor) and dumps at 61 s
        _swap(eve, k, true, -int256(uint256(100_000e6)), 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.roll(vm.getBlockNumber() + 1);
        _swap(eve, k, false, -int256(FoboToken(neko).balanceOf(eve)), 0);
        // bob holds a little; after the vesting the floor money is worth more than the tokens left can carry under the
        // price: the raise lifts the price instead
        _swap(bob, k, true, -int256(uint256(1_000e6)), 0);
        vm.warp(vm.getBlockTimestamp() + 11 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        vm.recordLogs();
        hook.poke(k);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool bought;
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "no RaiseFailed");
            if (logs[i].topics[0] == IFoboHook.BoughtBack.selector) bought = true;
        }
        assertTrue(bought, "the floor bought back");
        (int24 f,,,,) = _pool(k);
        assertLt(f, mid, "the floor is above the start");
        _dumpAll(k, _one(bob));
        assertLe(_tick(k), f + 60);
    }

    /// Quotes under MIN_QUOTE_DECIMALS are refused (a few raw units of pot near the max tick round raises into
    /// FloorBroken), at allow time, whatever their band.
    function test_fewerThanSixDecimalsRefused() public {
        _launchFobo();
        uint8[3] memory decs = [uint8(5), 2, 0];
        for (uint256 i; i < decs.length; i++) {
            MockQuote q = new MockQuote(decs[i], 0);
            factory.setQuoteBand(address(q), 400_000, 400_000 + factory.MAX_START_BAND());
            vm.expectRevert(IFoboFactory.BadQuote.selector);
            factory.setQuoteAllowed(address(q), true);
        }
    }

    /// 8- and 6-decimal quotes: launch with a dev buy, trade, raise, exit; the hook has no quote-decimal constant.
    function test_eightAndSixDecimalPairs() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        uint8[2] memory decs = [uint8(8), 6];
        for (uint256 i; i < decs.length; i++) {
            (MockQuote q, int24 mid) = _allowQuote(decs[i], 0);
            address alice = _user(string(abi.encodePacked("alice", vm.toString(i))));
            address bob = _user(string(abi.encodePacked("bob", vm.toString(i))));
            _fund(q, alice, 10_000);
            _fund(q, bob, 100_000);
            uint256 a0 = q.balanceOf(alice);
            (address token, PoolKey memory k) = _launchOn(q, alice, "Kumo", "KUMO", 10_000_000e18, mid);
            // 1% of supply: 3500 x 10 / 340 = $102.94, grossed up = $105.58
            assertApproxEqRel(a0 - q.balanceOf(alice), 10558 * 10 ** uint256(decs[i]) / 100, 0.007e18, "dev buy");
            _approve(bob, token);
            vm.warp(vm.getBlockTimestamp() + 61);
            _swap(bob, k, true, -int256(10_000 * 10 ** uint256(decs[i])), 0);
            vm.roll(vm.getBlockNumber() + 1);
            _swap(bob, k, true, -int256(1_000 * 10 ** uint256(decs[i])), 0);
            (int24 f,,,,) = _pool(k);
            assertLt(f, mid, "raised");
            address[] memory us = new address[](2);
            us[0] = alice;
            us[1] = bob;
            _dumpAll(k, us);
            assertLe(_tick(k), f + 60);
        }
    }

    // ---------------------------------------------------------------- attack scenarios
    /// A paused quote (USDG can pause) blocks its own pairs' swaps and payouts, nothing else: $FOBO and ETH pairs trade,
    /// its pool's floor still settles (claims only) and what's owed (the creator's fee; FoboBurner's claims of it) is
    /// paid once it resumes.
    function test_pausedQuoteOnlyBlocksItsPairs() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        (MockQuote usd, int24 mid) = _allowQuote(6, 0);
        Currency cq = Currency.wrap(address(usd));
        address alice = _user("alice");
        address bob = _user("bob");
        _fund(usd, alice, 10_000);
        _fund(usd, bob, 100_000);
        (address neko, PoolKey memory k) = _launchOn(usd, alice, "Neko", "NEKO", 0, mid);
        address kumo = _launchAs(bob, _signedEth(bob, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        PoolKey memory kk = hook.keyFor(address(0), kumo);
        _approve(bob, neko);
        _approve(bob, kumo);
        _swap(bob, k, true, -int256(uint256(1_000e6)), 0); // the snipe tax hands FoboBurner USD claims
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(bob, k, true, -int256(uint256(10_000e6)), 0);
        uint256 burnOwed = _burnerOwed(cq);
        assertEq(burnOwed, 360e6);
        (,, uint256 creatorOwed,,) = _pool(k);
        assertGt(creatorOwed, 0);

        usd.setPaused(true);
        vm.prank(bob, bob);
        vm.expectRevert();
        router.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            ""
        );
        vm.expectRevert();
        hook.claimCreator(k, alice);
        vm.expectRevert();
        burner.emergencyWithdraw(address(usd), team);
        // other pairs are untouched
        _swap(bob, foboKey, true, -1 ether, 1 ether);
        _swap(bob, kk, true, -1 ether, 1 ether);
        // the paused pair's floor still settles the block (claims move, no tokens)
        vm.roll(vm.getBlockNumber() + 1);
        (int24 f0,,,,) = _pool(k);
        hook.poke(k);
        (int24 f1,,,,) = _pool(k);
        assertLt(f1, f0, "raised while paused");

        usd.setPaused(false);
        uint256 a0 = usd.balanceOf(alice);
        hook.claimCreator(k, alice);
        assertEq(usd.balanceOf(alice) - a0, creatorOwed);
        uint256 t0 = usd.balanceOf(team);
        burner.emergencyWithdraw(address(usd), team);
        assertEq(usd.balanceOf(team) - t0, burnOwed);
        _dumpAll(k, _one(bob));
        assertLe(_tick(k), f1 + 60);
    }

    /// A payee the quote freezes (USDG can freeze accounts) never blocks a swap: nobody is paid in one, the creator's
    /// fee stays in creatorOwed and a referrer's in FoboRevenue.owed; both claim once unfrozen.
    function test_frozenPayeeIsOwedNotPaid() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        (MockQuote usd, int24 mid) = _allowQuote(6, 0);
        address alice = _user("alice");
        address bob = _user("bob");
        address carol = makeAddr("carol"); // bob's referrer
        _fund(usd, alice, 10_000);
        _fund(usd, bob, 100_000);
        address registrar = makeAddr("registrar");
        revenue.setRegistrar(registrar);
        address[] memory ts = new address[](1);
        address[] memory rs = new address[](1);
        (ts[0], rs[0]) = (bob, carol);
        vm.prank(registrar);
        assertEq(revenue.registerBy(ts, rs), 1);

        (address neko, PoolKey memory k) = _launchOn(usd, alice, "Neko", "NEKO", 0, mid);
        _approve(bob, neko);
        vm.warp(vm.getBlockTimestamp() + 61);
        usd.setFrozen(alice, true);
        usd.setFrozen(carol, true);
        _swap(bob, k, true, -int256(uint256(10_000e6)), 0);
        (,, uint256 creatorOwed,,) = _pool(k);
        assertEq(creatorOwed, 10_000e6 * 6 / 1000, "the creator's 0.6% is owed, not paid");
        uint256 referral = 10_000e6 * 4 / 1000 * 25 / 100; // 25% of the 0.4% protocol fee
        assertEq(revenue.owed(carol, address(usd)), referral, "the referrer's share is owed");
        vm.expectRevert();
        hook.claimCreator(k, alice);
        usd.setFrozen(alice, false);
        usd.setFrozen(carol, false);
        hook.claimCreator(k, alice);
        assertEq(usd.balanceOf(alice), 10_000e6 + creatorOwed);
        revenue.claim(carol, address(usd), carol);
        assertEq(usd.balanceOf(carol), referral);
    }

    /// A fee-on-transfer quote passes setQuoteAllowed (a review step, not a contract check) and then every transfer
    /// into the PoolManager comes up short: the creator's buy reverts, so nothing is lost but the launch doesn't go
    /// through. This is why docs/DEPLOYMENT.md §9.1 refuses such a token before signing.
    function test_feeOnTransferQuoteDevBuyReverts() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        (MockQuote fee, int24 mid) = _allowQuote(6, 100); // 1% on every transfer
        address alice = _user("alice");
        _fund(fee, alice, 10_000);
        bytes32 s = _saltAfter(alice, address(fee), "Neko", "NEKO");
        IFoboFactory.LaunchParams memory lp = _signedBy(
            startSignerKey, alice, address(fee), "Neko", "NEKO", s, 1_000_000e18, mid, vm.getBlockTimestamp() + 1 hours
        );
        vm.prank(alice);
        vm.expectRevert(); // the PoolManager's CurrencyNotSettled (what arrived is less than what was sent)
        factory.launch{value: FEE}(lp);
        // without the buy it launches, and the first trade in it reverts the same way: nothing a holder could lose
        lp = _signedBy(startSignerKey, alice, address(fee), "Neko", "NEKO", s, 0, mid, vm.getBlockTimestamp() + 1 hours);
        vm.prank(alice);
        (address neko,) = factory.launch{value: FEE}(lp);
        PoolKey memory k = hook.keyFor(address(fee), neko);
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            ""
        );
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
