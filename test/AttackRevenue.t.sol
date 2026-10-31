// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {FoboHook} from "../src/FoboHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FoboRevenue} from "../src/FoboRevenue.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {IFoboRevenue} from "../src/interfaces/IFoboRevenue.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {RevenueBase} from "./Revenue.t.sol";

/// Attack tests for FoboRevenue (protocol revenue sharing, referrals, registrar) and its hook wiring.
/// Naming: test_FIXED_* was a weakness the first attack pass found (test_BREAK_*), now asserting the fix; test_INFO_*
/// documents an accepted, bounded behaviour; every other test is an attack that failed (it passes when the protocol
/// holds).

/// A partner that, when paid ETH (inside FoboRevenue's PoolManager unlock), tries to claim again (itself and the team)
/// and makes a swap of its own straight on the PoolManager (credited to FoboRevenue in the middle of the claim).
contract ReentrantPartner {
    FoboRevenue immutable revenue;
    IPoolManager immutable pm;
    address immutable team;
    PoolKey key;
    bool armed;
    uint256 public received;
    bool public nestedClaimReverted;
    bool public nestedTeamClaimReverted;
    bool public swapped;

    constructor(FoboRevenue _revenue, IPoolManager _pm, address _team) {
        revenue = _revenue;
        pm = _pm;
        team = _team;
    }

    function arm(PoolKey calldata k) external {
        key = k;
        armed = true;
    }

    receive() external payable {
        received += msg.value;
        if (!armed) return;
        armed = false;
        try revenue.claim(address(this), address(0), address(this)) {}
        catch {
            nestedClaimReverted = true;
        }
        try revenue.claim(team, address(0), team) {}
        catch {
            nestedTeamClaimReverted = true;
        }
        // the PoolManager is unlocked (by FoboRevenue): swap straight on it and settle our own deltas
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        pm.settle{value: uint256(int256(-d.amount0()))}();
        pm.take(key.currency1, address(this), uint256(int256(d.amount1())));
        swapped = true;
    }
}

abstract contract AttackRevenueBase is RevenueBase {
    using PoolIdLibrary for PoolKey;

    /// `t` is bound to `referrer` by the registrar (the site's sign-up: the only way to get a referrer), then gets ETH
    /// and $FOBO
    function _selfRegistered(string memory name, address referrer) internal returns (address t) {
        t = _user(name);
        _setRegistrar(address(this));
        revenue.registerBy(_one(t), _one(referrer));
        _swap(t, foboKey, true, -5 ether, 5 ether);
        _approve(t, fobo);
        _approve(t, kumo);
    }

    function _setRegistrar(address reg) internal {
        revenue.setRegistrar(reg);
    }

    function _hasLog(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) return true;
        }
        return false;
    }

    function _buyCall(PoolKey memory k, int256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                k,
                IPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            )
        );
    }
}

contract AttackRevenueTest is AttackRevenueBase {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        _markets();
    }

    // =====================================================================================================
    // FIXED: self-serve registration let any relayer / bundler / filler farm the referral on other people's volume
    // =====================================================================================================

    /// Was: a bundler (tx.origin of every swap it lands) named a second wallet of its own as its referrer and earned
    /// 0.1% of everyone's bundled volume. Now there is no self-serve register: the only way to a referrer is the site's
    /// sign-up (the registrar). A bundler's EOA that never signed up through a link has none, so bundled swaps pay no
    /// referral to anyone (they go to the team). Residual (INFO): a relayer EOA that does sign up through a link earns
    /// its referrer the referral fee on what it relays; the owner unbinds that relayer (clearReferrers).
    function test_FIXED_bundlerCannotSelfServeAReferrer() public {
        address bundler = _user("bundler");
        (bool ok,) = address(revenue).call(abi.encodeWithSignature("register(address)", makeAddr("bundlerAlt")));
        assertFalse(ok, "no self-serve register");
        address realReferrer = makeAddr("realReferrer");
        address smartWallet = _user("smartWallet");
        _setRegistrar(address(this));
        revenue.registerBy(_one(smartWallet), _one(realReferrer));
        uint256 team0 = revenue.owed(team, ETH);
        for (uint256 i; i < 10; i++) {
            vm.prank(smartWallet, bundler); // msg.sender = the user's wallet, tx.origin = the bundler's EOA
            router.swap{value: 10 ether}(
                kumoKey,
                IPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        assertEq(revenue.referrerOf(bundler), address(0));
        assertEq(_earned(realReferrer, ETH), 0, "tx.origin attribution: bundled swaps pay no referral");
        assertGt(revenue.owed(team, ETH), team0, "they go to the team");
    }

    // =====================================================================================================
    // INFO: a stolen registrar can bind any unreferred wallet (active traders too), and it can be undone
    // =====================================================================================================

    /// With no first-trade lock (the site decides who qualifies), a stolen registrar key can bind ANY wallet with no
    /// referrer to a referrer of the thief's choice, including wallets that have been trading for weeks, and take that
    /// referral share of their protocol fees until the owner reacts. It can't change an existing referral or move money.
    /// Recovery: the owner rotates the registrar (setRegistrar) and clears the bad bindings (clearReferrers; the app
    /// database says which are right), and the new registrar binds the real referrer. What the attacker's referrer
    /// earned before the clear stays its own (nothing credited ever moves).
    function test_INFO_stolenRegistrarBindsAnyUnreferredWalletButIsRecoverable() public {
        address attackerRef = makeAddr("attackerRef");
        address registrarKey = makeAddr("registrarHotKey");
        _setRegistrar(registrarKey);
        address victim = _user("victim");
        address realReferrer = makeAddr("victimRealReferrer");
        _swap(victim, kumoKey, true, -10 ether, 10 ether); // an active, unreferred trader
        assertEq(_earned(attackerRef, ETH), 0);
        vm.prank(registrarKey);
        assertEq(revenue.registerBy(_one(victim), _one(attackerRef)), 1);
        _swap(victim, kumoKey, true, -10 ether, 10 ether);
        uint256 stolen = _earned(attackerRef, ETH);
        assertGt(stolen, 0, "attacker earned until the owner reacted");

        // recovery: rotate, clear, re-bind
        address newKey = makeAddr("newRegistrar");
        revenue.setRegistrar(newKey);
        vm.prank(registrarKey);
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(_one(victim), _one(attackerRef));
        revenue.clearReferrers(_one(victim));
        vm.prank(newKey);
        assertEq(revenue.registerBy(_one(victim), _one(realReferrer)), 1);
        _swap(victim, kumoKey, true, -10 ether, 10 ether);
        assertEq(_earned(attackerRef, ETH), stolen, "the attacker earns nothing more");
        assertGt(_earned(realReferrer, ETH), 0, "the real referrer earns from then on");
    }

    /// The registrar's batch has no per-referrer cap: a stolen key can bind 200 wallets per call to distinct referrers.
    /// Bounded: the owner clears them in batches of the same size (gas of both reported).
    function test_INFO_registrarBatchBindsManyReferrersButClears() public {
        address registrarKey = makeAddr("registrarHotKey");
        _setRegistrar(registrarKey);
        uint256 n = revenue.MAX_REGISTER_BATCH();
        address[] memory ts = new address[](n);
        address[] memory rs = new address[](n);
        for (uint256 i; i < n; i++) {
            ts[i] = address(uint160(0x100000 + i));
            rs[i] = address(uint160(0x900000 + i)); // a distinct referrer per victim
        }
        vm.prank(registrarKey);
        uint256 g = gasleft();
        uint256 set = revenue.registerBy(ts, rs);
        g -= gasleft();
        emit log_named_uint("registerBy gas, full batch, all new", g);
        assertEq(set, n);
        assertLt(g, 10_000_000, "a full batch fits a block");
        g = gasleft();
        revenue.clearReferrers(ts);
        g -= gasleft();
        emit log_named_uint("clearReferrers gas, full batch", g);
        for (uint256 i; i < n; i++) {
            assertEq(revenue.referrerOf(ts[i]), address(0));
        }
    }

    /// Was: a sign-up who traded (or launched) before the launch-day batch was skipped (locked unreferred). Now there
    /// is no lock: the batch binds them anyway, so a late batch (or a referral that qualifies weeks later, once the
    /// wallet connects X) still lands.
    function test_FIXED_tradeBeforeBatchStillBinds() public {
        address early = _user("earlySignup");
        address kol = makeAddr("kol");
        _swap(early, foboKey, true, -1 ether, 1 ether); // trades a block before the batch
        address launcher = _user("earlyLauncher");
        vm.prank(launcher, launcher);
        factory.launch{value: 0.01 ether}(_signedEth(launcher, "Ln", "LN", bytes32(uint256(5)), 0, FOBO_TICK));

        address[] memory ts = new address[](2);
        address[] memory rs = new address[](2);
        (ts[0], rs[0], ts[1], rs[1]) = (early, kol, launcher, kol);
        _setRegistrar(address(this));
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.ReferrerSet(early, kol);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.ReferrerSet(launcher, kol);
        assertEq(revenue.registerBy(ts, rs), 2, "both bound");
        uint256 k0 = _earned(kol, ETH);
        _swap(early, kumoKey, true, -1 ether, 1 ether);
        assertGt(_earned(kol, ETH), k0, "the referrer earns from then on");
    }

    // =====================================================================================================
    // attacks that fail
    // =====================================================================================================

    /// No owner config and no fee size can make credit revert or book more/less than the gross (so the hook's
    /// CreditFailed fallback can't be forced by configuration, and claims == Σ owed per credit).
    function testFuzz_creditNeverRevertsAndAddsUp(
        uint16[3] memory pb,
        uint16 partnerBps,
        uint16 refBps,
        uint128 protocolFee,
        uint128 creatorFee
    ) public {
        FoboRevenue r = new FoboRevenue(pm, address(this), team);
        // setHook only takes a hook built for r: stand the hook's revenue() in for it
        vm.mockCall(address(hook), abi.encodeCall(IFoboHook.revenue, ()), abi.encode(address(r)));
        r.setHook(address(hook));
        vm.clearMockedCalls();
        vm.prank(address(hook));
        pm.setOperator(address(r), true); // as the hook's constructor does for the FoboRevenue it is deployed with
        address[] memory ps = new address[](3);
        uint16[] memory bs = new uint16[](3);
        // any shares adding up to 100% of the partner fee, any fees adding up to at most 100%
        uint256 left = 10_000;
        for (uint256 i; i < 3; i++) {
            ps[i] = address(uint160(0xA000 + i));
            // forge-lint: disable-next-line(unsafe-typecast)
            bs[i] = i == 2 ? uint16(left) : uint16(bound(pb[i], 1, left - (2 - i)));
            left -= bs[i];
        }
        r.setPartners(ps, bs);
        partnerBps = uint16(bound(partnerBps, 0, 10_000));
        refBps = uint16(bound(refBps, 0, 10_000 - partnerBps));
        r.setFeePercent(partnerBps, refBps);
        address ref = makeAddr("ref");
        address t = makeAddr("t");
        r.setRegistrar(address(this));
        r.registerBy(_one(t), _one(ref));
        // the hook's fees come from int128 swap deltas: the PoolManager can't mint or settle more in one go
        protocolFee = uint128(bound(protocolFee, 0, uint128(type(int128).max) / 2));
        creatorFee = uint128(bound(creatorFee, 0, uint128(type(int128).max) / 2));
        uint256 gross = uint256(protocolFee) + creatorFee;
        vm.deal(address(this), address(this).balance + gross);
        uint256 hookClaims = pm.balanceOf(address(hook), 0);
        _fundHook(ETH, gross);
        _creditAsHook(r, ETH, t, protocolFee, creatorFee);
        uint256 owed = r.owed(ref, ETH) + r.owed(team, ETH);
        for (uint256 i; i < 3; i++) {
            owed += r.owed(ps[i], ETH);
        }
        // nobody is paid in the credit: every wei is owed
        assertEq(ref.balance, 0, "nothing sent");
        assertEq(owed, gross, "every wei shared out");
        assertEq(pm.balanceOf(address(r), 0), owed, "claims == sum owed");
        assertEq(pm.balanceOf(address(hook), 0), hookClaims, "exactly the credit's claims taken from the hook");
        assertEq(r.owed(ref, ETH), uint256(protocolFee) * refBps / 10_000, "referrer: the referral fee of the protocol fee");
        uint256 partnerFee = gross * partnerBps / 10_000;
        for (uint256 i; i < 3; i++) {
            assertEq(r.owed(ps[i], ETH), partnerFee * bs[i] / 10_000, "partner: its share of the partner fee");
        }
    }

    /// Silent fallback via gas: in a block whose first swap also runs the floor raise (raise + credit both in the same
    /// beforeSwap), every gas limit either reverts or credits FoboRevenue (the referrer's share owed). A swap never
    /// succeeds with CreditFailed, so a trader or wallet can't divert the referrer's/partners' share to the team by
    /// under-gassing. Sweeps the limit.
    function test_noGasLimitSucceedsWithCreditFailed_raiseSameSwap() public {
        _onePartner(makeAddr("kol"), 2_500);
        address r = makeAddr("referrer");
        address t = _selfRegistered("referredTrader", r);
        // build pot, then move to a new block so the next swap runs a raise first
        _swap(alice, kumoKey, true, -20 ether, 20 ether);
        vm.roll(vm.getBlockNumber() + 1);
        bytes memory call = _buyCall(kumoKey, -1 ether);
        uint256 snap = vm.snapshotState();
        uint256 lo = 100_000;
        uint256 hi = 4_000_000;
        while (hi - lo > 200) {
            uint256 mid = (lo + hi) / 2;
            vm.prank(t, t);
            (bool ok,) = address(router).call{gas: mid, value: 1 ether}(call);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("least gas, raise + credit in one swap", hi);
        uint256 successes;
        for (uint256 g = hi > 60_000 ? hi - 60_000 : 0; g < hi + 400_000; g += 1_500) {
            uint256 r0 = revenue.owed(r, ETH);
            vm.recordLogs();
            vm.prank(t, t);
            (bool ok,) = address(router).call{gas: g, value: 1 ether}(call);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (ok) {
                successes++;
                assertFalse(_hasLog(logs, address(hook), IFoboHook.CreditFailed.selector), "silent CreditFailed");
                assertGt(revenue.owed(r, ETH), r0, "the referrer's share booked");
            }
            vm.revertToState(snap);
        }
        assertGt(successes, 100);
    }

    /// Same sweep for an exact-out buy (credit in afterSwap, raise in beforeSwap) and an exact-in sell (credit in
    /// afterSwap after the swap math).
    function test_noGasLimitSucceedsWithCreditFailed_afterSwapPaths() public {
        address r = makeAddr("referrer");
        address t = _selfRegistered("referredTrader", r);
        _swap(t, kumoKey, true, -5 ether, 5 ether);
        _swap(alice, kumoKey, true, -20 ether, 20 ether);
        vm.roll(vm.getBlockNumber() + 1);
        bytes[2] memory calls = [
            _buyCall(kumoKey, int256(100_000e18)),
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    kumoKey,
                    IPoolManager.SwapParams({
                        zeroForOne: false, amountSpecified: -100_000e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                )
            )
        ];
        for (uint256 c; c < 2; c++) {
            uint256 value = c == 0 ? 1 ether : 0;
            uint256 snap = vm.snapshotState();
            uint256 lo = 100_000;
            uint256 hi = 4_000_000;
            while (hi - lo > 200) {
                uint256 mid = (lo + hi) / 2;
                vm.prank(t, t);
                (bool ok,) = address(router).call{gas: mid, value: value}(calls[c]);
                vm.revertToState(snap);
                if (ok) hi = mid;
                else lo = mid;
            }
            for (uint256 g = hi - 30_000; g < hi + 300_000; g += 3_000) {
                vm.recordLogs();
                vm.prank(t, t);
                (bool ok,) = address(router).call{gas: g, value: value}(calls[c]);
                Vm.Log[] memory logs = vm.getRecordedLogs();
                if (ok) {
                    assertFalse(_hasLog(logs, address(hook), IFoboHook.CreditFailed.selector), "silent CreditFailed");
                }
                vm.revertToState(snap);
            }
        }
    }

    /// A recipient re-entering during its own ETH payout (inside FoboRevenue's unlock): nested claims revert (nested
    /// unlock), a swap made straight on the unlocked PoolManager credits FoboRevenue mid-claim, and afterwards the
    /// recipient was paid exactly once and FoboRevenue's claims still equal everything it owes.
    function test_claimReentrancyCannotDoubleClaimOrDrift() public {
        ReentrantPartner p = new ReentrantPartner(revenue, pm, team);
        vm.deal(address(p), 10 ether);
        _onePartner(address(p), 2_500);
        address r = makeAddr("referrer");
        address t = _selfRegistered("referredTrader", r);
        _swap(t, kumoKey, true, -10 ether, 10 ether);
        uint256 owedP = revenue.owed(address(p), ETH);
        assertGt(owedP, 0);
        p.arm(kumoKey);
        vm.prank(t, t);
        revenue.claim(address(p), ETH, address(p));
        assertFalse(p.nestedClaimReverted(), "own nested claim: balance already zeroed, returns 0");
        assertTrue(p.nestedTeamClaimReverted(), "nested claim of another balance reverts (nested unlock)");
        assertTrue(p.swapped(), "re-entrant swap went through");
        assertEq(p.received(), owedP, "paid exactly once");
        // the re-entrant swap's partner share is booked again for p, the rest for the referrer (t is tx.origin) / team
        uint256 sum = revenue.owed(address(p), ETH) + revenue.owed(team, ETH) + revenue.owed(r, ETH);
        assertEq(_revClaims(ETH), sum, "claims == sum owed after a re-entrant claim");
        revenue.claim(address(p), ETH, address(p));
        revenue.claim(team, ETH, team);
        revenue.claim(r, ETH, r);
        assertEq(_revClaims(ETH), 0);
    }

    /// Wash trading with every rebate an outsider can get: the attacker launches its own pool (creator fee 0.6%),
    /// names its second wallet as referrer before its first credited swap (+0.1%), is the only holder (gets the floor
    /// back through its own tokens), and round-trips 10 x 10 ETH. It ends with less ETH than it started with.
    function test_washTradingWithSelfReferralAndCreatorFeeLoses() public {
        address atk = _user("washer");
        address alt = makeAddr("washerAlt");
        // the best case for the attacker: it signed up through its own second wallet's link
        _setRegistrar(address(this));
        revenue.registerBy(_one(atk), _one(alt));
        uint256 start = atk.balance;
        vm.prank(atk, atk);
        (address w,) =
            factory.launch{value: 0.01 ether}(_signedEth(atk, "Wash", "WASH", bytes32(uint256(42)), 0, FOBO_TICK));
        PoolKey memory wk = hook.keyFor(ETH, w);
        _approve(atk, w);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        for (uint256 i; i < 10; i++) {
            _swap(atk, wk, true, -10 ether, 10 ether);
            vm.roll(vm.getBlockNumber() + 1);
            _swap(atk, wk, false, -int256(FoboToken(w).balanceOf(atk)), 0);
            vm.roll(vm.getBlockNumber() + 1);
        }
        hook.claimCreator(wk, _creatorOf(wk));
        revenue.claim(alt, ETH, alt);
        uint256 end = atk.balance + alt.balance;
        emit log_named_decimal_uint("washer net loss (ETH)", start - end, 18);
        assertLt(end, start, "wash trading is a loss");
        assertGt(start - end, 0.2 ether, "loses at least the team's 0.3% of 100 ETH");
    }

    /// Self-referral and referral loops are bounded: A -> B, B -> A both work, but nobody can be its own referrer and a
    /// referral never changes; a referred trader's swaps never pay its referrer more than the rate of the protocol fee.
    function test_referralLoopsAreBounded() public {
        address a = _user("loopA");
        address b = _user("loopB");
        _setRegistrar(address(this));
        assertEq(revenue.registerBy(_one(a), _one(a)), 0, "no self referral");
        address[] memory ts = new address[](2);
        address[] memory rs = new address[](2);
        (ts[0], rs[0], ts[1], rs[1]) = (a, b, b, a);
        assertEq(revenue.registerBy(ts, rs), 2);
        assertEq(revenue.registerBy(_one(a), _one(makeAddr("other"))), 0, "never changed");
        assertEq(revenue.referrerOf(a), b);
        // 0.1% each of 10 ETH (rounding), owed to the other
        vm.recordLogs();
        _swap(a, kumoKey, true, -10 ether, 10 ether);
        SplitLog memory x = _lastSplit();
        assertEq(x.referrer, b);
        assertApproxEqRel(x.toReferrer, 0.01 ether, 0.001e18);
        vm.recordLogs();
        _swap(b, kumoKey, true, -10 ether, 10 ether);
        x = _lastSplit();
        assertEq(x.referrer, a);
        assertApproxEqRel(x.toReferrer, 0.01 ether, 0.001e18);
        assertEq(revenue.owed(a, ETH) + revenue.owed(b, ETH), 2 * x.toReferrer, "each owed its share, nothing more");
    }

    /// No one but the hook can credit, and nobody can claim someone else's balance to themselves.
    function test_noForgedCreditOrRedirectedClaim() public {
        address atk = makeAddr("atk");
        vm.prank(atk);
        vm.expectRevert(IFoboRevenue.NotHook.selector);
        revenue.credit(ETH, atk, 1 ether, 0);
        vm.prank(atk);
        vm.expectRevert(IFoboRevenue.NotPoolManager.selector);
        revenue.unlockCallback(abi.encode(ETH, atk, 1 ether));
        _swap(_trader("plain"), kumoKey, true, -10 ether, 10 ether);
        uint256 owedTeam = revenue.owed(team, ETH);
        uint256 a0 = atk.balance;
        uint256 t0 = team.balance;
        vm.prank(atk);
        revenue.claim(team, ETH, team);
        assertEq(atk.balance, a0);
        assertEq(team.balance - t0, owedTeam);
    }

    // =====================================================================================================
    // info
    // =====================================================================================================

    /// Second pass (DB as source of truth, no on-chain lock): registerBy's transient duplicate marks are cleared at the
    /// end of each call, so a register -> clearReferrers -> register sequence in one transaction re-binds (the second
    /// call sees no stale Duplicate mark), and a batch that names a trader twice keeps the first referrer only.
    function test_registerByMarksDontLeakAndFirstEntryWins() public {
        address t = makeAddr("markTrader");
        address r1 = makeAddr("markRef1");
        address r2 = makeAddr("markRef2");
        _setRegistrar(address(this));
        address[] memory ts = new address[](2);
        address[] memory rs = new address[](2);
        (ts[0], rs[0], ts[1], rs[1]) = (t, r1, t, r2);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.ReferrerSet(t, r1);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(t, r2, IFoboRevenue.SkipReason.Duplicate);
        assertEq(revenue.registerBy(ts, rs), 1);
        assertEq(revenue.referrerOf(t), r1, "first entry wins");
        // same transaction (a forge test is one): clear, then register again
        revenue.clearReferrers(_one(t));
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.ReferrerSet(t, r2);
        assertEq(revenue.registerBy(_one(t), _one(r2)), 1, "no stale transient mark");
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(t, r1, IFoboRevenue.SkipReason.AlreadyReferred);
        assertEq(revenue.registerBy(_one(t), _one(r1)), 0);
    }

    /// Nobody but the registrar binds; a disabled registrar (0) can't be impersonated by address(0); batches are bounded.
    function test_registerByGatesAndBounds() public {
        address atk = makeAddr("atkRegistrar");
        vm.prank(atk);
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(_one(atk), _one(makeAddr("atkRef")));
        revenue.setRegistrar(address(0));
        vm.prank(address(0));
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(_one(atk), _one(makeAddr("atkRef")));
        _setRegistrar(address(this));
        vm.expectRevert(IFoboRevenue.LengthMismatch.selector);
        revenue.registerBy(_one(atk), new address[](0));
        uint256 n = revenue.MAX_REGISTER_BATCH() + 1;
        vm.expectRevert(IFoboRevenue.BatchTooLarge.selector);
        revenue.registerBy(new address[](n), new address[](n));
        vm.expectRevert(IFoboRevenue.BatchTooLarge.selector);
        revenue.clearReferrers(new address[](n));
        vm.prank(atk);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.clearReferrers(_one(atk));
    }

    /// INFO: clearReferrers only resets the chain; a registrar that sends the binding again re-binds it. The site no
    /// longer does for a revoked referral (the web app's referral tests "FIXED: a revoked referral stays
    /// cleared": referrals:clear marks it cleared_at, which the sender and referrals:register skip), and its sender never
    /// re-sends one it already registered. For a farm, rotating the registrar (setRegistrar) is what stops the re-sends.
    function test_INFO_clearedTraderIsReboundByTheNextRegistrarSend() public {
        address farmRef = makeAddr("farmRef");
        address sybil = _user("farmSybil");
        _setRegistrar(address(this));
        assertEq(revenue.registerBy(_one(sybil), _one(farmRef)), 1);
        revenue.clearReferrers(_one(sybil));
        assertEq(revenue.referrerOf(sybil), address(0));
        // the site's registrar re-sends what its database calls cleared
        assertEq(revenue.registerBy(_one(sybil), _one(farmRef)), 1, "re-bound");
        uint256 f0 = _earned(farmRef, ETH);
        _swap(sybil, kumoKey, true, -10 ether, 10 ether);
        assertGt(_earned(farmRef, ETH), f0, "the re-bound referrer earns again");
        // the lever: a new registrar (the old key can't re-send), then clear again
        revenue.setRegistrar(makeAddr("newRegistrar"));
        revenue.clearReferrers(_one(sybil));
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(_one(sybil), _one(farmRef));
        f0 = _earned(farmRef, ETH);
        _swap(sybil, kumoKey, true, -10 ether, 10 ether);
        assertEq(_earned(farmRef, ETH), f0, "rotated and cleared: it earns nothing more");
    }

    /// Was (INFO): registerBy accepted address(0) as a trader (harmless: tx.origin is never 0). Now it is skipped like a
    /// bad referrer, with a RegisterSkipped(BadReferrer).
    function test_FIXED_registerBySkipsAZeroTrader() public {
        _setRegistrar(address(this));
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(address(0), makeAddr("zeroRef"), IFoboRevenue.SkipReason.BadReferrer);
        assertEq(revenue.registerBy(_one(address(0)), _one(makeAddr("zeroRef"))), 0);
        assertEq(revenue.referrerOf(address(0)), address(0));
    }

    /// Was: FoboRevenue.Claimed shared IFoboHook.Claimed's topic0. Now it's RevenueClaimed.
    function test_FIXED_revenueClaimedTopicIsDistinct() public pure {
        assertTrue(IFoboRevenue.RevenueClaimed.selector != IFoboHook.Claimed.selector);
    }

    /// Was: the owner could name FoboRevenue itself as a partner or the team (its ETH share could never be claimed).
    /// Now setPartners, setTeam and setRegistrar refuse it, and setPartners also refuses the hook and the PoolManager.
    /// (Any other unclaimable address stays an owner-trust matter.)
    function test_FIXED_revenueItselfCantBePartnerOrTeam() public {
        vm.expectRevert(IFoboRevenue.SelfAddress.selector);
        _setSolePartner(address(revenue));
        vm.expectRevert(IFoboRevenue.BadPartner.selector);
        _setSolePartner(address(hook));
        vm.expectRevert(IFoboRevenue.BadPartner.selector);
        _setSolePartner(address(pm));
        vm.expectRevert(IFoboRevenue.SelfAddress.selector);
        revenue.setTeam(address(revenue));
        vm.expectRevert(IFoboRevenue.SelfAddress.selector);
        revenue.setRegistrar(address(revenue));
    }

    // =====================================================================================================
    // third pass (final design): owner powers, claims that can't be paid, and what a referrer can't do
    // =====================================================================================================

    /// INFO (documented owner power; was BREAK: the docs said the Owner Safe "can't touch ... anyone's referrer"):
    /// setRegistrar(itself) + clearReferrers + registerBy moves any referred trader to a referrer of its choice in one
    /// Safe batch, and setFeePercent can raise the referral fee (for every referrer) up to 100% of the protocol fee. Nothing already credited moves, but every
    /// future referral share of that trader goes to the owner's pick. docs/DEPLOYMENT.md §0 and README §5.1 / §8 now
    /// list it as an owner power (the Owner Safe's signers are trusted with who earns on whom).
    function test_INFO_ownerCanMoveAnyReferral() public {
        address realRef = makeAddr("honestReferrer");
        address victim = _referred("ownerVictim", realRef);
        uint256 h0 = _earned(realRef, ETH);
        _swap(victim, kumoKey, true, -10 ether, 10 ether);
        uint256 honest = _earned(realRef, ETH);
        uint256 perSwap = honest - h0; // the honest referrer's share of one 10 ETH swap
        assertGt(perSwap, 0);

        address pick = makeAddr("ownersPick");
        // one Owner Safe batch: become registrar, clear, re-bind, double the referral fee
        revenue.setRegistrar(address(this));
        revenue.clearReferrers(_one(victim));
        assertEq(revenue.registerBy(_one(victim), _one(pick)), 1);
        revenue.setFeePercent(0, 5_000);
        _swap(victim, kumoKey, true, -10 ether, 10 ether);
        assertEq(revenue.referrerOf(victim), pick, "the owner moved an existing referral");
        assertEq(_earned(realRef, ETH), honest, "the honest referrer earns nothing more");
        assertApproxEqRel(_earned(pick, ETH), perSwap * 2, 0.01e18, "the pick earns 2x the honest share");
    }

    /// Failed attack: a partner (or referrer) that can't receive ETH only blocks its own claim; swaps keep crediting
    /// and everyone else claims normally.
    function test_unpayableRecipientOnlyBlocksItself() public {
        address sink = address(new EthRejector());
        _onePartner(sink, 2_500);
        address t = _referred("rejectTrader", sink); // the same contract as a referrer too
        _swap(t, kumoKey, true, -10 ether, 10 ether);
        uint256 owedSink = revenue.owed(sink, ETH);
        assertGt(owedSink, 0);
        vm.expectRevert();
        revenue.claim(sink, ETH, sink);
        assertEq(revenue.owed(sink, ETH), owedSink, "still owed, nothing lost");
        uint256 t0 = team.balance;
        uint256 owedTeam = revenue.owed(team, ETH);
        revenue.claim(team, ETH, team);
        assertEq(team.balance - t0, owedTeam, "the team claims normally");
        _swap(t, kumoKey, true, -10 ether, 10 ether);
        assertGt(revenue.owed(sink, ETH), owedSink, "swaps keep crediting it");
        assertEq(_revClaims(ETH), revenue.owed(sink, ETH) + revenue.owed(team, ETH), "claims == sum owed");
    }

    /// Failed attack: the registrar can't overwrite a referral, even by naming the trader twice or in a later batch,
    /// and an entry for a trader with itself as referrer is skipped (fuzzed over batch layouts).
    function testFuzz_registerByNeverOverwrites(address t, address r1, address r2) public {
        vm.assume(t != address(0) && r1 != address(0) && r2 != address(0) && r1 != t && r2 != t && r1 != r2);
        // referrers that could never claim are skipped by design (BadReferrer): this checks the overwrite rule only
        vm.assume(_canRefer(r1) && _canRefer(r2));
        _setRegistrar(address(this));
        address[] memory ts = new address[](3);
        address[] memory rs = new address[](3);
        (ts[0], rs[0], ts[1], rs[1], ts[2], rs[2]) = (t, r1, t, t, t, r2);
        assertEq(revenue.registerBy(ts, rs), 1);
        assertEq(revenue.referrerOf(t), r1);
        assertEq(revenue.registerBy(_one(t), _one(r2)), 0);
        assertEq(revenue.referrerOf(t), r1);
    }

    /// A referrer registerBy accepts: not FoboRevenue, the hook or the PoolManager (none of them could ever claim).
    function _canRefer(address r) internal view returns (bool) {
        return r != address(revenue) && r != address(hook) && r != address(pm);
    }
}

/// Rejects every ETH transfer (a partner or referrer that cannot be paid).
contract EthRejector {
    receive() external payable {
        revert("no eth");
    }
}
