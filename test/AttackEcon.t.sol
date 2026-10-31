// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FoboFactory} from "../src/FoboFactory.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {FoboHook} from "../src/FoboHook.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {FloorMath} from "../src/libraries/FloorMath.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {FoboBase} from "./Fobo.t.sol";

/// Economic attack scenarios, kept as regression tests. Every scenario logs PnL after taxes (forge test
/// --mc AttackEcon -vv); every attack asserts the attacker loses and the honest holder keeps the surplus. The snipe
/// tax's economics (E1, E9, E11, E12: who ends up with a sniper's tax) assert the owner's decision (README §5): 60% joins
/// the floor over 10 minutes, 40% buys back and burns $FOBO, so no sniper or creator ever gets the burn share back, and
/// an empty pool's floor money (its whole snipe pot included, vested or not) goes to the burn instead of the next buyer.
/// E14: floor money a pool's few holders can't carry leaves too, instead of waiting for a buyer past the next tranche.
contract AttackEcon is FoboBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant T0 = 1_700_000_000;

    // ------------------------------------------------------------------ helpers

    /// the next block (as the hook counts blocks), some seconds later
    function _win(uint256 secs) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    function _sellAll(address who, PoolKey memory key) internal returns (uint256 got) {
        address tok = Currency.unwrap(key.currency1);
        uint256 bal = FoboToken(tok).balanceOf(who);
        if (bal == 0) return 0;
        _approve(who, tok);
        uint256 b0 = who.balance;
        _swap(who, key, false, -int256(bal), 0);
        got = who.balance - b0;
    }

    function _pokeWindows(PoolKey memory key, uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _win(12);
            hook.poke(key);
        }
    }

    function _logPnl(string memory what, uint256 paid, uint256 got) internal {
        emit log_named_decimal_int(what, int256(got) - int256(paid), 18);
    }

    function _ethChild(address creator, string memory name, uint256 dev, uint256 value)
        internal
        returns (PoolKey memory k)
    {
        bytes32 s = keccak256(abi.encode(name));
        vm.prank(creator);
        (address tok,) = factory.launch{value: value}(_signedEth(creator, name, name, s, dev, FOBO_TICK));
        k = hook.keyFor(address(0), tok);
    }

    // ------------------------------------------------------------------ E1: the snipe tax a patient sniper gets back

    /// A lone sniper pays 90% at second 0, holds 11 minutes while the snipe pot vests, then sells. The vested floor share
    /// buys back and burns for him (he is the only holder), but the 40% burn share is gone: he pays at least 36%.
    function test_E1_loneSniperGetsTaxBack() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        address sn = _user("sniper");
        _swap(sn, k, true, -10 ether, 10 ether); // s = 0: 9 ETH tax, 5.4 to the snipe pot, 3.6 to the burn
        _pokeWindows(k, 56); // ~11 minutes of windows; anyone (or trading) triggers these
        uint256 got = _sellAll(sn, k);
        _logPnl("E1 lone sniper: 10 ETH at s=0, sells at 11 min, PnL", 10 ether, got);
        emit log_named_decimal_uint("    effective cost %", (10 ether - got) * 100e18 / 10 ether, 18);
        assertGe(10 ether - got, 3.6 ether, "a lone sniper pays at least 36% (the burn share)");
        assertApproxEqAbs(_burnerOwed(Currency.wrap(address(0))), 3.6 ether, 1, "owed to the $FOBO burn");
    }

    /// Sniper at s=0 vs. organic buyers at s=61. Everyone exits at 11 minutes, sniper first. Compared with the same organic
    /// flow without the sniper, and with a sniper who waits to s=61 (base rate).
    function test_E1b_sniperVsOrganic() public {
        _launchFobo();
        uint256 snap = vm.snapshotState();
        uint256 sniperGot;
        uint256 orgWithSniper;
        for (uint256 mode; mode < 3; mode++) {
            // mode 0: sniper at s=0; mode 1: no sniper; mode 2: "sniper" buys at s=61 first (base rate)
            PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
            address sn = _user("sniper");
            uint256 t0 = vm.getBlockTimestamp();
            if (mode == 0) _swap(sn, k, true, -10 ether, 10 ether);
            _win(61);
            if (mode == 2) _swap(sn, k, true, -10 ether, 10 ether);
            address[5] memory org;
            for (uint256 i; i < 5; i++) {
                org[i] = _user(string(abi.encodePacked("org", vm.toString(i))));
                _swap(org[i], k, true, -2 ether, 2 ether);
                _win(12);
            }
            while (vm.getBlockTimestamp() < t0 + 11 minutes) {
                _win(12);
                hook.poke(k);
            }
            uint256 gs = _sellAll(sn, k);
            uint256 go;
            for (uint256 i; i < 5; i++) {
                go += _sellAll(org[i], k);
            }
            if (mode == 0) {
                _logPnl("E1b mode0 sniper(10 ETH @ s=0) PnL", 10 ether, gs);
                _logPnl("E1b mode0 organic total (10 ETH @ s>=61) PnL", 10 ether, go);
                (sniperGot, orgWithSniper) = (gs, go);
            } else if (mode == 1) {
                _logPnl("E1b mode1 organic total, no sniper, PnL", 10 ether, go);
            } else {
                _logPnl("E1b mode2 early buyer (10 ETH @ s=61) PnL", 10 ether, gs);
                _logPnl("E1b mode2 organic total PnL", 10 ether, go);
                assertGe(gs, sniperGot + 3.6 ether, "sniping at s=0 costs at least 36% more than buying at s=61");
                assertGe(orgWithSniper, go, "organic buyers do better behind a sniper than behind an early buyer");
            }
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ E2: stranded floor money, captured in one window

    /// The MAX_BACKING_RATIO state: a sniper rugged, almost nobody holds, the vested pot can't buy back. The first buyer
    /// of a window turns the ratio on with its own buy; its own swap's afterSwap runs the buyback, lifting the price over
    /// its tokens; it sells in the same window (same tx in practice).
    function test_E2_strandedPotOneWindowCapture() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        address sn = _user("sniper");
        address carol = _user("carol");
        _swap(sn, k, true, -100 ether, 100 ether); // 90 ETH snipe pot
        _win(61);
        _swap(carol, k, true, -0.1 ether, 0.1 ether);
        _win(4 minutes);
        uint256 snGot = _sellAll(sn, k);
        _logPnl("E2 sniper rug PnL", 100 ether, snGot);
        _win(2 hours);
        hook.poke(k); // fully vested; ratio blocks the buyback
        uint256 carolBefore = _exitValueK(carol, k);
        emit log_named_decimal_uint("E2 carol exit value before eve (paid 0.1)", carolBefore, 18);
        assertGt(carolBefore, 25 ether, "the holder gets the floor share of the stranded snipe tax (54 ETH)");
        uint256[5] memory sizes = [uint256(0.05 ether), 0.2 ether, 1 ether, 5 ether, 20 ether];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            _win(12);
            address eve = _user("eve");
            uint256 e0 = eve.balance;
            _swap(eve, k, true, -int256(sizes[i]), sizes[i]); // first swap of the window: the buyback runs after it
            _sellAll(eve, k); // same window
            emit log_named_decimal_uint("E2 eve buy size", sizes[i], 18);
            _logPnl("   eve one-window PnL", e0, eve.balance);
            assertLt(eve.balance, e0, "one-window capture loses");
            emit log_named_decimal_uint("   carol exit value after", _exitValueK(carol, k), 18);
            // and repeated every window for 20 windows
            uint256 tot = e0;
            for (uint256 w; w < 20; w++) {
                _win(12);
                uint256 b0 = eve.balance;
                _swap(eve, k, true, -int256(sizes[i]), sizes[i]);
                _sellAll(eve, k);
                if (eve.balance < b0) break;
            }
            _logPnl("   eve PnL after up to 20 more windows", tot, eve.balance);
            assertLt(eve.balance, tot, "repeating it loses");
            assertGe(_exitValueK(carol, k) + 2, carolBefore, "the holder keeps it");
            emit log_named_decimal_uint("   carol exit value after all", _exitValueK(carol, k), 18);
            vm.revertToState(snap);
        }
    }

    function _uniqSalt(address launcher, address quote, string memory nm, uint256 i) internal view returns (bytes32 s) {
        for (uint256 j = i * 1000;; j++) {
            s = bytes32(j);
            if (factory.predictToken(launcher, s, nm, nm) > quote) return s;
        }
    }

    function _exitValueK(address who, PoolKey memory k) internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        got = _sellAll(who, k);
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ E3: JIT harvest of the vesting snipe pot

    /// A sniper rugs at minute 2 while 80% of the snipe pot is still vesting. Each window releases ~1/50 of it and buys
    /// back. Eve buys as the window's first swap (the buyback runs in her afterSwap) and sells in the same window.
    function test_E3_vestingJitHarvest() public {
        _launchFobo();
        uint256 snap = vm.snapshotState();
        uint256 carolNoEve;
        for (uint256 mode; mode < 2; mode++) {
            PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
            uint256 t0 = vm.getBlockTimestamp();
            address sn = _user("sniper");
            address carol = _user("carol");
            address eve = _user("eve");
            _swap(sn, k, true, -20 ether, 20 ether);
            _win(61);
            _swap(carol, k, true, -1 ether, 1 ether);
            _win(60);
            _sellAll(sn, k); // rug at minute 2
            uint256 e0 = eve.balance;
            uint256 jits;
            while (vm.getBlockTimestamp() < t0 + 11 minutes) {
                _win(12);
                if (mode == 1) {
                    _swap(eve, k, true, -2 ether, 2 ether);
                    _sellAll(eve, k);
                    jits++;
                } else {
                    hook.poke(k);
                }
            }
            uint256 c = _sellAll(carol, k);
            if (mode == 0) {
                carolNoEve = c;
                emit log_named_decimal_uint("E3 carol exit (paid 1 ETH), no JIT", c, 18);
            } else {
                emit log_named_decimal_uint("E3 carol exit (paid 1 ETH), with eve's JIT", c, 18);
                emit log_named_uint("   eve JIT windows", jits);
                _logPnl("   eve total PnL", e0, eve.balance);
                assertLt(eve.balance, e0, "the JIT loses");
                assertGe(c, carolNoEve, "the holder loses nothing to it");
            }
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ E4: $FOBO's snipe window bypassed via the factory

    /// During $FOBO's own snipe window, a $FOBO-pair launch's dev buy used to pay ETH -> $FOBO through the $FOBO pool with
    /// the factory as sender, at the base 2.5%: a bot with max dev buys bought $FOBO at the bottom of its curve. Now a
    /// $FOBO pair's dev buy is paid in $FOBO the launcher already holds: ETH alone can't launch one, and the launch's
    /// only $FOBO-pool swap is the fee swap, at the snipe rate (test_factoryPaysTheBaseRateOnlyOnItsOwnLaunch).
    function test_E4_childLaunchIsNoWayIntoFobo() public {
        _launchFobo();
        vm.warp(T0 + 1);
        address bot = _user("bot");
        bytes32 s = _uniqSalt(bot, fobo, "C0", 0);
        vm.prank(bot);
        vm.expectRevert(); // FoboToken: no allowance, no balance
        factory.launch{value: 1000 ether}(_signed(bot, "C0", "C0", s, 50_000_000e18, 0));
        vm.prank(bot);
        factory.launch{value: 1000 ether}(_signed(bot, "C0", "C0", s, 0, 0));
        assertEq(FoboToken(fobo).balanceOf(bot), 0, "a launch hands the launcher no $FOBO");
    }

    // ------------------------------------------------------------------ E1c: fair exit order

    /// Same as E1b mode 0 but the organic buyers exit first and the sniper last.
    function test_E1c_sniperExitsLast() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        uint256 t0 = vm.getBlockTimestamp();
        address sn = _user("sniper");
        _swap(sn, k, true, -10 ether, 10 ether);
        _win(61);
        address[5] memory org;
        for (uint256 i; i < 5; i++) {
            org[i] = _user(string(abi.encodePacked("org", vm.toString(i))));
            _swap(org[i], k, true, -2 ether, 2 ether);
            _win(12);
        }
        while (vm.getBlockTimestamp() < t0 + 11 minutes) {
            _win(12);
            hook.poke(k);
        }
        uint256 go;
        for (uint256 i; i < 5; i++) {
            go += _sellAll(org[i], k);
        }
        uint256 gs = _sellAll(sn, k);
        _logPnl("E1c organic total (exit first) PnL", 10 ether, go);
        _logPnl("E1c sniper (10 ETH @ s=0, exits last) PnL", 10 ether, gs);
        assertGe(10 ether - gs, 3.6 ether, "the sniper pays at least 36%");
    }

    // ------------------------------------------------------------------ E2b: the sniper recaptures his own stranded tax

    function test_E2b_sniperRugsThenRecapturesOwnTax() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        address sn = _user("sniper");
        address carol = _user("carol");
        uint256 s0 = sn.balance;
        _swap(sn, k, true, -100 ether, 100 ether); // 90 ETH snipe tax
        _win(61);
        _swap(carol, k, true, -0.1 ether, 0.1 ether);
        _win(4 minutes);
        _sellAll(sn, k); // rug: takes his curve money and a share of what vested
        _win(7 minutes); // the pot finishes vesting; the ratio blocks the buyback
        hook.poke(k);
        _win(12);
        _swap(sn, k, true, -1 ether, 1 ether); // first swap of the window: the buyback runs after it
        _sellAll(sn, k);
        _logPnl("E2b sniper total PnL (paid 100 ETH at s=0)", s0, sn.balance);
        emit log_named_decimal_uint("    effective snipe tax %", (s0 - sn.balance) * 100e18 / 100 ether, 18);
        emit log_named_decimal_uint("    carol exit (paid 0.1)", _exitValueK(carol, k), 18);
        assertGt(s0 - sn.balance, 40 ether, "the sniper doesn't get his stranded tax back");
        assertGt(_exitValueK(carol, k), 25 ether, "the holder does");
    }

    // ------------------------------------------------------------------ E5: sandwiching a $FOBO-pair dev buy

    /// The $FOBO-pair dev buy used to pay ETH -> $FOBO at the in-transaction price, so a same-block $FOBO pump made it cost
    /// more. Now it is paid in $FOBO on the fresh pool, at the signed tick: a pump before the launch (the band reads
    /// $FOBO's start-of-block tick) doesn't change what it costs, so there is nothing to sandwich.
    function test_E5_devBuySandwich() public {
        _launchFobo();
        _win(61);
        address o = _user("organic");
        _swap(o, foboKey, true, -20 ether, 20 ether); // $FOBO has some depth
        _win(12);
        hook.poke(foboKey);
        _win(12);
        int24 ft = _tick(foboKey);
        int24 ts = (FOBO_TICK - ft) / 60 * 60;
        address victim = _user("victim");
        _fundFobo(victim, 20 ether);
        bytes32 s = _uniqSalt(victim, fobo, "V", 1);
        IFoboFactory.LaunchParams memory lp = _signed(victim, "V", "V", s, 50_000_000e18, ts);
        uint256 snap = vm.snapshotState();
        uint256 f0 = FoboToken(fobo).balanceOf(victim);
        vm.recordLogs();
        vm.prank(victim);
        factory.launch{value: 10 ether}(lp);
        uint256 fair = f0 - FoboToken(fobo).balanceOf(victim); // its creator fee is owed to it, not paid back in the swap
        emit log_named_decimal_uint("E5 victim's 5% dev buy, in $FOBO, no sandwich", fair, 18);
        vm.revertToState(snap);
        lp.devBuyMaxCost = fair;
        uint256[5] memory xs = [uint256(0.05 ether), 1 ether, 5 ether, 20 ether, 80 ether];
        for (uint256 i; i < xs.length; i++) {
            snap = vm.snapshotState();
            _swap(_user("eve"), foboKey, true, -int256(xs[i]), xs[i]);
            f0 = FoboToken(fobo).balanceOf(victim);
            vm.prank(victim);
            factory.launch{value: 10 ether}(lp);
            assertEq(f0 - FoboToken(fobo).balanceOf(victim), fair, "a $FOBO pump doesn't move the dev buy's cost");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ E9: the creator's dev buy rides the snipers' tax

    function test_E9_creatorDevBuyRidesSnipeTax() public {
        _launchFobo();
        address cr = _user("creator");
        uint256 c0 = cr.balance;
        PoolKey memory k = _ethChild(cr, "K", 50_000_000e18, 1 ether);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 devCost = c0 - cr.balance;
        emit log_named_decimal_uint("E9 creator paid (fee + 5% dev buy)", devCost, 18);
        address[3] memory sn;
        uint256 tax;
        for (uint256 i; i < 3; i++) {
            sn[i] = _user(string(abi.encodePacked("sn", vm.toString(i))));
            vm.warp(t0 + i * 10);
            _swap(sn[i], k, true, -2 ether, 2 ether); // snipers at s = 0, 10, 20
            uint256 s = i * 10;
            tax += (2 ether * (900_000 - 875_000 * s / 60) + 999_999) / 1_000_000;
        }
        uint256 burnShare = _burnerOwed(Currency.wrap(address(0)));
        assertApproxEqAbs(burnShare, tax * 40 / 100, 3, "40% of the snipers' tax to the $FOBO burn");
        while (vm.getBlockTimestamp() < t0 + 11 minutes) {
            _win(12);
            hook.poke(k);
        }
        uint256 got = _sellAll(cr, k);
        _logPnl("E9 creator PnL selling the dev buy at 11 min (excl. creator fees)", devCost, got);
        (,, uint256 owed,,) = _pool(k);
        emit log_named_decimal_uint("    creator fees owed", owed, 18);
        uint256 gs;
        for (uint256 i; i < 3; i++) {
            gs += _sellAll(sn[i], k);
        }
        _logPnl("    snipers total PnL (6 ETH)", 6 ether, gs);
        // the creator rides the floor share (60%) like any holder, never the burn share
        assertLt(int256(got) - int256(devCost), int256(tax - burnShare), "the creator gets at most the floor share");
        assertLe(owed, 6 ether * 6 / 1000, "no creator fees from the snipe window");
        assertGe(6 ether - gs, burnShare, "the snipers lose at least the burn share");
    }

    function test_E2trace() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        address sn = _user("sniper");
        address carol = _user("carol");
        _swap(sn, k, true, -100 ether, 100 ether);
        _win(61);
        _swap(carol, k, true, -0.1 ether, 0.1 ether);
        _win(4 minutes);
        _sellAll(sn, k);
        _win(2 hours);
        hook.poke(k);
        uint256 sz = vm.envOr("SZ", uint256(20 ether));
        (int24 f0, uint256 pot0,,, uint128 lb0) = _pool(k);
        emit log_named_int("tick before", _tick(k));
        emit log_named_int("tickF before", f0);
        emit log_named_decimal_uint("pot before", pot0, 18);
        emit log_named_uint("liqBand before", lb0);
        (uint128 sp, uint128 rel) = _snipe(k);
        emit log_named_decimal_uint("snipePot", sp, 18);
        emit log_named_decimal_uint("released", rel, 18);
        emit log_named_decimal_uint("PM eth", address(pm).balance, 18);
        _win(12);
        address eve = _user("eve");
        uint256 e0 = eve.balance;
        vm.recordLogs();
        _swap(eve, k, true, -int256(sz), sz);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IFoboHook.BoughtBack.selector) {
                (uint256 b, uint160 sq) = abi.decode(logs[i].data, (uint256, uint160));
                emit log_named_decimal_uint("BoughtBack burned", b, 18);
                sq;
            }
            if (logs[i].topics[0] == IFoboHook.FloorRaised.selector) {
                (int24 tf,, uint256 q, uint256 c) = abi.decode(logs[i].data, (int24, uint160, uint256, uint256));
                emit log_named_int("FloorRaised tickF", tf);
                emit log_named_decimal_uint("  quoteInFloor", q, 18);
                emit log_named_decimal_uint("  circulating", c, 18);
            }
            if (logs[i].topics[0] == IFoboHook.RaiseFailed.selector) emit log("RaiseFailed");
        }
        emit log_named_int("tick after buy", _tick(k));
        emit log_named_decimal_uint("eve tokens", FoboToken(Currency.unwrap(k.currency1)).balanceOf(eve), 18);
        _sellAll(eve, k);
        emit log_named_int("tick after sell", _tick(k));
        _logPnl("eve PnL", e0, eve.balance);
        assertLt(eve.balance, e0, "the capture loses");
    }

    /// E2 with a one-window hold: eve buys, the next window's raise (poke or anyone's swap) buys back with her as the
    /// main holder, she sells. Defeats any fix that only looks at the start-of-window state.
    function test_E2c_strandedPotOneWindowHold() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        address sn = _user("sniper");
        address carol = _user("carol");
        _swap(sn, k, true, -100 ether, 100 ether);
        _win(61);
        _swap(carol, k, true, -0.1 ether, 0.1 ether);
        _win(4 minutes);
        _sellAll(sn, k);
        _win(2 hours);
        hook.poke(k);
        _win(12);
        address eve = _user("eve");
        uint256 e0 = eve.balance;
        _swap(eve, k, true, -1 ether, 1 ether);
        _win(12);
        hook.poke(k);
        _sellAll(eve, k);
        _logPnl("E2c eve PnL (1 ETH, held one window)", e0, eve.balance);
        assertLt(eve.balance, e0, "holding one window loses");
        emit log_named_decimal_uint("    carol exit (paid 0.1)", _exitValueK(carol, k), 18);
    }

    /// No rug, no stranding: the snipe pot simply vests while nobody trades or pokes (a quiet pool). The first swap
    /// after the quiet spell releases everything vested; in the current code its afterSwap sees the post-pump price.
    function test_E2d_quietPoolVestCapture() public {
        _launchFobo();
        uint256[4] memory xs = [uint256(1 ether), 3 ether, 10 ether, 30 ether];
        for (uint256 i; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
            address sn = _user("sniper");
            address carol = _user("carol");
            _swap(sn, k, true, -10 ether, 10 ether); // 9 ETH snipe pot
            _win(61);
            _swap(carol, k, true, -2 ether, 2 ether);
            _win(10 minutes); // quiet: nothing released yet beyond the first raise
            uint256 holdersBefore = _exitValueK(carol, k);
            address eve = _user("eve");
            uint256 e0 = eve.balance;
            _swap(eve, k, true, -int256(xs[i]), xs[i]);
            _sellAll(eve, k);
            emit log_named_decimal_uint("E2d eve pump size", xs[i], 18);
            _logPnl("    eve same-window PnL", e0, eve.balance);
            emit log_named_decimal_uint("    carol exit before / after", holdersBefore, 18);
            emit log_named_decimal_uint("                               ", _exitValueK(carol, k), 18);
            assertLt(eve.balance, e0, "the pump loses");
            assertGe(_exitValueK(carol, k) + 2, holdersBefore, "the holder loses nothing to it");
            vm.revertToState(snap);
        }
    }

    /// A rug in a quiet pool (no MAX_BACKING_RATIO involved): the sniper sells at minute 2, then nobody trades or pokes
    /// until minute 11. The first swap after the quiet spell releases the rest of the snipe pot; eve's pump is that swap.
    function test_E2e_quietRugVestCapture() public {
        _launchFobo();
        uint256[5] memory xs = [uint256(0.5 ether), 1 ether, 3 ether, 10 ether, 30 ether];
        for (uint256 i; i < 5; i++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
            address sn = _user("sniper");
            address carol = _user("carol");
            _swap(sn, k, true, -10 ether, 10 ether); // 9 ETH snipe pot
            _win(61);
            _swap(carol, k, true, -1 ether, 1 ether);
            _win(60);
            _sellAll(sn, k); // rug at minute 2
            _win(9 minutes); // quiet
            uint256 snap2 = vm.snapshotState();
            hook.poke(k);
            uint256 fair = _exitValueK(carol, k);
            vm.revertToState(snap2);
            address eve = _user("eve");
            uint256 e0 = eve.balance;
            _swap(eve, k, true, -int256(xs[i]), xs[i]);
            _sellAll(eve, k);
            emit log_named_decimal_uint("E2e eve pump size", xs[i], 18);
            _logPnl("    eve same-window PnL", e0, eve.balance);
            emit log_named_decimal_uint("    carol exit if poked first (paid 1)", fair, 18);
            emit log_named_decimal_uint("    carol exit after eve", _exitValueK(carol, k), 18);
            assertLt(eve.balance, e0, "the pump loses");
            assertGe(_exitValueK(carol, k) + 2, fair, "the holder gets what a poke would have given her");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ E10: cheap wash volume for a creator-holder

    /// The creator holds most of the circulating supply, wash-trades 1 ETH round trips, collects the 0.6% creator share
    /// and gets most of the 1.5% floor share back through the buyback. What fake volume costs per ETH.
    function test_E10_creatorWashVolumeCost() public {
        _launchFobo();
        address cr = _user("creator");
        uint256 c0 = cr.balance;
        PoolKey memory k = _ethChild(cr, "K", 50_000_000e18, 1 ether);
        _win(61);
        _swap(cr, k, true, -2 ether, 2 ether); // the creator is the main holder
        address org = _user("org");
        _swap(org, k, true, -0.3 ether, 0.3 ether);
        uint256 vol;
        for (uint256 i; i < 100; i++) {
            _win(12);
            uint256 bal0 = FoboToken(Currency.unwrap(k.currency1)).balanceOf(cr);
            _swap(cr, k, true, -1 ether, 1 ether);
            uint256 got = FoboToken(Currency.unwrap(k.currency1)).balanceOf(cr) - bal0;
            _approve(cr, Currency.unwrap(k.currency1));
            _swap(cr, k, false, -int256(got), 0);
            vol += 2 ether;
        }
        _pokeWindows(k, 5);
        hook.claimCreator(k, _creatorOf(k));
        _sellAll(cr, k);
        int256 pnl = int256(cr.balance) - int256(c0);
        // reference: the same entry and exit without the wash trades
        emit log_named_decimal_uint("E10 wash volume (ETH, both legs)", vol, 18);
        emit log_named_decimal_int("    creator total PnL incl. entry/exit (ETH)", pnl, 18);
        emit log_named_decimal_uint("    org exit (paid 0.3)", _exitValueK(org, k), 18);
        assertLt(pnl, 0, "wash volume costs the creator");
    }

    function test_E10b_creatorNoWashReference() public {
        _launchFobo();
        address cr = _user("creator");
        uint256 c0 = cr.balance;
        PoolKey memory k = _ethChild(cr, "K", 50_000_000e18, 1 ether);
        _win(61);
        _swap(cr, k, true, -2 ether, 2 ether);
        address org = _user("org");
        _swap(org, k, true, -0.3 ether, 0.3 ether);
        _pokeWindows(k, 105);
        hook.claimCreator(k, _creatorOf(k));
        _sellAll(cr, k);
        emit log_named_decimal_int("E10b creator PnL without wash (ETH)", int256(cr.balance) - int256(c0), 18);
        emit log_named_decimal_uint("    org exit (paid 0.3)", _exitValueK(org, k), 18);
    }

    // ------------------------------------------------------------------ E11, E12: who gets a sniper's tax

    /// A sniper rugs at minute 2; eve buys right after and holds 1-50 windows while the rest of the snipe pot vests, then
    /// sells. Every window's release buys back for whoever holds then, so a holder through the vest earns a share of the
    /// floor's 60% (the owner's decision, README §5), never of the 40% burn share.
    function test_E11_holdThroughTheVestAfterARug() public {
        _launchFobo();
        uint256[3] memory sizes = [uint256(0.5 ether), 2 ether, 10 ether];
        uint256[4] memory holds = [uint256(1), 5, 25, 50];
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 h; h < holds.length; h++) {
                uint256 snap = vm.snapshotState();
                PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
                address sn = _user("sniper");
                address eve = _user("eve");
                _swap(sn, k, true, -20 ether, 20 ether); // 18 ETH tax: 10.8 floor, 7.2 burn
                _win(61);
                _swap(_user("carol"), k, true, -1 ether, 1 ether);
                _win(60);
                _sellAll(sn, k);
                _win(12);
                hook.poke(k);
                uint256 e0 = eve.balance;
                _swap(eve, k, true, -int256(sizes[i]), sizes[i]);
                _pokeWindows(k, holds[h]);
                _sellAll(eve, k);
                emit log_named_decimal_uint("E11 eve buys", sizes[i], 18);
                emit log_named_uint("    and holds windows", holds[h]);
                _logPnl("    eve PnL", e0, eve.balance);
                assertLt(int256(eve.balance) - int256(e0), 10.8 ether, "at most the floor share");
                assertGe(_burnerOwed(Currency.wrap(address(0))), 7.2 ether, "the burn share stays with the burn");
                vm.revertToState(snap);
            }
        }
    }

    /// The lone sniper sells everything at minute 1: nobody holds while the other 90% of the snipe pot vests. It used to
    /// lift the empty pool to the next tranche's start ($1b at a $10k start) and wait in the band for whoever bought
    /// next (+6.5 ETH on 30 ETH); then the drain took only what had vested, so a buyer right after it collected the rest
    /// as it vested (audit M-1: +4.66 ETH on 0.1 ETH). Now the empty pool's first drain sends the whole snipe pot left
    /// to the $FOBO burn (_drain): the price doesn't move and no next buyer, arriving right after the drain, mid-vest
    /// or after it, of any size or patience, makes money.
    function test_E12_deadPoolVest() public {
        _launchFobo();
        uint256[5] memory sizes = [uint256(0.02 ether), 0.1 ether, 1 ether, 5 ether, 30 ether];
        uint256[3] memory arrivals = [uint256(1), 20, 50]; // windows after the exit: right after the drain, mid-vest, after
        uint256[3] memory holds = [uint256(0), 1, 50];
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 a; a < arrivals.length; a++) {
                for (uint256 h; h < holds.length; h++) {
                    uint256 snap = vm.snapshotState();
                    PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
                    address sn = _user("sniper");
                    address eve = _user("eve");
                    _swap(sn, k, true, -10 ether, 10 ether); // 9 ETH tax: 5.4 snipe pot, 3.6 burn
                    _win(61);
                    uint256 sg = _sellAll(sn, k);
                    int24 tOut = _tick(k);
                    uint256 burn0 = _burnerOwed(Currency.wrap(address(0)));
                    (uint128 sp, uint128 rel) = _snipe(k);
                    uint256 left = sp - rel; // what hadn't vested by the exit (4.8 of 5.4)
                    _pokeWindows(k, 1);
                    (sp, rel) = _snipe(k);
                    assertEq(rel, sp, "the first drain sends the whole snipe pot, vested or not");
                    assertGe(_burnerOwed(Currency.wrap(address(0))) - burn0, left, "to the burn");
                    _pokeWindows(k, arrivals[a] - 1);
                    assertEq(_tick(k), tOut, "no lift in an empty pool");
                    if (i == 0 && a == 0 && h == 0) {
                        _logPnl("E12 lone sniper (10 ETH at s=0, out at minute 1) PnL", 10 ether, sg);
                        (int24 tf, uint256 pot,,, uint128 lb) = _pool(k);
                        emit log_named_int("    tickF", tf);
                        emit log_named_decimal_uint("    pot", pot, 18);
                        emit log_named_uint("    liqBand", lb);
                        (,, uint256 circ) = hook.floorOf(k);
                        emit log_named_uint("    circulating (wei)", circ);
                    }
                    uint256 e0 = eve.balance;
                    _swap(eve, k, true, -int256(sizes[i]), sizes[i]);
                    _pokeWindows(k, holds[h]);
                    _sellAll(eve, k);
                    if (h == holds.length - 1) {
                        emit log_named_decimal_uint("E12 next buyer buys", sizes[i], 18);
                        emit log_named_uint("    windows after the exit", arrivals[a]);
                        emit log_named_uint("    and holds windows", holds[h]);
                        _logPnl("    PnL", e0, eve.balance);
                    }
                    assertLt(eve.balance, e0, "the next buyer gets nothing left under the price");
                    vm.revertToState(snap);
                }
            }
        }
    }

    /// E12 inside the snipe window: the lone sniper sells everything at second 30. The next block's drain sends the whole
    /// snipe pot to the burn, so a buyer arriving while the window or the vest still runs (second 31 to minute 2) gets
    /// none of it, however long it holds: only its own snipe tax's floor share comes back to it (it vests only once the
    /// schedule passes what the drain released, still in full by SNIPE_VEST), never what it paid to the burn.
    function test_E12c_exitInsideTheWindow() public {
        _launchFobo();
        uint256[3] memory sizes = [uint256(0.1 ether), 1 ether, 10 ether];
        uint256[5] memory arrivals = [uint256(31), 45, 59, 61, 120]; // seconds after launch
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 a; a < arrivals.length; a++) {
                uint256 snap = vm.snapshotState();
                PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
                uint256 t0 = vm.getBlockTimestamp();
                address sn = _user("sniper");
                address eve = _user("eve");
                _swap(sn, k, true, -10 ether, 10 ether);
                _win(30);
                _sellAll(sn, k); // out at second 30: empty pool inside the window
                _win(1);
                hook.poke(k); // the drain
                (uint128 sp, uint128 rel) = _snipe(k);
                assertEq(rel, sp, "the drain sends the whole snipe pot");
                vm.warp(t0 + arrivals[a]);
                uint256 e0 = eve.balance;
                _swap(eve, k, true, -int256(sizes[i]), sizes[i]);
                _pokeWindows(k, 55); // through the end of the vest
                (sp, rel) = _snipe(k);
                assertEq(rel, sp, "tax paid after the drain vested in full by SNIPE_VEST");
                _sellAll(eve, k);
                emit log_named_decimal_uint("E12c next buyer buys", sizes[i], 18);
                emit log_named_uint("    at second", arrivals[a]);
                _logPnl("    PnL after holding through the vest", e0, eve.balance);
                assertLt(eve.balance, e0, "no buyer after an exit inside the window makes money");
                vm.revertToState(snap);
            }
        }
    }

    /// E12 with dust left behind: the sniper keeps 10,000 tokens (above EMPTY_CIRCULATING) so the pool isn't empty. The
    /// floor never holds more than those tokens can carry up to the next tranche's start (Ctx.cap): the rest goes to the
    /// burn instead of waiting under a $1b price for the next big buyer.
    function test_E12b_dustHolderVest() public {
        _launchFobo();
        uint256[4] memory sizes = [uint256(0.1 ether), 1 ether, 5 ether, 30 ether];
        uint256[3] memory holds = [uint256(0), 1, 5];
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 h; h < holds.length; h++) {
                uint256 snap = vm.snapshotState();
                PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
                address sn = _user("sniper");
                address eve = _user("eve");
                address tok = Currency.unwrap(k.currency1);
                uint256 s0 = sn.balance;
                _swap(sn, k, true, -10 ether, 10 ether);
                _win(61);
                _approve(sn, tok);
                _swap(sn, k, false, -int256(FoboToken(tok).balanceOf(sn) - 10_000e18), 0);
                _pokeWindows(k, 50);
                if (i == 0 && h == 0) {
                    (uint128 sp, uint128 rel) = _snipe(k);
                    emit log_named_decimal_uint("E12b snipe pot left unreleased", sp - rel, 18);
                    emit log_named_decimal_uint(
                        "E12b burn owed after the vest (of 3.6 + 5.4)", _burnerOwed(Currency.wrap(address(0))), 18
                    );
                    emit log_named_int("    tick after the vest (start 193800)", _tick(k));
                    uint256 dust = _exitValueK(sn, k);
                    emit log_named_decimal_uint("    the dust's exit value", dust, 18);
                    _logPnl("    sniper PnL incl. the dust", s0, sn.balance + dust);
                }
                uint256 e0 = eve.balance;
                _swap(eve, k, true, -int256(sizes[i]), sizes[i]);
                _pokeWindows(k, holds[h]);
                _sellAll(eve, k);
                emit log_named_decimal_uint("E12b next buyer buys", sizes[i], 18);
                emit log_named_uint("    and holds windows", holds[h]);
                _logPnl("    PnL", e0, eve.balance);
                assertLt(eve.balance, e0, "the next buyer gets nothing left under the price");
                vm.revertToState(snap);
            }
        }
    }

    // ------------------------------------------------------------------ E13: sandwiching the $FOBO buy-and-burn

    /// FoboBurner.buybackAndBurn buys $FOBO with the ETH snipe tax's burn share. Eve pumps $FOBO first (same block, or
    /// held from the block before so the start-of-block tick is hers), lets the keeper's buyback through (the largest
    /// that fits the bound, with no minimum: a keeper key at its worst), then sells. The buyback never takes the price
    /// more than ~1% past the start of the block, and she pays the pool's 2.5% each way.
    function test_E13_buyBurnSandwich() public {
        _launchFobo();
        _win(61);
        address o = _user("organic");
        _swap(o, foboKey, true, -20 ether, 20 ether); // $FOBO has some depth
        _win(12);
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        _swap(_user("sniper"), k, true, -50 ether, 50 ether); // 18 ETH owed to the burn
        uint256[6] memory xs = [uint256(0.01 ether), 0.05 ether, 0.2 ether, 1 ether, 5 ether, 20 ether];
        for (uint256 held; held < 2; held++) {
            for (uint256 i; i < xs.length; i++) {
                uint256 snap = vm.snapshotState();
                _win(12);
                address eve = _user("eve");
                _approve(eve, fobo);
                uint256 e0 = eve.balance;
                _swap(eve, foboKey, true, -int256(xs[i]), xs[i]);
                if (held == 1) _win(12); // her pump is the start-of-block price now
                uint256 burned = _buybackMax();
                _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
                emit log_named_decimal_uint(held == 1 ? "E13 pump held a block" : "E13 pump same block", xs[i], 18);
                emit log_named_decimal_uint("    $FOBO burned", burned, 18);
                _logPnl("    eve PnL", e0, eve.balance);
                assertLt(eve.balance, e0, "the sandwich loses");
                vm.revertToState(snap);
            }
        }
    }

    // ------------------------------------------------------------------ E14: floor money the holders can't carry

    /// Audit M-2: a whale pumps and exits, leaving a dust holder (2,000 tokens, above EMPTY_CIRCULATING) with the price
    /// just under the next tranche's start, where no raise or buyback can move. The floor held ~3.5 ETH behind 2,000
    /// tokens worth ~0.77 ETH even at that start: it waited there until a buyer pushed past the start, and the next raise
    /// put it under his price (+2.67 ETH on 50 ETH held 2 blocks). Now what the circulating tokens can't carry at the
    /// highest price a buyback may lift to (tranche 0's quote over the price counted) leaves for the burn (FloorSwept),
    /// both while the floor can't move (_planDrain) and in every rebuild (_rebuild): the buyer loses, however long he
    /// holds, and the dust holder keeps its exit.
    function test_E14_strandedFloorMoneyAfterAnExit() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        _win(61);
        address whale = _user("whale");
        address dust = _user("dust");
        _swap(whale, k, true, -400 ether, 400 ether);
        _swap(dust, k, true, 2_000e18, 1 ether); // exact-out: 2,000 tokens
        _win(12);
        _sellAll(whale, k);
        uint256 burn0 = _burnerOwed(Currency.wrap(address(0)));
        // the windows' buybacks lift the dust holder to what its tokens can carry, the rest leaves
        _pokeWindows(k, 20);
        uint256 swept = _burnerOwed(Currency.wrap(address(0))) - burn0;
        emit log_named_decimal_uint("E14 floor money swept after the exit", swept, 18);
        assertGt(swept, 2 ether, "what 2,000 tokens can't carry left for the burn");
        {
            (int24 tf, uint256 pot,,, uint128 lb) = _pool(k);
            (int24 s1,) = hook.trancheOf(k, 1);
            assertGe(_tick(k), s1, "the next tranche's start is not reached: no raise or buyback can move");
            uint160 sCap = TickMath.getSqrtPriceAtTick(s1);
            uint256 worth = FullMath.mulDiv(FullMath.mulDiv(2_000e18, FixedPoint96.Q96, sCap), FixedPoint96.Q96, sCap);
            uint256 bandQ =
                FloorMath.quote(TickMath.getSqrtPriceAtTick(tf), TickMath.getSqrtPriceAtTick(tf + 60), lb, true);
            emit log_named_decimal_uint("    band quote left (2,000 tokens' worth at the next start)", bandQ, 18);
            emit log_named_decimal_uint("    their worth there", worth, 18);
            assertLe(pot + bandQ, worth, "the floor keeps at most what they can carry");
            uint256 dustExit = _exitValueK(dust, k);
            emit log_named_decimal_uint("    dust holder exit value", dustExit, 18);
            // the same 0.742 ETH as before the fix: only money it could never reach left
            assertGe(dustExit, worth * 95 / 100, "the dust holder still exits at about its tokens' worth there");
        }
        uint256 dustBefore = _exitValueK(dust, k);
        uint256[4] memory holds = [uint256(1), 2, 3, 10];
        for (uint256 h; h < holds.length; h++) {
            uint256 snap = vm.snapshotState();
            address eve = _user("eve");
            uint256 e0 = eve.balance;
            _win(12);
            _swap(eve, k, true, -50 ether, 50 ether);
            for (uint256 w; w < holds[h]; w++) {
                _win(1); // Robinhood Chain: ~100 ms blocks
                hook.poke(k);
            }
            _sellAll(eve, k);
            emit log_named_uint("E14 eve buys 50 ETH past the start, holds blocks", holds[h]);
            _logPnl("    eve PnL", e0, eve.balance);
            assertLt(eve.balance, e0, "the buyer past the start gets none of it");
            assertGe(_exitValueK(dust, k), dustBefore * 99 / 100, "nor does the dust holder lose to him");
            vm.revertToState(snap);
        }
    }

    /// E14 after its drain: the pool sits at the cap (its floor money is what its 2,000 tokens can carry), and every swap
    /// adds a little tax to the pot. A drain needs more than 1/DRAIN_SLACK (1%) of the cap over it, so 30 blocks of dust
    /// trading sweep nothing (a wei-level drain every block used to cost each block's first swap ~95k gas), the dust
    /// holder keeps its exit, and floor money well over the cap still leaves.
    function test_E14b_poolAtTheCapDoesNotSweepEveryBlock() public {
        _launchFobo();
        PoolKey memory k = _ethChild(_user("creator"), "K", 0, 1 ether);
        _win(61);
        address whale = _user("whale");
        address dust = _user("dust");
        address eve = _user("eve");
        _swap(whale, k, true, -400 ether, 400 ether);
        _swap(dust, k, true, 2_000e18, 1 ether); // exact-out: 2,000 tokens
        _win(12);
        _sellAll(whale, k);
        _pokeWindows(k, 20); // the drains: at the cap now
        _approve(eve, Currency.unwrap(k.currency1));
        uint256 dustBefore = _exitValueK(dust, k);
        (int24 f0, uint256 pot0,,,) = _pool(k);
        vm.recordLogs();
        for (uint256 b; b < 30; b++) {
            _win(1);
            _swap(eve, k, true, -0.0001 ether, 0.0001 ether);
            _swap(eve, k, false, -0.1e18, 0);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.FloorSwept.selector, "no sweep at the cap");
            assertTrue(logs[i].topics[0] != IFoboHook.FloorRaised.selector, "nothing moved");
        }
        (int24 f1, uint256 pot1,,,) = _pool(k);
        assertEq(f1, f0, "the floor stayed");
        assertGt(pot1, pot0, "the dust's tax waits in the pot");
        assertGe(_exitValueK(dust, k), dustBefore, "the dust holder keeps its exit");
        // over 1% more than the cap: it leaves again
        for (uint256 i; i < 10; i++) {
            _win(1);
            _swap(eve, k, true, -1 ether, 1 ether);
            _sellAll(eve, k);
        }
        uint256 burn0 = _burnerOwed(Currency.wrap(address(0)));
        _win(1);
        hook.poke(k);
        assertGt(_burnerOwed(Currency.wrap(address(0))), burn0, "floor money over the cap still leaves");
        assertGe(_exitValueK(dust, k), dustBefore * 99 / 100, "and the dust holder keeps its exit");
    }
}
