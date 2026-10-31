// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FoboHook} from "../src/FoboHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FoboRevenue} from "../src/FoboRevenue.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {IFoboRevenue} from "../src/interfaces/IFoboRevenue.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {Tax} from "../src/libraries/Tax.sol";
import {FoboBase, RevertingReceiver} from "./Fobo.t.sol";

/// What every FoboRevenue test needs: $FOBO, an ETH pair (KUMO) and a $FOBO pair (NEKO), all past their snipe windows,
/// traders with ETH and $FOBO, and helpers to sign referrals and read balances.
abstract contract RevenueBase is FoboBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    address constant ETH = address(0);
    address alice;
    address kumo;
    address neko;
    PoolKey kumoKey;
    PoolKey nekoKey;

    function _markets() internal {
        _launchFobo();
        alice = _user("alice");
        // inside $FOBO's snipe window: its 40% share, the creator fee, is credited (no protocol fee)
        _swap(alice, foboKey, true, -1 ether, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(alice, foboKey, true, -50 ether, 50 ether);
        vm.prank(alice);
        (kumo,) = factory.launch{value: 1 ether}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        vm.prank(alice);
        FoboToken(fobo).approve(address(factory), type(uint256).max);
        bytes32 s = _salt(alice, "Neko", "NEKO");
        vm.prank(alice);
        (neko,) = factory.launch{value: 1 ether}(_signed(alice, "Neko", "NEKO", s, 0, 0));
        kumoKey = hook.keyFor(ETH, kumo);
        nekoKey = hook.keyFor(fobo, neko);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61); // past both snipe windows
    }

    /// A trader with ETH and $FOBO, approved for every token
    function _trader(string memory name) internal returns (address t) {
        t = _user(name);
        _swap(t, foboKey, true, -5 ether, 5 ether);
        _approve(t, fobo);
        if (kumo != address(0)) _approve(t, kumo);
        if (neko != address(0)) _approve(t, neko);
    }

    /// The site's registrar (FoboRevenue.registerBy), set by the owner
    function _registrar() internal returns (address reg) {
        reg = makeAddr("registrar");
        if (revenue.registrar() != reg) revenue.setRegistrar(reg);
    }

    function _bind(address t, address r) internal returns (uint256 set) {
        address[] memory ts = new address[](1);
        address[] memory rs = new address[](1);
        (ts[0], rs[0]) = (t, r);
        vm.prank(_registrar());
        set = revenue.registerBy(ts, rs);
    }

    /// A fresh trader `name`, bound to `referrer` by the registrar before its first trade, with ETH and $FOBO
    function _referred(string memory name, address referrer) internal returns (address t) {
        t = makeAddr(name);
        assertEq(_bind(t, referrer), 1);
        vm.deal(t, 1_000_000 ether);
        _swap(t, foboKey, true, -5 ether, 5 ether);
        _approve(t, fobo);
        if (kumo != address(0)) _approve(t, kumo);
        if (neko != address(0)) _approve(t, neko);
    }

    /// One partner taking the whole partner fee, `fee` bps of the gross (setPartners replaces the whole list, then
    /// setFeePercent sets the fee; the referral fee stays)
    function _onePartner(address a, uint16 fee) internal {
        address[] memory r = new address[](1);
        uint16[] memory b = new uint16[](1);
        (r[0], b[0]) = (a, 10_000);
        revenue.setPartners(r, b);
        revenue.setFeePercent(fee, revenue.referralBps());
    }

    /// setPartners with `a` as the only partner (100% of the partner fee), the fee untouched: for checking what
    /// setPartners refuses (vm.expectRevert covers one call)
    function _setSolePartner(address a) internal {
        address[] memory r = new address[](1);
        uint16[] memory b = new uint16[](1);
        (r[0], b[0]) = (a, 10_000);
        revenue.setPartners(r, b);
    }

    /// Two partners sharing a partner fee of `fee` bps of the gross, `s1` / `s2` of it (adding up to 10_000)
    function _twoPartners(address a1, uint16 s1, address a2, uint16 s2, uint16 fee) internal {
        address[] memory r = new address[](2);
        uint16[] memory b = new uint16[](2);
        (r[0], b[0], r[1], b[1]) = (a1, s1, a2, s2);
        revenue.setPartners(r, b);
        revenue.setFeePercent(fee, revenue.referralBps());
    }

    /// No partners: the partner fee to 0 first, then the empty list (the order setPartners requires)
    function _noPartners() internal {
        revenue.setFeePercent(0, revenue.referralBps());
        revenue.setPartners(new address[](0), new uint16[](0));
    }

    function _revClaims(address currency) internal view returns (uint256) {
        return pm.balanceOf(address(revenue), Currency.wrap(currency).toId());
    }

    /// What `who` has earned in `currency`: what it is owed plus what it holds (a claim moves it from one to the other;
    /// nobody is paid in a swap)
    function _earned(address who, address currency) internal view returns (uint256) {
        return revenue.owed(who, currency) + (currency == ETH ? who.balance : FoboToken(currency).balanceOf(who));
    }

    uint8 constant CB_FUND_HOOK = 1;
    uint8 constant CB_CREDIT = 2;

    /// Gives the hook `amount` of `currency` claims, paid for by this contract (ETH, or a token it holds), as swaps do
    function _fundHook(address currency, uint256 amount) internal {
        pm.unlock(abi.encode(CB_FUND_HOOK, abi.encode(currency, amount)));
    }

    /// Calls FoboRevenue.credit as the hook does: from the hook, inside a PoolManager unlock (as in a swap), with the
    /// hook holding the claims (_fundHook first). Returns the gas the credit used.
    function _creditAsHook(address currency, address trader, uint256 protocolFee, uint256 creatorFee)
        internal
        returns (uint256)
    {
        return _creditAsHook(revenue, currency, trader, protocolFee, creatorFee);
    }

    /// The same for another FoboRevenue `rev` (its hook must be the hook, and the hook must have made it its operator)
    function _creditAsHook(FoboRevenue rev, address currency, address trader, uint256 protocolFee, uint256 creatorFee)
        internal
        returns (uint256)
    {
        bytes memory args = abi.encode(rev, currency, trader, protocolFee, creatorFee);
        return abi.decode(pm.unlock(abi.encode(CB_CREDIT, args)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only the PoolManager");
        (uint8 action, bytes memory args) = abi.decode(data, (uint8, bytes));
        if (action == CB_FUND_HOOK) {
            (address currency, uint256 amount) = abi.decode(args, (address, uint256));
            pm.mint(address(hook), Currency.wrap(currency).toId(), amount);
            if (currency == ETH) {
                pm.settle{value: amount}();
            } else {
                pm.sync(Currency.wrap(currency));
                FoboToken(currency).transfer(address(pm), amount);
                pm.settle();
            }
            return "";
        }
        (FoboRevenue rev, address c, address trader, uint256 protocolFee, uint256 creatorFee) =
            abi.decode(args, (FoboRevenue, address, address, uint256, uint256));
        vm.prank(address(hook));
        uint256 g = gasleft();
        rev.credit(c, trader, protocolFee, creatorFee);
        g -= gasleft();
        return abi.encode(g);
    }

    struct SplitLog {
        // the hook's TaxPaid
        uint256 taxToCreator;
        uint256 taxToTeam;
        // FoboRevenue's Split
        uint256 protocolFee;
        uint256 creatorFee;
        uint256 toReferrer;
        uint256 toPartners;
        uint256 toTeam;
        address referrer;
    }

    /// The last swap's TaxPaid and Split (recorded logs)
    function _lastSplit() internal returns (SplitLog memory x) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter == address(hook) && l.topics[0] == IFoboHook.TaxPaid.selector) {
                (,,, x.taxToCreator, x.taxToTeam,) =
                    abi.decode(l.data, (bool, uint256, uint256, uint256, uint256, uint256));
            }
            if (l.emitter == address(revenue) && l.topics[0] == IFoboRevenue.Split.selector) {
                (x.protocolFee, x.creatorFee, x.toReferrer, x.toPartners, x.toTeam) =
                    abi.decode(l.data, (uint256, uint256, uint256, uint256, uint256));
                x.referrer = address(uint160(uint256(l.topics[3])));
                seen = true;
            }
        }
        require(seen, "no Split");
    }
}

contract RevenueConfigTest is RevenueBase {
    function test_defaults() public {
        assertEq(revenue.owner(), address(this));
        assertEq(revenue.team(), team);
        assertEq(revenue.hook(), address(hook));
        assertEq(address(hook.revenue()), address(revenue));
        assertEq(revenue.referralBps(), 2_500, "25% referral fee by default");
        assertEq(revenue.partnerBps(), 0, "no partner fee by default");
        assertEq(revenue.partnerCount(), 0);
        assertEq(revenue.MAX_PARTNERS(), 5);
    }

    /// The constructor logs the defaults, so an indexer starting at the deploy has both fees from the first block
    function test_constructorLogsTheDefaults() public {
        vm.expectEmit();
        emit IFoboRevenue.FeePercentSet(0, 2_500);
        new FoboRevenue(pm, address(this), team);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new FoboRevenue(pm, address(0), team);
        vm.expectRevert(IFoboRevenue.ZeroAddress.selector);
        new FoboRevenue(pm, address(this), address(0));
    }

    function test_ownerOnly() public {
        address rando = makeAddr("rando");
        vm.startPrank(rando);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.setPartners(new address[](0), new uint16[](0));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.setFeePercent(0, 100);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.setTeam(rando);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.setHook(rando);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.transferOwnership(rando);
        vm.expectRevert(IFoboRevenue.NotHook.selector);
        revenue.credit(ETH, rando, 1, 0);
        vm.stopPrank();
    }

    /// setHook: once, never zero, and only a hook built for this FoboRevenue (its revenue() is this contract): a hook
    /// deployed with another one could never be replaced.
    function test_hookIsSetOnce() public {
        vm.expectRevert(IFoboRevenue.HookAlreadySet.selector);
        revenue.setHook(makeAddr("other"));
        FoboRevenue fresh = new FoboRevenue(pm, address(this), team);
        vm.expectRevert(IFoboRevenue.ZeroAddress.selector);
        fresh.setHook(address(0));
        vm.expectRevert(IFoboRevenue.BadHook.selector);
        fresh.setHook(address(hook)); // hook.revenue() is the suite's FoboRevenue
        vm.expectRevert();
        fresh.setHook(makeAddr("eoa")); // no revenue() to read
        assertEq(fresh.hook(), address(0), "still unset");
    }

    function test_twoStepOwnership() public {
        address safe = makeAddr("ownerSafe");
        vm.expectEmit(address(revenue));
        emit Ownable2Step.OwnershipTransferStarted(address(this), safe);
        revenue.transferOwnership(safe);
        assertEq(revenue.owner(), address(this), "still the owner until accepted");
        assertEq(revenue.pendingOwner(), safe);
        vm.prank(makeAddr("rando"));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.acceptOwnership();
        vm.prank(safe);
        revenue.acceptOwnership();
        assertEq(revenue.owner(), safe);
        assertEq(revenue.pendingOwner(), address(0));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.setFeePercent(0, 1);
        vm.prank(safe);
        revenue.setFeePercent(0, 1);
        assertEq(revenue.referralBps(), 1);
    }

    function test_setTeam() public {
        vm.expectRevert(IFoboRevenue.ZeroAddress.selector);
        revenue.setTeam(address(0));
        address t2 = makeAddr("team2");
        revenue.setTeam(t2);
        assertEq(revenue.team(), t2);
    }

    function _list(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _bps(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory r) {
        r = new uint16[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function test_setPartnersReplacesTheWholeList() public {
        address p1 = makeAddr("p1");
        address p2 = makeAddr("p2");
        address p3 = makeAddr("p3");
        address p4 = makeAddr("p4");
        address[] memory r = _list(p1, p2, p3);
        uint16[] memory b = _bps(5_000, 3_000, 2_000); // 100% of the partner fee
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.PartnersSet(r, b);
        revenue.setPartners(r, b);
        assertEq(revenue.partnerCount(), 3);
        (address[] memory ra, uint16[] memory ba) = revenue.partners();
        assertEq(ra.length, 3);
        assertEq(ra[0], p1);
        assertEq(ba[1], 3_000);
        assertEq(ra[2], p3);
        // a shorter list replaces it (even with a partner fee on): nothing of the old one survives
        revenue.setFeePercent(3_000, 2_500);
        _onePartner(p4, 3_000);
        (ra, ba) = revenue.partners();
        assertEq(ra.length, 1);
        assertEq(ra[0], p4);
        assertEq(ba[0], 10_000);
        assertEq(revenue.partnerCount(), 1);
        // empty: no partners (the partner fee to 0 first)
        _noPartners();
        (ra,) = revenue.partners();
        assertEq(ra.length, 0);
        assertEq(revenue.partnerCount(), 0);
        assertEq(revenue.partnerBps(), 0);
        assertEq(revenue.referralBps(), 2_500, "the referral fee stays");
    }

    function test_setPartnersRules() public {
        address p1 = makeAddr("p1");
        address p2 = makeAddr("p2");
        address p3 = makeAddr("p3");
        _onePartner(p1, 2_500);
        vm.expectRevert(IFoboRevenue.LengthMismatch.selector);
        revenue.setPartners(_list(p1, p2, p3), new uint16[](2));
        // MAX_PARTNERS (5) is fine, one more isn't
        address[] memory six = new address[](6);
        uint16[] memory sixBps = new uint16[](6);
        for (uint256 i; i < 6; i++) {
            (six[i], sixBps[i]) = (makeAddr(string(abi.encodePacked("many", vm.toString(i)))), 2_000);
        }
        sixBps[5] = 0;
        address[] memory five = new address[](5);
        uint16[] memory fiveBps = new uint16[](5);
        for (uint256 i; i < 5; i++) {
            (five[i], fiveBps[i]) = (six[i], sixBps[i]);
        }
        revenue.setPartners(five, fiveBps);
        assertEq(revenue.partnerCount(), 5);
        (sixBps[4], sixBps[5]) = (1_000, 1_000);
        vm.expectRevert(IFoboRevenue.TooManyPartners.selector);
        revenue.setPartners(six, sixBps);
        _onePartner(p1, 2_500);
        vm.expectRevert(IFoboRevenue.ZeroAddress.selector);
        revenue.setPartners(_list(p1, address(0), p3), _bps(5_000, 2_500, 2_500));
        vm.expectRevert(IFoboRevenue.ZeroShare.selector);
        revenue.setPartners(_list(p1, p2, p3), _bps(5_000, 0, 5_000));
        vm.expectRevert(IFoboRevenue.DuplicatePartner.selector);
        revenue.setPartners(_list(p1, p2, p1), _bps(5_000, 2_500, 2_500));
        vm.expectRevert(IFoboRevenue.SelfAddress.selector);
        revenue.setPartners(_list(p1, address(revenue), p3), _bps(5_000, 2_500, 2_500));
        vm.expectRevert(IFoboRevenue.BadPartner.selector);
        revenue.setPartners(_list(p1, address(hook), p3), _bps(5_000, 2_500, 2_500));
        vm.expectRevert(IFoboRevenue.BadPartner.selector);
        revenue.setPartners(_list(p1, address(pm), p3), _bps(5_000, 2_500, 2_500));
        // the shares are of the partner fee: exactly 100%, never less or more
        vm.expectRevert(IFoboRevenue.BadShareTotal.selector);
        revenue.setPartners(_list(p1, p2, p3), _bps(5_000, 2_500, 2_499));
        vm.expectRevert(IFoboRevenue.BadShareTotal.selector);
        revenue.setPartners(_list(p1, p2, p3), _bps(5_000, 2_500, 2_501));
        // emptying it while the partner fee is on: the fee would have no one to go to
        vm.expectRevert(IFoboRevenue.PartnerFeeActive.selector);
        revenue.setPartners(new address[](0), new uint16[](0));
        // a failed call leaves the list as it was
        (address[] memory ra, uint16[] memory ba) = revenue.partners();
        assertEq(ra.length, 1);
        assertEq(ra[0], p1);
        assertEq(ba[0], 10_000);
    }

    function test_setFeePercentRules() public {
        // a partner fee needs partners
        vm.expectRevert(IFoboRevenue.NoPartners.selector);
        revenue.setFeePercent(1, 2_500);
        // without partners the referral fee can be anything up to 100%
        revenue.setFeePercent(0, 10_000);
        assertEq(revenue.referralBps(), 10_000);
        revenue.setFeePercent(0, 0);
        assertEq(revenue.referralBps(), 0);
        _onePartner(makeAddr("p1"), 2_500);
        // together at most 100%
        vm.expectRevert(IFoboRevenue.FeeTooHigh.selector);
        revenue.setFeePercent(7_501, 2_500);
        vm.expectRevert(IFoboRevenue.FeeTooHigh.selector);
        revenue.setFeePercent(type(uint16).max, type(uint16).max);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.FeePercentSet(7_500, 2_500);
        revenue.setFeePercent(7_500, 2_500);
        assertEq(revenue.partnerBps(), 7_500);
        assertEq(revenue.referralBps(), 2_500);
        revenue.setFeePercent(10_000, 0); // everything to the partners is allowed
        assertEq(revenue.partnerBps(), 10_000);
    }

    function _pair(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    /// The registrar (the site's sign-up) is the only way to get a referrer: there is no self-serve register
    function test_noSelfServeRegister() public {
        (bool ok,) = address(revenue).call(abi.encodeWithSignature("register(address)", makeAddr("referrer")));
        assertFalse(ok, "register(address) doesn't exist");
        (ok,) = address(revenue)
            .call(
                abi.encodeWithSignature(
                    "registerFor(address,address,uint256,bytes)", makeAddr("t"), makeAddr("r"), 0, ""
                )
            );
        assertFalse(ok, "registerFor(...) doesn't exist");
    }

    function test_selfAddressRejected() public {
        vm.expectRevert(IFoboRevenue.SelfAddress.selector);
        revenue.setTeam(address(revenue));
        vm.expectRevert(IFoboRevenue.SelfAddress.selector);
        _setSolePartner(address(revenue));
        vm.expectRevert(IFoboRevenue.SelfAddress.selector);
        revenue.setRegistrar(address(revenue));
    }

    function test_registrarOnly() public {
        address[] memory ts = _pair(makeAddr("t1"), makeAddr("t2"));
        address[] memory rs = _pair(makeAddr("r"), makeAddr("r"));
        // none set: nobody may call it, not even address(0)'s owner
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(ts, rs);
        vm.prank(address(0));
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(ts, rs);
        vm.prank(makeAddr("rando"));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.setRegistrar(makeAddr("rando"));
        address reg = _registrar();
        vm.prank(makeAddr("rando"));
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(ts, rs);
        vm.prank(reg);
        assertEq(revenue.registerBy(ts, rs), 2);
        assertEq(revenue.referrerOf(ts[1]), rs[1]);
    }

    function test_registrarRotationAndDisable() public {
        address reg = _registrar();
        address reg2 = makeAddr("registrar2");
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegistrarSet(reg2);
        revenue.setRegistrar(reg2);
        address[] memory ts = _pair(makeAddr("t1"), makeAddr("t2"));
        address[] memory rs = _pair(makeAddr("r"), makeAddr("r"));
        vm.prank(reg);
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(ts, rs);
        revenue.setRegistrar(address(0));
        vm.prank(reg2);
        vm.expectRevert(IFoboRevenue.NotRegistrar.selector);
        revenue.registerBy(ts, rs);
    }

    function test_registerBySkipsWhatCantBeSet() public {
        _markets();
        address r = makeAddr("referrer");
        address done = makeAddr("alreadyReferred");
        _bind(done, makeAddr("first"));
        address traded = _trader("unreferredTrader");
        address[] memory ts = new address[](10);
        address[] memory rs = new address[](10);
        (ts[0], rs[0]) = (makeAddr("ok"), r);
        (ts[1], rs[1]) = (makeAddr("zero"), address(0));
        (ts[2], rs[2]) = (r, r); // self
        (ts[3], rs[3]) = (done, r); // already has one: never changed
        (ts[4], rs[4]) = (makeAddr("ok"), makeAddr("other")); // a duplicate later in the batch: the first wins
        (ts[5], rs[5]) = (traded, r); // traded without a referrer: still bindable
        (ts[6], rs[6]) = (address(0), r); // no trader
        // referrers that could never claim: their share would be booked and stuck forever (FoboRevenue has no
        // receive(), the hook and the PoolManager never claim)
        (ts[7], rs[7]) = (makeAddr("t7"), address(revenue));
        (ts[8], rs[8]) = (makeAddr("t8"), address(hook));
        (ts[9], rs[9]) = (makeAddr("t9"), address(pm));
        address reg = _registrar();
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.ReferrerSet(ts[0], r);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(ts[1], address(0), IFoboRevenue.SkipReason.BadReferrer);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(r, r, IFoboRevenue.SkipReason.BadReferrer);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(done, r, IFoboRevenue.SkipReason.AlreadyReferred);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(ts[4], rs[4], IFoboRevenue.SkipReason.Duplicate);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.ReferrerSet(traded, r);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RegisterSkipped(address(0), r, IFoboRevenue.SkipReason.BadReferrer);
        for (uint256 i = 7; i < 10; i++) {
            vm.expectEmit(address(revenue));
            emit IFoboRevenue.RegisterSkipped(ts[i], rs[i], IFoboRevenue.SkipReason.BadReferrer);
        }
        vm.prank(reg);
        assertEq(revenue.registerBy(ts, rs), 2);
        assertEq(revenue.referrerOf(ts[0]), r);
        assertEq(revenue.referrerOf(ts[1]), address(0));
        assertEq(revenue.referrerOf(r), address(0));
        assertEq(revenue.referrerOf(done), makeAddr("first"));
        assertEq(revenue.referrerOf(traded), r);
        assertEq(revenue.referrerOf(address(0)), address(0));
        for (uint256 i = 7; i < 10; i++) {
            assertEq(revenue.referrerOf(ts[i]), address(0), "an unclaimable referrer is never bound");
        }
    }

    /// The recovery from a compromised registrar: rotate it, then the owner clears the bindings it made, and the new
    /// registrar binds the right referrer
    function test_clearReferrers() public {
        _markets();
        address bad = makeAddr("attackerRef");
        address good = makeAddr("realReferrer");
        address victim = makeAddr("victim");
        address trader = _trader("activeTrader");
        _bind(victim, bad);
        _bind(trader, bad);
        address[] memory two = _pair(victim, trader);
        vm.prank(makeAddr("rando"));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        revenue.clearReferrers(two);
        uint256 tooMany = revenue.MAX_REGISTER_BATCH() + 1;
        vm.expectRevert(IFoboRevenue.BatchTooLarge.selector);
        revenue.clearReferrers(new address[](tooMany));
        revenue.setRegistrar(makeAddr("newRegistrar"));
        // a trader with no referrer is skipped: ReferrerCleared only for the two that had one
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (victim, makeAddr("neverReferred"), trader);
        vm.recordLogs();
        revenue.clearReferrers(three);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "one ReferrerCleared per trader that had a referrer");
        assertEq(logs[0].topics[0], IFoboRevenue.ReferrerCleared.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(victim))));
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(trader))));
        assertEq(revenue.referrerOf(victim), address(0));
        assertEq(revenue.referrerOf(trader), address(0));
        vm.prank(makeAddr("newRegistrar"));
        assertEq(revenue.registerBy(two, _pair(good, good)), 2);
        assertEq(revenue.referrerOf(victim), good);
        assertEq(revenue.referrerOf(trader), good);
    }

    function test_registerByBounds() public {
        address reg = _registrar();
        vm.prank(reg);
        vm.expectRevert(IFoboRevenue.LengthMismatch.selector);
        revenue.registerBy(new address[](2), new address[](1));
        uint256 max = revenue.MAX_REGISTER_BATCH();
        vm.prank(reg);
        vm.expectRevert(IFoboRevenue.BatchTooLarge.selector);
        revenue.registerBy(new address[](max + 1), new address[](max + 1));
        address[] memory ts = new address[](max);
        address[] memory rs = new address[](max);
        for (uint256 i; i < max; i++) {
            (ts[i], rs[i]) = (address(uint160(0x10000 + i)), makeAddr("r"));
        }
        vm.prank(reg);
        uint256 g = gasleft();
        assertEq(revenue.registerBy(ts, rs), max);
        g -= gasleft();
        emit log_named_uint("registerBy gas, full batch", g);
        emit log_named_uint("registerBy gas per entry", g / max);
    }
}

/// No first-trade lock: the site decides who qualifies (README §5.1), so a trader can get a referrer after trading
contract RevenueLateRegisterTest is RevenueBase {
    function setUp() public override {
        super.setUp();
        _markets();
    }

    function test_registerBeforeTheFirstSwapWorks() public {
        address r = makeAddr("referrer");
        address t = _referred("t", r); // bound, then traded
        uint256 r0 = _earned(r, ETH);
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        assertGt(_earned(r, ETH), r0, "a referred trader keeps earning its referrer");
    }

    function test_registerByAfterTradingWorks() public {
        address t = _trader("t"); // its $FOBO buy is credited with no referrer
        address r = makeAddr("referrer");
        uint256 team0 = revenue.owed(team, ETH);
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        assertGt(revenue.owed(team, ETH), team0, "unreferred: the share is the team's");
        assertEq(_bind(t, r), 1, "an active trader with no referrer can still be bound");
        assertEq(revenue.referrerOf(t), r);
        uint256 r0 = _earned(r, ETH);
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        assertGt(_earned(r, ETH), r0, "its referrer earns from then on");
        assertEq(_bind(t, makeAddr("other")), 0, "and it never changes");
        assertEq(revenue.referrerOf(t), r);
    }

    /// Snipe-window swaps credit nothing; binding after them works like any other
    function test_registerAfterSnipeWindowSwap() public {
        address u = makeAddr("sniper");
        vm.deal(u, 100 ether);
        vm.prank(alice);
        (address x,) = factory.launch{value: 1 ether}(_signedEth(alice, "X", "X", bytes32(uint256(9)), 0, FOBO_TICK));
        _swap(u, hook.keyFor(ETH, x), true, -1 ether, 1 ether);
        assertEq(_bind(u, makeAddr("referrer")), 1);
    }

    /// An unreferred trader's credit: no storage write for the registry (one cold read), first swap vs next
    function test_gas_unreferredCredit() public {
        address freshCurrency = address(new FoboToken("Fresh", "FRESH"));
        _fundHook(freshCurrency, 2 ether);
        address t = makeAddr("fresh");
        uint256 g = _creditAsHook(freshCurrency, t, 1 ether, 0);
        uint256 g2 = _creditAsHook(freshCurrency, t, 1 ether, 0);
        emit log_named_uint("credit gas, unreferred, first swap", g);
        emit log_named_uint("credit gas, unreferred, next swap", g2);
    }
}

contract RevenueSplitTest is RevenueBase {
    using PoolIdLibrary for PoolKey;

    /// Up to MAX_PARTNERS partners (5)
    uint256 constant N = 5;
    address[N] ps;
    /// The partner fee the split runs use, bps of the gross, and each partner's share of it (_setPartners)
    uint16 constant PARTNER_FEE = 3_000;
    uint256[N] pShares;

    function setUp() public override {
        super.setUp();
        _markets();
        assertEq(revenue.MAX_PARTNERS(), N);
        ps[0] = makeAddr("kol");
        for (uint256 i = 1; i < N; i++) {
            ps[i] = makeAddr(string(abi.encodePacked("p", vm.toString(i + 1))));
        }
    }

    struct Before {
        uint256 hookTeam;
        uint256 claims;
        uint256 team;
        uint256 referrer; // owed plus held (_earned)
        uint256 referrerOwed;
        uint256[N] partners;
        uint256 creatorOwed;
    }

    function _snap(PoolKey memory k, address referrer) internal view returns (Before memory b) {
        address c = Currency.unwrap(k.currency0);
        b.hookTeam = hook.teamOwed(k.currency0);
        b.claims = _revClaims(c);
        b.team = revenue.owed(team, c);
        if (referrer != address(0)) (b.referrer, b.referrerOwed) = (_earned(referrer, c), revenue.owed(referrer, c));
        for (uint256 i; i < N; i++) {
            b.partners[i] = revenue.owed(ps[i], c);
        }
        (,, b.creatorOwed,,) = _pool(k);
    }

    /// One swap of each kind by `trader` in `k`, each checked to the wei against the split rules
    function _checkSwaps(PoolKey memory k, address trader, address referrer, uint256 nPartners) internal {
        bool isFobo = Currency.unwrap(k.currency1) == fobo;
        bool isEth = k.currency0.isAddressZero();
        int256[4] memory amounts = [-int256(0.3 ether), int256(100_000e18), -int256(40_000e18), int256(0.01 ether)];
        for (uint256 kind; kind < 4; kind++) {
            bool buy = kind < 2;
            Before memory b = _snap(k, referrer);
            vm.recordLogs();
            _swap(trader, k, buy, amounts[kind], buy && isEth ? 5 ether : 0);
            SplitLog memory x = _lastSplit();
            Before memory a = _snap(k, referrer);
            uint256 fee = x.protocolFee;
            assertGt(fee, 0);
            assertEq(fee, x.taxToTeam, "the protocol fee is TaxPaid.toTeam");
            assertEq(x.creatorFee, isFobo ? x.taxToCreator : 0, "creator fee only in $FOBO's pool");
            assertEq(x.referrer, referrer);
            uint256 gross = fee + x.creatorFee;
            uint256 toRef = x.toReferrer;
            uint256 toP = x.toPartners;
            uint256 toTeam = x.toTeam;
            uint256 expRef = referrer == address(0) ? 0 : fee * revenue.referralBps() / 10_000;
            assertEq(toRef, expRef, "referrer: the referral fee of the protocol fee");
            assertEq(a.referrer - b.referrer, expRef);
            // never paid in the swap: owed, like everyone else
            assertEq(a.referrerOwed - b.referrerOwed, expRef, "the referrer's share is owed");
            uint256 sumP;
            uint256 partnerFee = gross * revenue.partnerBps() / 10_000;
            for (uint256 i; i < N; i++) {
                uint256 exp = i < nPartners ? partnerFee * pShares[i] / 10_000 : 0;
                assertEq(a.partners[i] - b.partners[i], exp, "partner: its share of the partner fee (of the gross)");
                sumP += exp;
            }
            assertEq(toP, sumP);
            assertEq(toTeam, gross - expRef - sumP, "team: the rest");
            assertEq(a.team - b.team, toTeam);
            assertEq(a.claims - b.claims, gross, "FoboRevenue holds exactly what it owes");
            assertEq(a.hookTeam, b.hookTeam, "nothing left with the hook's team balance");
            if (isFobo) assertEq(a.creatorOwed, b.creatorOwed, "$FOBO's creator fee is shared out");
        }
    }

    /// The first `n` of ps as the partners, sharing PARTNER_FEE: one 100%; two 60/40; three 50/20/30; four
    /// 40/30/20/10; five 30/25/20/15/10 (none: no fee)
    function _setPartners(uint256 n) internal {
        if (n == 0) return _noPartners();
        if (n == 1) pShares = [uint256(10_000), 0, 0, 0, 0];
        else if (n == 2) pShares = [uint256(6_000), 4_000, 0, 0, 0];
        else if (n == 3) pShares = [uint256(5_000), 2_000, 3_000, 0, 0];
        else if (n == 4) pShares = [uint256(4_000), 3_000, 2_000, 1_000, 0];
        else pShares = [uint256(3_000), 2_500, 2_000, 1_500, 1_000];
        address[] memory r = new address[](n);
        uint16[] memory b = new uint16[](n);
        for (uint256 i; i < n; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            (r[i], b[i]) = (ps[i], uint16(pShares[i]));
        }
        revenue.setPartners(r, b);
        revenue.setFeePercent(PARTNER_FEE, revenue.referralBps());
    }

    function _run(uint256 nPartners, bool referred) internal {
        _setPartners(nPartners);
        address r = makeAddr("referrer");
        address t = referred ? _referred("referredTrader", r) : _trader("plainTrader");
        address ref = referred ? r : address(0);
        _checkSwaps(kumoKey, t, ref, nPartners);
        _checkSwaps(nekoKey, t, ref, nPartners);
        _checkSwaps(foboKey, t, ref, nPartners);
    }

    function test_split_0partners_plain() public {
        _run(0, false);
    }

    function test_split_0partners_referred() public {
        _run(0, true);
    }

    function test_split_1partner_plain() public {
        _run(1, false);
    }

    function test_split_1partner_referred() public {
        _run(1, true);
    }

    function test_split_2partners_plain() public {
        _run(2, false);
    }

    function test_split_2partners_referred() public {
        _run(2, true);
    }

    function test_split_3partners_plain() public {
        _run(3, false);
    }

    function test_split_3partners_referred() public {
        _run(3, true);
    }

    function test_split_5partners_plain() public {
        _run(5, false);
    }

    function test_split_5partners_referred() public {
        _run(5, true);
    }

    /// Every fee setting applies from the next swap, the referral fee and the partner fee independently, up to both
    /// adding up to 100% (the team then only keeps the unreferred and rounding remainders)
    function test_split_feeChanges() public {
        address r = makeAddr("referrer");
        _setPartners(3);
        address t = _referred("referredTrader", r);
        revenue.setFeePercent(PARTNER_FEE, 4_000);
        _checkSwaps(kumoKey, t, r, 3);
        revenue.setFeePercent(PARTNER_FEE, 0);
        _checkSwaps(nekoKey, t, r, 3);
        revenue.setFeePercent(6_000, 4_000);
        _checkSwaps(foboKey, t, r, 3);
        revenue.setFeePercent(10_000, 0);
        _checkSwaps(kumoKey, t, r, 3);
    }

    /// The owner's launch example: partner fee 25% [partner1 100%], referral fee 25%. A referred trade: partner1 25% of
    /// the protocol fee (0.1% of volume), the referrer 25% (0.1%), the team the rest (0.2%); not referred: partner1 25%
    /// (0.1%), the team 75% (0.3%). The referrer never dilutes partner 1.
    function test_ownersExample() public {
        address partner1 = ps[0];
        _onePartner(partner1, 2_500);
        assertEq(revenue.referralBps(), 2_500);
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        address u = _trader("plainTrader");
        Before memory b = _snap(kumoKey, r);
        _swap(t, kumoKey, true, -10 ether, 10 ether); // tax 0.25 ETH, protocol fee 0.04 ETH
        Before memory a = _snap(kumoKey, r);
        assertEq(a.referrer - b.referrer, 0.01 ether, "referrer: 25% of the protocol fee");
        assertEq(a.partners[0] - b.partners[0], 0.01 ether, "partner 1: 25%");
        assertEq(a.team - b.team, 0.02 ether, "team: the rest, 50%");
        b = a;
        _swap(u, kumoKey, true, -10 ether, 10 ether);
        a = _snap(kumoKey, r);
        assertEq(a.referrer, b.referrer, "no referrer");
        assertEq(a.partners[0] - b.partners[0], 0.01 ether, "partner 1: 25%");
        assertEq(a.team - b.team, 0.03 ether, "team: 75%");
    }

    /// Two partners sharing a 30% partner fee 60/40, referral fee 25%: on a referred trade in an ETH pair (protocol fee
    /// 0.04) the partners get 0.012 (0.0072 / 0.0048), the referrer 0.01, the team 0.018; in $FOBO's pool (gross 0.1:
    /// creator fee 0.06 + protocol fee 0.04) the partners get 0.03 of the gross (0.018 / 0.012), the referrer still
    /// 0.01 of the protocol fee only, the team 0.06
    function test_twoPartners60_40() public {
        _twoPartners(ps[0], 6_000, ps[1], 4_000, 3_000);
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        Before memory b = _snap(kumoKey, r);
        _swap(t, kumoKey, true, -10 ether, 10 ether);
        Before memory a = _snap(kumoKey, r);
        assertEq(a.partners[0] - b.partners[0], 0.0072 ether, "partner 1: 60% of 30%");
        assertEq(a.partners[1] - b.partners[1], 0.0048 ether, "partner 2: 40% of 30%");
        assertEq(a.referrer - b.referrer, 0.01 ether, "referrer: 25% of the protocol fee");
        assertEq(a.team - b.team, 0.018 ether, "team: the rest");
        b = _snap(foboKey, r);
        _swap(t, foboKey, true, -10 ether, 10 ether);
        a = _snap(foboKey, r);
        assertEq(a.partners[0] - b.partners[0], 0.018 ether, "partner 1: 60% of 30% of the gross");
        assertEq(a.partners[1] - b.partners[1], 0.012 ether, "partner 2: 40% of 30% of the gross");
        assertEq(a.referrer - b.referrer, 0.01 ether, "referrer: of the protocol fee only");
        assertEq(a.team - b.team, 0.06 ether, "team: the rest");
    }

    /// Removing a partner at launch-night settings: the partner fee to 0 first (with it on, the list can't be emptied),
    /// then the empty list; from the next swap the team gets what the partner did
    function test_removePartner() public {
        _onePartner(ps[0], 2_500);
        address t = _trader("plainTrader");
        vm.expectRevert(IFoboRevenue.PartnerFeeActive.selector);
        revenue.setPartners(new address[](0), new uint16[](0));
        revenue.setFeePercent(0, 2_500);
        revenue.setPartners(new address[](0), new uint16[](0));
        Before memory b = _snap(kumoKey, address(0));
        _swap(t, kumoKey, true, -10 ether, 10 ether);
        Before memory a = _snap(kumoKey, address(0));
        assertEq(a.partners[0], b.partners[0], "no more partner share");
        assertEq(a.team - b.team, 0.04 ether, "the team gets all of an unreferred protocol fee");
    }

    /// $FOBO's own creator fee (0.6% of its volume): partners get their share of it, no referral on it, the team the rest
    function test_foboCreatorFeeSplit() public {
        _onePartner(ps[0], 2_500);
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        Before memory b = _snap(foboKey, r);
        _swap(t, foboKey, true, -10 ether, 10 ether); // tax 0.25: creator fee 0.06, protocol fee 0.04
        Before memory a = _snap(foboKey, r);
        assertEq(a.referrer - b.referrer, 0.01 ether, "referrer: 25% of the protocol fee only");
        assertEq(a.partners[0] - b.partners[0], 0.025 ether, "partner: 25% of protocol + creator fee");
        assertEq(a.team - b.team, 0.065 ether, "team: the rest");
        assertEq(a.creatorOwed, b.creatorOwed, "nothing to $FOBO's creator balance in the hook");
    }

    /// $FOBO's creator fee from a swap whose credit failed waits in its creator balance and reaches FoboRevenue through
    /// claimCreator once FoboRevenue works: credited outside any unlock with trader 0 (no protocol fee, and a zero trader
    /// can never be bound), so no referrer ever earns on it, whoever tx.origin is
    function test_foboCreditFailureRecoverable() public {
        _onePartner(ps[0], 2_500);
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        vm.mockCallRevert(address(revenue), abi.encodeWithSelector(IFoboRevenue.credit.selector), "down");
        Before memory b = _snap(foboKey, r);
        assertEq(b.creatorOwed, 0, "every earlier swap was credited");
        vm.recordLogs();
        _swap(t, foboKey, true, -10 ether, 10 ether); // tax 0.25: creator fee 0.06, protocol fee 0.04
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool failed;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IFoboHook.CreditFailed.selector) failed = true;
        }
        assertTrue(failed, "CreditFailed");
        Before memory a = _snap(foboKey, r);
        assertEq(a.creatorOwed - b.creatorOwed, 0.06 ether, "the creator fee waits in $FOBO's creator balance");
        assertEq(a.hookTeam - b.hookTeam, 0.04 ether, "the protocol fee with the team in the hook");
        assertEq(a.referrer, b.referrer, "no referral on a failed credit");
        vm.clearMockedCalls();
        assertEq(_bind(address(0), r), 0, "registerBy skips trader 0");
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.Split(ETH, address(0), address(0), 0, 0.06 ether, 0, 0.015 ether, 0.045 ether);
        vm.prank(t, t);
        hook.claimCreator(foboKey, _creatorOf(foboKey));
        Before memory c = _snap(foboKey, r);
        assertEq(c.creatorOwed, 0);
        assertEq(c.partners[0] - a.partners[0], 0.015 ether, "partner: 25% of it");
        assertEq(c.team - a.team, 0.045 ether, "team: the rest");
        assertEq(c.referrer, a.referrer, "no referral on it");
        assertEq(c.claims - a.claims, 0.06 ether, "FoboRevenue holds exactly what it owes");
        // nothing left: a second claim is a no-op
        vm.recordLogs();
        hook.claimCreator(foboKey, _creatorOf(foboKey));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// Swaps sent through a contract wallet: the trader is tx.origin (the bundler's EOA), so no referral
    function test_referralFollowsTxOrigin() public {
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        address bundler = makeAddr("bundler");
        uint256 r0 = _earned(r, ETH);
        vm.prank(t, bundler);
        router.swap{value: 1 ether}(
            kumoKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(_earned(r, ETH), r0, "tx.origin isn't the referred trader: no referral");
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        assertGt(_earned(r, ETH), r0);
    }

    /// The snipe window has no protocol fee (60% floor / 40% burn): nothing is credited, nothing is called ($FOBO's own
    /// pool aside: its 40% is its creator fee, RevenueFoboSnipeTest)
    function test_snipeWindowCreditsNothing() public {
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        vm.prank(alice);
        (address x,) = factory.launch{value: 1 ether}(_signedEth(alice, "X", "X", bytes32(uint256(9)), 0, FOBO_TICK));
        PoolKey memory xk = hook.keyFor(ETH, x);
        uint256 c0 = _revClaims(ETH);
        uint256 r0 = _earned(r, ETH);
        _swap(t, xk, true, -1 ether, 1 ether);
        assertEq(_revClaims(ETH), c0);
        assertEq(_earned(r, ETH), r0);
    }

    function test_claims() public {
        _onePartner(ps[0], 2_500);
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        _swap(t, kumoKey, true, -10 ether, 10 ether);
        _swap(t, nekoKey, true, -100_000e18, 0);
        _swap(t, foboKey, true, -10 ether, 10 ether);
        address[2] memory cur = [ETH, fobo];
        for (uint256 j; j < 2; j++) {
            assertEq(
                _earned(r, cur[j]), revenue.owed(r, cur[j]), "the referrer was paid nothing in the swaps: all owed"
            );
        }
        // the partner, the team and the referrer alike: anyone (the keeper) triggers the claim, it pays the account
        address[3] memory who = [ps[0], team, r];
        for (uint256 i; i < 3; i++) {
            for (uint256 j; j < 2; j++) {
                uint256 owed = revenue.owed(who[i], cur[j]);
                assertGt(owed, 0);
                uint256 bal = cur[j] == ETH ? who[i].balance : FoboToken(fobo).balanceOf(who[i]);
                uint256 claims = _revClaims(cur[j]);
                vm.expectEmit(address(revenue));
                emit IFoboRevenue.RevenueClaimed(who[i], cur[j], owed);
                vm.prank(makeAddr("anyone")); // anyone can trigger it; it pays the account
                assertEq(revenue.claim(who[i], cur[j], who[i]), owed);
                uint256 got = (cur[j] == ETH ? who[i].balance : FoboToken(fobo).balanceOf(who[i])) - bal;
                assertEq(got, owed, "paid in the pool's quote");
                assertEq(revenue.owed(who[i], cur[j]), 0);
                assertEq(claims - _revClaims(cur[j]), owed);
                assertEq(revenue.claim(who[i], cur[j], who[i]), 0, "nothing twice");
            }
        }
        assertEq(_revClaims(ETH), 0);
        assertEq(_revClaims(fobo), 0);
    }

    /// A recipient that can't take ETH only blocks its own claim, never swaps or anyone else's
    function test_revertingRecipientBlocksOnlyItself() public {
        address bad = address(new RevertingReceiver());
        _twoPartners(bad, 5_000, ps[0], 5_000, 2_000);
        address t = _trader("plainTrader");
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        vm.expectRevert();
        revenue.claim(bad, ETH, bad);
        revenue.claim(ps[0], ETH, ps[0]);
        revenue.claim(team, ETH, team);
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        assertGt(revenue.owed(bad, ETH), 0);
    }

    /// Only the account can send its claim elsewhere (the way out for a recipient that can't take ETH); anyone else
    /// can only pay the account itself
    function test_claimToAnotherAddress() public {
        address bad = address(new RevertingReceiver());
        _twoPartners(bad, 5_000, ps[0], 5_000, 2_000);
        _swap(_trader("plainTrader"), kumoKey, true, -1 ether, 1 ether);
        uint256 owed = revenue.owed(bad, ETH);
        address alt = makeAddr("alt");
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(IFoboRevenue.NotAccount.selector);
        revenue.claim(bad, ETH, alt);
        vm.prank(alt);
        vm.expectRevert(IFoboRevenue.NotAccount.selector);
        revenue.claim(bad, ETH, alt);
        vm.prank(bad);
        vm.expectRevert(IFoboRevenue.ZeroAddress.selector);
        revenue.claim(bad, ETH, address(0));
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.RevenueClaimed(bad, ETH, owed);
        vm.prank(bad);
        assertEq(revenue.claim(bad, ETH, alt), owed);
        assertEq(alt.balance, owed, "paid to the address it picked");
        assertEq(revenue.owed(bad, ETH), 0);
    }

    /// Changing the config applies to swaps from then on; what's owed stays owed
    function test_configChangesAreNotRetroactive() public {
        _onePartner(ps[0], 2_500);
        address t = _trader("plainTrader");
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        uint256 owedBefore = revenue.owed(ps[0], ETH);
        _noPartners();
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        assertEq(revenue.owed(ps[0], ETH), owedBefore, "removed partner keeps what it earned, earns no more");
        address t2 = makeAddr("team2");
        uint256 teamBefore = revenue.owed(team, ETH);
        revenue.setTeam(t2);
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        assertEq(revenue.owed(team, ETH), teamBefore, "the old team keeps what it was owed");
        assertGt(revenue.owed(t2, ETH), 0);
        revenue.claim(team, ETH, team);
    }

    /// The worst credit (run with --isolate: each call a cold transaction): a referred trader, MAX_PARTNERS partners
    /// and every balance (each partner's, the referrer's, the team's) written for the first time, in a currency
    /// FoboRevenue never held. Also an unreferred trader's, and warm balances.
    function test_gas_creditWorst() public {
        _setPartners(revenue.MAX_PARTNERS());
        address fresh = address(new FoboToken("Fresh", "FRESH"));
        _fundHook(fresh, 10 ether);
        address r = makeAddr("freshReferrer");
        address t = makeAddr("freshTrader");
        _bind(t, r);
        uint256 g = _creditAsHook(fresh, t, 1 ether, 1 ether);
        assertEq(revenue.owed(r, fresh), 0.25 ether, "the referrer's share is owed");
        emit log_named_uint("credit gas, worst (referred, MAX_PARTNERS partners, all fresh)", g);
        assertLt(g * 3 / 2, hook.CREDIT_GAS(), "CREDIT_GAS leaves 50% headroom");
        // a never-seen unreferred trader, all fresh (no referrer balance: the registry read only)
        address fresh2 = address(new FoboToken("Fresh2", "FRESH2"));
        _fundHook(fresh2, 10 ether);
        g = _creditAsHook(fresh2, makeAddr("neverSeen"), 1 ether, 1 ether);
        emit log_named_uint("credit gas, unreferred, MAX_PARTNERS partners, all fresh", g);
        assertLt(g * 3 / 2, hook.CREDIT_GAS(), "CREDIT_GAS leaves 50% headroom");
        g = _creditAsHook(fresh, t, 1 ether, 0);
        emit log_named_uint("credit gas, warm balances, referred, MAX_PARTNERS partners", g);
    }

    /// Whole swaps (run with --isolate for cold-transaction numbers): plain; referred (its share owed); and referred
    /// with MAX_PARTNERS partners
    function test_gas_swapWithCredit() public {
        address t = _trader("plainTrader");
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        uint256 g = gasleft();
        _swap(t, kumoKey, true, -1 ether, 1 ether);
        g -= gasleft();
        emit log_named_uint("swap gas, not referred, no partners", g);
        address r = makeAddr("referrer");
        address u = _referred("referredTrader", r);
        _swap(u, kumoKey, true, -1 ether, 1 ether);
        g = gasleft();
        _swap(u, kumoKey, true, -1 ether, 1 ether);
        g -= gasleft();
        emit log_named_uint("swap gas, referred, no partners", g);
        _setPartners(revenue.MAX_PARTNERS());
        _swap(u, kumoKey, true, -1 ether, 1 ether);
        g = gasleft();
        _swap(u, kumoKey, true, -1 ether, 1 ether);
        g -= gasleft();
        emit log_named_uint("swap gas, referred, MAX_PARTNERS partners", g);
    }
}

/// $FOBO's own snipe window, partners set before its launch
contract RevenueFoboSnipeTest is RevenueBase {
    using PoolIdLibrary for PoolKey;

    /// The 40% other pools burn is $FOBO's creator fee: FoboRevenue shares it out in the swap that paid it, with the
    /// partners of that moment (a later setPartners doesn't move it) and no referral even for a referred trader (a
    /// referral is only ever of the protocol fee, and the window has none). Nothing waits in $FOBO's creator balance.
    function test_foboSnipeShareCreditedInTheSwap() public {
        address p0 = makeAddr("kol");
        address p1 = makeAddr("p2");
        address[] memory rs = new address[](2);
        uint16[] memory bs = new uint16[](2);
        (rs[0], bs[0], rs[1], bs[1]) = (p0, 6_000, p1, 4_000);
        revenue.setPartners(rs, bs);
        revenue.setFeePercent(3_000, 2_500);
        address r = makeAddr("referrer");
        address t = makeAddr("referredTrader");
        assertEq(_bind(t, r), 1);
        vm.deal(t, 10 ether);
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 10);
        (uint256 rate, bool snipe) = Tax.rate(10);
        assertTrue(snipe, "inside the window");
        uint256 share = Tax.snipeBurn(Tax.ofGross(1 ether, rate));
        uint256 toP0 = (share * 3_000 / 10_000) * 6_000 / 10_000;
        uint256 toP1 = (share * 3_000 / 10_000) * 4_000 / 10_000;
        uint256 team0 = revenue.owed(team, ETH);
        uint256 claims0 = _revClaims(ETH);
        uint256 hookTeam0 = hook.teamOwed(foboKey.currency0);
        vm.expectEmit(address(revenue));
        emit IFoboRevenue.Split(ETH, t, r, 0, share, 0, toP0 + toP1, share - toP0 - toP1);
        vm.recordLogs();
        _swap(t, foboKey, true, -1 ether, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.CreditFailed.selector, "credited");
        }
        (,, uint256 creatorOwed,,) = _pool(foboKey);
        assertEq(creatorOwed, 0, "nothing waits in $FOBO's creator balance");
        assertEq(revenue.owed(p0, ETH), toP0, "partner: its share");
        assertEq(revenue.owed(p1, ETH), toP1, "partner: its share");
        assertEq(revenue.owed(team, ETH) - team0, share - toP0 - toP1, "team: the rest");
        assertEq(revenue.owed(r, ETH) + r.balance, 0, "no referral on it");
        assertEq(_revClaims(ETH) - claims0, share, "FoboRevenue holds exactly what it owes");
        assertEq(hook.teamOwed(foboKey.currency0), hookTeam0, "nothing to the team in the hook");
        // the partners of the swap's moment keep their share: a later list moves nothing already credited
        _noPartners();
        vm.recordLogs();
        hook.claimCreator(foboKey, _creatorOf(foboKey));
        assertEq(vm.getRecordedLogs().length, 0, "nothing to claim");
        assertEq(revenue.owed(p0, ETH), toP0);
        assertEq(revenue.owed(p1, ETH), toP1);
    }
}

/// A referrer with code that would call back into the PoolManager when paid (sync() in the middle of someone's swap is
/// what could break the trader's settlement). FoboRevenue never pays anyone in a swap, so it only ever runs inside a
/// claim (FoboRevenue's own unlock, where it is harmless).
contract PoolManagerPoker {
    IPoolManager immutable pm;
    Currency immutable cur;
    uint256 public calls;

    constructor(IPoolManager _pm, address _cur) {
        pm = _pm;
        cur = Currency.wrap(_cur);
    }

    receive() external payable {
        calls++;
        pm.sync(cur);
    }
}

/// Nobody is paid in the swap (README §5.1): the referrer's share is owed like the partners' and the team's, whatever
/// the referrer is (an account with no code, a contract), in the pool's quote, and the keeper's claim pays it later.
contract RevenueReferrerOwedTest is RevenueBase {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        _markets();
    }

    /// One buy of `k` by `t` (logs recorded): its Split
    function _buy(PoolKey memory k, address t) internal returns (SplitLog memory) {
        bool isEth = k.currency0.isAddressZero();
        vm.recordLogs();
        _swap(t, k, true, isEth ? -1 ether : -100_000e18, isEth ? 1 ether : 0);
        return _lastSplit();
    }

    function _held(address who, address currency) internal view returns (uint256) {
        return currency == ETH ? who.balance : FoboToken(currency).balanceOf(who);
    }

    /// An account with no code: owed in the pool's quote (ETH in KUMO and $FOBO's own pool, $FOBO in NEKO), nothing
    /// sent in the swap; anyone's claim (the keeper's) pays it the whole share
    function test_referrerIsOwedNotPaidInTheSwap() public {
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        PoolKey[3] memory ks = [kumoKey, foboKey, nekoKey];
        for (uint256 i; i < 3; i++) {
            address c = Currency.unwrap(ks[i].currency0);
            uint256 held = _held(r, c);
            uint256 owed = revenue.owed(r, c);
            uint256 claims = _revClaims(c);
            SplitLog memory x = _buy(ks[i], t);
            assertGt(x.toReferrer, 0);
            assertEq(_held(r, c), held, "nothing sent in the swap");
            assertEq(revenue.owed(r, c) - owed, x.toReferrer, "owed, in the pool's quote");
            assertEq(_revClaims(c) - claims, x.protocolFee + x.creatorFee, "claims == what it owes");
        }
        for (uint256 j; j < 2; j++) {
            address c = j == 0 ? ETH : fobo;
            uint256 owed = revenue.owed(r, c);
            uint256 held = _held(r, c);
            vm.prank(makeAddr("keeper"));
            assertEq(revenue.claim(r, c, r), owed);
            assertEq(_held(r, c) - held, owed, "the keeper's claim pays the referrer");
        }
    }

    /// A referrer with code is never called during the swap, so it can't re-enter the PoolManager mid-swap: the trade
    /// settles normally. Its claim pays it later.
    function test_contractReferrerIsOwed() public {
        PoolManagerPoker poker = new PoolManagerPoker(pm, fobo);
        address t = _referred("referredTrader", address(poker));
        SplitLog memory x = _buy(nekoKey, t);
        assertGt(x.toReferrer, 0);
        assertEq(revenue.owed(address(poker), fobo), x.toReferrer, "owed");
        _buy(kumoKey, t);
        uint256 owedEth = revenue.owed(address(poker), ETH);
        assertGt(owedEth, 0);
        assertEq(poker.calls(), 0, "never called in a swap");
        assertEq(revenue.claim(address(poker), ETH, address(poker)), owedEth);
        assertEq(address(poker).balance, owedEth);
        assertEq(poker.calls(), 1, "paid in its claim");
    }

    /// There is no in-swap payment path left to call
    function test_noPayReferrer() public {
        (bool ok,) = address(revenue)
            .call(abi.encodeWithSignature("payReferrer(address,address,uint256)", ETH, address(this), 1));
        assertFalse(ok, "payReferrer(...) doesn't exist");
        (ok,) = address(revenue).call(abi.encodeWithSignature("PAY_GAS()"));
        assertFalse(ok, "PAY_GAS() doesn't exist");
        // nor in the hook: a creator is never paid mid-trade, and the $FOBO buy-and-burn left it for FoboBurner
        (ok,) =
            address(hook).call(abi.encodeWithSignature("payFromHook(address,address,uint256)", ETH, address(this), 1));
        assertFalse(ok, "payFromHook(...) doesn't exist");
        (ok,) = address(hook).call(abi.encodeWithSignature("buyBurnFobo()"));
        assertFalse(ok, "buyBurnFobo() doesn't exist");
        (ok,) = address(hook).call(abi.encodeWithSignature("burnOwed(address)", ETH));
        assertFalse(ok, "burnOwed(...) doesn't exist");
    }

    /// The hook makes the FoboRevenue it is deployed with its ERC-6909 operator (credit takes the claims itself); no one
    /// else is
    function test_revenueIsTheHooksOperator() public view {
        assertTrue(pm.isOperator(address(hook), address(revenue)));
        assertFalse(pm.isOperator(address(hook), address(this)));
    }
}

/// FoboRevenue that always reverts
contract RevertingRevenue {
    function credit(address, address, uint256, uint256) external pure {
        revert("broken");
    }
}

/// FoboRevenue that burns all the gas it gets
contract GasBurnerRevenue {
    uint256 public x;

    function credit(address, address, uint256, uint256) external {
        while (true) {
            x++;
        }
    }
}

/// FoboRevenue that returns a huge revert reason (a returndata bomb)
contract BombRevenue {
    function credit(address, address, uint256, uint256) external pure {
        assembly {
            revert(0, 1000000)
        }
    }
}

/// A misbehaving FoboRevenue never bricks swaps: the protocol fee stays with the team in the hook, $FOBO's creator fee in
/// its creator balance (claimCreator shares it out through FoboRevenue, so it waits there, never paid elsewhere),
/// CreditFailed says so, and the hook's claims still equal what it owes.
abstract contract BrokenRevenueTest is RevenueBase {
    using PoolIdLibrary for PoolKey;

    address broken;

    function _broken() internal virtual returns (address);

    function _revenueForHook() internal override returns (address) {
        broken = _broken();
        return broken;
    }

    function test_swapsStillWork() public {
        _markets();
        address t = _trader("plainTrader");
        PoolKey[3] memory ks = [kumoKey, nekoKey, foboKey];
        for (uint256 i; i < 3; i++) {
            PoolKey memory k = ks[i];
            bool isEth = k.currency0.isAddressZero();
            uint256 team0 = hook.teamOwed(k.currency0);
            (,, uint256 cr0,,) = _pool(k);
            vm.recordLogs();
            _swap(t, k, true, isEth ? -1 ether : -100_000e18, isEth ? 1 ether : 0);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 tax;
            bool failed;
            for (uint256 j; j < logs.length; j++) {
                if (logs[j].topics[0] == IFoboHook.TaxPaid.selector) {
                    (,,, uint256 toCreator, uint256 toTeam,) =
                        abi.decode(logs[j].data, (bool, uint256, uint256, uint256, uint256, uint256));
                    tax = toTeam;
                    (,, uint256 cr1,,) = _pool(k);
                    assertEq(cr1 - cr0, toCreator, "the creator fee goes to the creator's balance (owed)");
                }
                if (logs[j].topics[0] == IFoboHook.CreditFailed.selector) failed = true;
            }
            assertTrue(failed, "CreditFailed");
            assertGt(tax, 0);
            assertEq(hook.teamOwed(k.currency0) - team0, tax, "protocol fee to the team in the hook");
            assertEq(pm.balanceOf(broken, k.currency0.toId()), 0, "nothing sent to the broken contract");
            _swap(t, k, false, -int256(FoboToken(Currency.unwrap(k.currency1)).balanceOf(t) / 2), 0);
        }
        // the team gets paid; $FOBO's creator fee only ever goes to FoboRevenue, so it stays owed
        uint256 tb = team.balance;
        hook.claimTeam(Currency.wrap(ETH));
        assertGt(team.balance, tb);
        (,, uint256 cr,,) = _pool(foboKey);
        assertGt(cr, 0);
        address none = _creatorOf(foboKey); // $FOBO's pool has none: `to` unused
        vm.expectRevert();
        hook.claimCreator(foboKey, none);
        (,, uint256 cr2,,) = _pool(foboKey);
        assertEq(cr2, cr, "still owed");
    }
}

contract RevertingRevenueTest is BrokenRevenueTest {
    function _broken() internal override returns (address) {
        return address(new RevertingRevenue());
    }
}

contract GasBurnerRevenueTest is BrokenRevenueTest {
    function _broken() internal override returns (address) {
        return address(new GasBurnerRevenue());
    }
}

contract BombRevenueTest is BrokenRevenueTest {
    function _broken() internal override returns (address) {
        return address(new BombRevenue());
    }
}

/// Too little gas for the credit reverts NeedGas instead of quietly giving the share to the team, so a wallet's gas
/// estimate always includes the credit; the least gas that works books the referrer's share (never the CreditFailed
/// fallback, which would give it to the team)
contract RevenueNeedGasTest is RevenueBase {
    function test_creditNeedsGasNotSilentFallback() public {
        _markets();
        _onePartner(makeAddr("kol"), 2_500);
        address r = makeAddr("referrer");
        address t = _referred("referredTrader", r);
        _swap(t, kumoKey, true, -1 ether, 1 ether); // the block's raise is done; the next swaps only credit
        int256[4] memory amounts = [-int256(0.01 ether), int256(100_000e18), -int256(100_000e18), int256(0.001 ether)];
        for (uint256 k; k < 4; k++) {
            bool buy = k < 2;
            bytes memory call = abi.encodeCall(
                PoolSwapTest.swap,
                (
                    kumoKey,
                    IPoolManager.SwapParams({
                        zeroForOne: buy,
                        amountSpecified: amounts[k],
                        sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                )
            );
            uint256 snap = vm.snapshotState();
            uint256 lo = 50_000;
            uint256 hi = 3_000_000;
            while (hi - lo > 500) {
                uint256 mid = (lo + hi) / 2;
                vm.prank(t, t);
                (bool ok,) = address(router).call{gas: mid, value: buy ? 1 ether : 0}(call);
                vm.revertToState(snap);
                if (ok) hi = mid;
                else lo = mid;
            }
            uint256 owed0 = revenue.owed(r, ETH);
            vm.recordLogs();
            vm.prank(t, t);
            (bool ok2,) = address(router).call{gas: hi, value: buy ? 1 ether : 0}(call);
            assertTrue(ok2);
            assertGt(revenue.owed(r, ETH), owed0, "the least gas that works books the referrer's share");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool split;
            for (uint256 j; j < logs.length; j++) {
                assertTrue(logs[j].topics.length == 0 || logs[j].topics[0] != IFoboHook.CreditFailed.selector);
                if (logs[j].topics.length != 0 && logs[j].topics[0] == IFoboRevenue.Split.selector) split = true;
            }
            assertTrue(split, "credited (Split)");
            emit log_named_uint("least gas", hi);
            vm.revertToState(snap);
        }
    }
}
