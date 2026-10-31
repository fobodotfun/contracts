// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FoboHook} from "../src/FoboHook.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {FloorMath} from "../src/libraries/FloorMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FoboBase} from "./Fobo.t.sol";

/// Protocol auditor's three-pool accounting fuzz: $FOBO, an ETH pair and a $FOBO pair traded at random (exact-in and
/// exact-out buys, sells, claims, pokes, random block and time steps), then everyone exits. After every step the hook's
/// ERC-6909 claims equal what it owes in each currency (pots, unvested snipe tax, creator and team balances, dust
/// reserves: burn shares go to FoboBurner, never stay here; FoboBurner never gets $FOBO, a $FOBO pair's is burned), FoboRevenue's claims equal what it owes (referrers, 0-3 partners, the team;
/// some traders referred, partner list and both fees set at random, revenue claims among the steps), no floor ever
/// drops, every exit stops inside the band, and no raise ever fails. In half the runs every pool's dust reserve is
/// emptied before trading (review M-1: a reserve spent by rounding must never fail a raise); the claims it held are then
/// counted apart (`spent`).
/// A referrer with code (a smart wallet): FoboRevenue books its share (owed) instead of paying it in the swap
contract ContractReferrer {
    receive() external payable {}
}

contract AuditInvTest is FoboBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey[3] keys;
    int24[3] lastF;
    address[4] us;
    // everyone FoboRevenue may owe: the team, three partners, the traders, alice and a contract (the referrers u3, alice
    // and the contract: all owed, nobody is paid in a swap)
    address[10] payees;
    // dust reserve emptied by the test (its claims stay with the hook)
    uint256[3] spent;

    function _obl(PoolKey memory k) internal view returns (uint256) {
        (,,,,,,,, uint128 sp, uint128 rel,,, uint256 pot, uint256 cr,) = hook.pools(k.toId());
        return pot + sp - rel + cr;
    }

    function _reserve(PoolKey memory k) internal view returns (uint256 r) {
        (,,,, r,) = (0, 0, 0, 0, 0, 0);
        (,,,,,,,,,,,,,, r) = hook.pools(k.toId());
    }

    function _check() internal view {
        Currency eth = Currency.wrap(address(0));
        Currency fb = Currency.wrap(fobo);
        uint256 ethObl = _obl(keys[0]) + _obl(keys[1]) + hook.teamOwed(eth);
        uint256 foboObl = _reserve(keys[0]) + spent[0] + _obl(keys[2]) + hook.teamOwed(fb);
        assertEq(pm.balanceOf(address(hook), eth.toId()), ethObl, "ETH claims == obligations");
        assertEq(pm.balanceOf(address(hook), fb.toId()), foboObl, "FOBO claims == obligations");
        // a $FOBO pair's burn share is burned at once: FoboBurner never gets $FOBO
        assertEq(_burnerOwed(fb), 0, "no $FOBO claims in FoboBurner");
        for (uint256 i = 1; i < 3; i++) {
            assertEq(
                pm.balanceOf(address(hook), keys[i].currency1.toId()),
                _reserve(keys[i]) + spent[i],
                "token claims == reserve"
            );
        }
        uint256 revEth;
        uint256 revFobo;
        for (uint256 i; i < payees.length; i++) {
            revEth += revenue.owed(payees[i], address(0));
            revFobo += revenue.owed(payees[i], fobo);
        }
        assertEq(pm.balanceOf(address(revenue), eth.toId()), revEth, "FoboRevenue ETH claims == owed");
        assertEq(pm.balanceOf(address(revenue), fb.toId()), revFobo, "FoboRevenue FOBO claims == owed");
        for (uint256 i; i < 3; i++) {
            (,,,, int24 f,,,,,,,,,,) = hook.pools(keys[i].toId());
            assertLe(f, lastF[i], "floor never drops");
        }
    }

    function testFuzz_accountingAndFloors(uint256 seed) public {
        vm.recordLogs();
        _launchFobo();
        address alice = _user("alice");
        for (uint256 i; i < 4; i++) {
            us[i] = _user(string(abi.encodePacked("u", vm.toString(i))));
        }
        // revenue sharing: 0-3 partners, random partner and referral fees, and u0, u1 referred (by u3 and alice: owed, like
        // everyone), u2 referred by a contract (owed) halfway through (after trading unreferred: no first-trade lock), u3 never
        payees[0] = team;
        for (uint256 i; i < 3; i++) {
            payees[1 + i] = makeAddr(string(abi.encodePacked("partner", vm.toString(i))));
        }
        for (uint256 i; i < 4; i++) {
            payees[4 + i] = us[i];
        }
        payees[8] = alice;
        payees[9] = address(new ContractReferrer());
        // shares of the partner fee adding up to 100%; fees adding up to at most 100%
        uint256 np = (seed >> 200) % 4;
        address[] memory pr = new address[](np);
        uint16[] memory pb = new uint16[](np);
        uint256 left = 10_000;
        for (uint256 i; i < np; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16 b = i + 1 == np ? uint16(left) : uint16(1 + (seed >> (204 + 8 * i)) % 3_333);
            (pr[i], pb[i]) = (payees[1 + i], b);
            left -= b;
        }
        revenue.setPartners(pr, pb);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 partnerFee = np == 0 ? 0 : uint16(uint256(keccak256(abi.encode(seed, "partnerFee"))) % 10_001);
        uint256 refSeed = uint256(keccak256(abi.encode(seed, "referralFee")));
        // forge-lint: disable-next-line(unsafe-typecast)
        revenue.setFeePercent(partnerFee, uint16(refSeed % (10_001 - uint256(partnerFee))));
        address[] memory rt = new address[](2);
        address[] memory rr = new address[](2);
        (rt[0], rr[0], rt[1], rr[1]) = (us[0], us[3], us[1], alice);
        revenue.setRegistrar(address(this));
        assertEq(revenue.registerBy(rt, rr), 2, "both bound");
        // FOBO inventory
        for (uint256 i; i < 4; i++) {
            _swap(us[i], foboKey, true, -1 ether, 1 ether);
        }
        _swap(alice, foboKey, true, -2 ether, 2 ether); // pays the $FOBO pair's initial buy
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(alice);
        (address kumo,) = factory.launch{value: 2 ether}(
            _signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), (seed % 5) * 10_000_000e18, FOBO_TICK)
        );
        bytes32 s = _salt(alice, "Neko", "NEKO");
        vm.prank(alice);
        FoboToken(fobo).approve(address(factory), type(uint256).max);
        // in band against $FOBO's price after the buys above (tokens per $FOBO + $FOBO per ETH = tokens per ETH)
        int24 nekoTick = (FOBO_TICK - _tick(foboKey)) / 60 * 60;
        vm.prank(alice);
        (address neko,) =
            factory.launch{value: 2 ether}(_signed(alice, "Neko", "NEKO", s, (seed % 3) * 10_000_000e18, nekoTick));
        keys[0] = foboKey;
        keys[1] = hook.keyFor(address(0), kumo);
        keys[2] = hook.keyFor(fobo, neko);
        for (uint256 i; i < 3; i++) {
            (,,,, int24 f,,,,,,,,,,) = hook.pools(keys[i].toId());
            lastF[i] = f;
            if ((seed >> 252) % 2 == 0) {
                spent[i] = _reserve(keys[i]);
                _setReserve(keys[i], 0);
            }
        }
        for (uint256 i; i < 4; i++) {
            _approve(us[i], fobo);
            _approve(us[i], kumo);
            _approve(us[i], neko);
        }
        _check();
        for (uint256 step; step < 40; step++) {
            if (step == 20) {
                (rt, rr) = (new address[](1), new address[](1));
                (rt[0], rr[0]) = (us[2], payees[9]);
                assertEq(revenue.registerBy(rt, rr), 1, "an active, unreferred trader can still be bound");
            }
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 pi = (seed >> 4) % 3;
            PoolKey memory k = keys[pi];
            address u = us[seed % 4];
            uint256 dt = (seed >> 8) % 4 == 0 ? 0 : ((seed >> 12) % 4 == 0 ? (seed >> 16) % 3 hours : (seed >> 16) % 30);
            vm.warp(vm.getBlockTimestamp() + dt);
            if ((seed >> 40) % 2 == 0) vm.roll(vm.getBlockNumber() + 1);
            address tok = Currency.unwrap(k.currency1);
            uint256 bal = FoboToken(tok).balanceOf(u);
            uint256 kind = (seed >> 48) % 7;
            bool isEth = k.currency0.isAddressZero();
            uint256 qbal = isEth ? u.balance : FoboToken(fobo).balanceOf(u);
            if (kind <= 2 || bal == 0) {
                uint256 amt = isEth ? 0.001 ether + (seed >> 56) % 5 ether : 1 + (seed >> 56) % (qbal / 3 + 1);
                if (amt > qbal) continue;
                // buy exact-in, or exact-out for a token amount
                if ((seed >> 100) % 2 == 0 || bal == 0) {
                    _swap(u, k, true, -int256(amt), isEth ? amt : 0);
                } else {
                    uint256 want = 1e18 + (seed >> 120) % 5_000_000e18;
                    try this.swapExt(u, k, true, int256(want), isEth ? 50 ether : 0) {} catch {}
                }
            } else if (kind <= 5) {
                uint256 amt = bal * ((seed >> 64) % 100 + 1) / 100;
                if (amt == 0) continue;
                _swap(u, k, false, -int256(amt), 0);
            } else if (kind == 6) {
                uint256 a = (seed >> 70) % 5;
                if (a == 0) {
                    hook.claimCreator(k, _creatorOf(k));
                } else if (a == 1) {
                    hook.claimTeam(k.currency0);
                } else if (a == 2) {
                    hook.poke(k);
                } else if (a == 3) {
                    address payee = payees[(seed >> 74) % payees.length];
                    revenue.claim(payee, Currency.unwrap(k.currency0), payee);
                } else {
                    _tryBuyback(); // BurnBound when $FOBO was pumped this block
                }
            }
            _check();
            for (uint256 i; i < 3; i++) {
                (,,,, int24 f,,,,,,,,,,) = hook.pools(keys[i].toId());
                lastF[i] = f;
            }
        }
        // everyone exits from the child pools, then $FOBO
        for (uint256 pi = 3; pi > 0; pi--) {
            PoolKey memory k = keys[pi - 1];
            (,,,, int24 tickF,,,,,,,,,,) = hook.pools(k.toId());
            address[] memory all = new address[](5);
            for (uint256 i; i < 4; i++) {
                all[i] = us[i];
            }
            all[4] = alice;
            address tok = Currency.unwrap(k.currency1);
            for (uint256 i; i < 5; i++) {
                uint256 b = FoboToken(tok).balanceOf(all[i]);
                if (b == 0) continue;
                _approve(all[i], tok);
                _swap(all[i], k, false, -int256(b), 0);
            }
            assertLe(_tick(k), tickF + 60, "exit never below the band");
            _check();
        }
        hook.claimCreator(keys[0], _creatorOf(keys[0]));
        hook.claimCreator(keys[1], _creatorOf(keys[1]));
        hook.claimCreator(keys[2], _creatorOf(keys[2]));
        hook.claimTeam(Currency.wrap(address(0)));
        hook.claimTeam(Currency.wrap(fobo));
        for (uint256 i; i < payees.length; i++) {
            revenue.claim(payees[i], address(0), payees[i]);
            revenue.claim(payees[i], fobo, payees[i]);
        }
        assertEq(pm.balanceOf(address(revenue), 0), 0, "FoboRevenue paid out every ETH it was credited");
        assertEq(pm.balanceOf(address(revenue), uint256(uint160(fobo))), 0, "and every $FOBO");
        vm.roll(vm.getBlockNumber() + 1);
        uint256 supply0 = FoboToken(fobo).totalSupply();
        uint256 owed0 = _burnerOwed(Currency.wrap(address(0)));
        if (_tryBuyback()) {
            assertLt(FoboToken(fobo).totalSupply(), supply0, "the buyback burned $FOBO");
            assertEq(_burnerOwed(Currency.wrap(address(0))), owed0 - owed0 / 2, "spent exactly what it was asked to");
        }
        _check();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 nb;
        uint256 nr;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == IFoboHook.BoughtBack.selector) nb++;
            if (logs[i].topics.length > 0 && logs[i].topics[0] == IFoboHook.FloorRaised.selector) nr++;
        }
        emit log_named_uint("buybacks", nb);
        emit log_named_uint("raises", nr);
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "RaiseFailed");
        }
    }

    function swapExt(address who, PoolKey memory key, bool buy, int256 amount, uint256 value) external {
        _swap(who, key, buy, amount, value);
    }
}

contract AuditInvSeeds is AuditInvTest {
    function test_seed1() public {
        testFuzz_accountingAndFloors(1);
    }

    function test_seed2() public {
        testFuzz_accountingAndFloors(12345);
    }

    function test_seed3() public {
        testFuzz_accountingAndFloors(999);
    }

    /// the seeds above empty every dust reserve (bit 252 clear); this one keeps them
    function test_seed4() public {
        testFuzz_accountingAndFloors(1 << 252 | 777);
    }
}

/// A plain 18-decimal ERC-20 quote with a large supply (a stablecoin-like pair at the lowest start tick)
contract BigQuote is ERC20 {
    constructor() ERC20("Quote", "Q") {
        _mint(msg.sender, 1e40);
    }
}

/// Protocol auditor's second fuzz (dust, exact-out, the lowest start tick) and the rebuild's rounding bounds.
contract AuditInvLowStartTest is FoboBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ rebuild rounding
    /// The band and tranche 0 are sized with FloorMath (rounding down); v4 charges getAmount{0,1}Delta rounding up. The
    /// charge never exceeds the amount the liquidity was sized from, so _rebuild's pot / reserve settlement can't
    /// underflow from rounding (and the pot left after the band always covers what _rebuild sweeps).
    function testFuzz_liquidityForQuoteNeverOverdraws(int24 tick, uint256 amount) public pure {
        tick = int24(bound(tick, -887100, 887100));
        tick = tick - (tick % 60);
        amount = bound(amount, 1, 1e30);
        uint160 sA = TickMath.getSqrtPriceAtTick(tick);
        uint160 sB = TickMath.getSqrtPriceAtTick(tick + 60);
        uint128 l = FloorMath.liquidityForQuote(sA, sB, amount);
        if (l == type(uint128).max) return;
        assertLe(SqrtPriceMath.getAmount0Delta(sA, sB, l, true), amount, "band add costs more than it was sized from");
    }

    function testFuzz_liquidityForTokenNeverOverdraws(int24 tick, uint256 amount) public pure {
        tick = int24(bound(tick, -887100, 887100));
        tick = tick - (tick % 60);
        amount = bound(amount, 1, 1e30);
        uint160 sMin = TickMath.getSqrtPriceAtTick(-887220);
        uint160 sB = TickMath.getSqrtPriceAtTick(tick);
        uint128 l = FloorMath.liquidityForToken(sMin, sB, amount);
        if (l == type(uint128).max) return;
        assertLe(SqrtPriceMath.getAmount1Delta(sMin, sB, l, true), amount, "tranche add costs more than it holds");
    }

    // ------------------------------------------------------------------ invariant fuzz: dust, exact-out, low start
    /// Three pools ($FOBO, an ETH pair, an owner-allowed 18-decimal ERC-20 pair at MIN_START_TICK, the tightest
    /// liquidity bound), traded at random with dust (1 wei to 1e6 wei) and large swaps, all four swap kinds (exact-out
    /// sells included), pokes, claims and FoboBurner buybacks, across blocks and the snipe window. After every step the hook's
    /// claims equal its obligations in every currency and no floor drops; at the end every holder exits in one sell each
    /// without reverting and inside the band, and no raise ever failed.
    PoolKey[3] ik;
    int24[3] ilastF;
    address[4] ius;
    address iq;

    function _iobl(PoolKey memory k) internal view returns (uint256) {
        (,,,,,,,, uint128 sp, uint128 rel,,, uint256 pot, uint256 cr,) = hook.pools(k.toId());
        return pot + sp - rel + cr;
    }

    function _ires(PoolKey memory k) internal view returns (uint256 r) {
        (,,,,,,,,,,,,,, r) = hook.pools(k.toId());
    }

    function _icheck() internal {
        Currency eth = Currency.wrap(address(0));
        Currency fb = Currency.wrap(fobo);
        Currency q = Currency.wrap(iq);
        assertEq(
            pm.balanceOf(address(hook), eth.toId()),
            _iobl(ik[0]) + _iobl(ik[1]) + hook.teamOwed(eth),
            "ETH claims == obligations"
        );
        assertEq(pm.balanceOf(address(hook), fb.toId()), _ires(ik[0]) + hook.teamOwed(fb), "FOBO claims");
        assertEq(pm.balanceOf(address(hook), q.toId()), _iobl(ik[2]) + hook.teamOwed(q), "quote claims");
        assertEq(_burnerOwed(fb), 0, "no $FOBO claims in FoboBurner");
        for (uint256 i = 1; i < 3; i++) {
            assertEq(pm.balanceOf(address(hook), ik[i].currency1.toId()), _ires(ik[i]), "token claims == reserve");
        }
        for (uint256 i; i < 3; i++) {
            (,,,, int24 f,,,,,,,,,,) = hook.pools(ik[i].toId());
            assertLe(f, ilastF[i], "floor never drops");
            ilastF[i] = f;
        }
    }

    function swapExt(address who, PoolKey memory key, bool buy, int256 amount, uint256 value) external {
        _swap(who, key, buy, amount, value);
    }

    function _setupInv() internal {
        _launchFobo();
        // an owner-allowed plain 18-decimal ERC-20 quote, its start band at MIN_START_TICK
        iq = address(new BigQuote());
        factory.setQuoteBand(iq, -54780, -54780 + 600);
        factory.setQuoteAllowed(iq, true);
        address alice = _user("alice");
        for (uint256 i; i < 4; i++) {
            ius[i] = _user(string(abi.encodePacked("iu", vm.toString(i))));
            FoboToken(iq).transfer(ius[i], 1e38);
            _approve(ius[i], iq);
        }
        FoboToken(iq).transfer(alice, 1e38);
        vm.prank(alice);
        FoboToken(iq).approve(address(factory), type(uint256).max);
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: 1 ether}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        bytes32 s = _saltAfter(alice, iq, "Low", "LOW");
        vm.prank(alice);
        (address low,) = factory.launch{value: 1 ether}(
            _signedBy(startSignerKey, alice, iq, "Low", "LOW", s, 0, -54780, vm.getBlockTimestamp() + 1 hours)
        );
        ik[0] = foboKey;
        ik[1] = hook.keyFor(address(0), kumo);
        ik[2] = hook.keyFor(iq, low);
        for (uint256 i; i < 3; i++) {
            (,,,, int24 f,,,,,,,,,,) = hook.pools(ik[i].toId());
            ilastF[i] = f;
        }
        for (uint256 i; i < 4; i++) {
            _approve(ius[i], fobo);
            _approve(ius[i], kumo);
            _approve(ius[i], low);
        }
    }

    function testFuzz_dustExactOutLowStart(uint256 seed) public {
        vm.recordLogs();
        _setupInv();
        _icheck();
        for (uint256 step; step < 60; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            PoolKey memory k = ik[(seed >> 4) % 3];
            address u = ius[seed % 4];
            uint256 r = (seed >> 8) % 8;
            vm.warp(vm.getBlockTimestamp() + (r == 0 ? (seed >> 16) % 2 hours : (r < 4 ? (seed >> 16) % 20 : 0)));
            if ((seed >> 40) % 3 != 0) vm.roll(vm.getBlockNumber() + 1);
            address tok = Currency.unwrap(k.currency1);
            bool isEth = k.currency0.isAddressZero();
            uint256 bal = FoboToken(tok).balanceOf(u);
            uint256 qbal = isEth ? u.balance : FoboToken(Currency.unwrap(k.currency0)).balanceOf(u);
            uint256 kind = (seed >> 48) % 9;
            // size class: dust (1..1e6 wei) or real
            bool dust = (seed >> 52) % 3 == 0;
            uint256 sz = dust
                ? 1 + (seed >> 56) % 1e6
                : 1e15 + (seed >> 56) % (isEth ? 5 ether : (k.currency0 == Currency.wrap(iq) ? 2e30 : 50_000e18));
            if (kind <= 1 || bal == 0) {
                if (sz > qbal) continue;
                _swap(u, k, true, -int256(sz), isEth ? sz : 0);
            } else if (kind == 2) {
                uint256 want = dust ? sz : 1e18 + (seed >> 120) % 5_000_000e18;
                try this.swapExt(u, k, true, int256(want), isEth ? 20 ether : 0) {} catch {}
            } else if (kind <= 4) {
                uint256 amt = dust ? (sz < bal ? sz : bal) : bal * ((seed >> 64) % 100 + 1) / 100;
                if (amt == 0) continue;
                _swap(u, k, false, -int256(amt), 0);
            } else if (kind == 5) {
                // exact-out sell: ask for a quote amount (reverts PartialFill if the pool can't release it)
                uint256 out = dust ? sz : sz / 10;
                try this.swapExt(u, k, false, int256(out), 0) {} catch {}
            } else {
                uint256 a = (seed >> 70) % 4;
                if (a == 0) hook.claimCreator(k, _creatorOf(k));
                else if (a == 1) hook.claimTeam(k.currency0);
                else if (a == 2) hook.poke(k);
                else _tryBuyback();
            }
            _icheck();
        }
        for (uint256 pi = 3; pi > 0; pi--) {
            PoolKey memory k = ik[pi - 1];
            (,,,, int24 tickF,,,,,,,,,,) = hook.pools(k.toId());
            address tok = Currency.unwrap(k.currency1);
            for (uint256 i; i < 4; i++) {
                uint256 b = FoboToken(tok).balanceOf(ius[i]);
                if (b == 0) continue;
                _swap(ius[i], k, false, -int256(b), 0);
            }
            assertLe(_tick(k), tickF + 60, "exit never past the band");
            _icheck();
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[3] memory raised;
        uint256 failed;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] == IFoboHook.RaiseFailed.selector) failed++;
            if (logs[i].topics[0] != IFoboHook.FloorRaised.selector) continue;
            for (uint256 j; j < 3; j++) {
                if (logs[i].topics[1] == PoolId.unwrap(ik[j].toId())) raised[j]++;
            }
        }
        emit log_named_uint("raises FOBO", raised[0]);
        emit log_named_uint("raises ETH pair", raised[1]);
        emit log_named_uint("raises low-start pair", raised[2]);
        assertEq(failed, 0, "no raise failed");
    }

    function test_dustExactOutLowStartSeed() public {
        testFuzz_dustExactOutLowStart(42);
    }
}
