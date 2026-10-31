// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {FoboVesting} from "../src/FoboVesting.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {IFoboVesting} from "../src/interfaces/IFoboVesting.sol";
import {MockQuote, QuoteBase} from "./QuoteDecimals.t.sol";

contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") {
        _mint(msg.sender, 1e30);
    }
}

/// Calls back into FoboVesting from its transfers (once armed): every lock and claim must refuse the reentry.
contract ReentrantToken is ERC20 {
    FoboVesting public vesting;
    bool public armed;
    bool public tryClaim;

    constructor(FoboVesting v) ERC20("Reenter", "RE") {
        vesting = v;
        _mint(msg.sender, 1e30);
    }

    function arm(bool claim_) external {
        armed = true;
        tryClaim = claim_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (!armed) return;
        armed = false;
        if (tryClaim) vesting.claim(0);
        else vesting.lock(address(this), 1, 1, address(this));
    }
}

/// FoboVesting on its own: the months, the linear math, claims, fee-on-transfer tokens, reentrancy, many locks.
contract FoboVestingTest is Test {
    FoboVesting vesting;
    PlainToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant MONTH = 365 days / 12;

    function setUp() public {
        vm.warp(1_700_000_000);
        vesting = new FoboVesting();
        token = new PlainToken();
        token.approve(address(vesting), type(uint256).max);
    }

    function test_monthIsATwelfthOfAYear() public view {
        assertEq(vesting.MONTH(), MONTH);
        assertEq(12 * vesting.MONTH(), 365 days);
    }

    function test_onlyOneThreeSixTwelveMonths() public {
        uint8[6] memory bad = [0, 2, 4, 5, 13, 255];
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(IFoboVesting.BadMonths.selector);
            vesting.lock(address(token), 1e18, bad[i], alice);
        }
        uint8[4] memory good = [1, 3, 6, 12];
        for (uint256 i; i < good.length; i++) {
            uint256 id = vesting.lock(address(token), 1e18, good[i], alice);
            assertEq(vesting.getLock(id).duration, good[i] * MONTH);
        }
    }

    function test_refusesZeroes() public {
        vm.expectRevert(IFoboVesting.ZeroAddress.selector);
        vesting.lock(address(token), 1e18, 1, address(0));
        vm.expectRevert(IFoboVesting.ZeroAddress.selector);
        vesting.lock(address(0), 1e18, 1, alice);
        vm.expectRevert(IFoboVesting.ZeroAmount.selector);
        vesting.lock(address(token), 0, 1, alice);
        vm.expectRevert(IFoboVesting.UnknownLock.selector);
        vesting.claim(0);
        vm.expectRevert(IFoboVesting.UnknownLock.selector);
        vesting.claimable(0);
        vm.expectRevert(IFoboVesting.UnknownLock.selector);
        vesting.getLock(0);
    }

    function test_lockRecordsAndEmits() public {
        vm.expectEmit(address(vesting));
        emit IFoboVesting.Locked(0, address(token), alice, address(this), 1200e18, uint64(block.timestamp), uint32(6 * MONTH));
        uint256 id = vesting.lock(address(token), 1200e18, 6, alice);
        IFoboVesting.Lock memory l = vesting.getLock(id);
        assertEq(l.token, address(token));
        assertEq(l.beneficiary, alice);
        assertEq(l.amount, 1200e18);
        assertEq(l.claimed, 0);
        assertEq(l.start, block.timestamp);
        assertEq(token.balanceOf(address(vesting)), 1200e18);
        assertEq(vesting.lockCount(), 1);
    }

    /// Nothing at the start, linear in between (to the second), everything at the end and after
    function test_linearAtStartMiddleEnd() public {
        uint256 id = vesting.lock(address(token), 1200e18, 12, alice);
        assertEq(vesting.claimable(id), 0, "nothing at the start");
        vm.expectRevert(IFoboVesting.NothingToClaim.selector);
        vesting.claim(id);

        vm.warp(block.timestamp + 1);
        assertEq(vesting.claimable(id), 1200e18 / uint256(365 days), "one second's worth");

        vm.warp(1_700_000_000 + 3 * MONTH);
        assertEq(vesting.claimable(id), 300e18, "a quarter at 3 of 12 months");
        vm.warp(1_700_000_000 + 6 * MONTH);
        assertEq(vesting.claimable(id), 600e18, "half at the middle");
        vm.warp(1_700_000_000 + 12 * MONTH - 1);
        assertLt(vesting.claimable(id), 1200e18, "not all of it a second before the end");
        vm.warp(1_700_000_000 + 12 * MONTH);
        assertEq(vesting.claimable(id), 1200e18, "all of it at the end");
        vm.warp(1_700_000_000 + 10 * 365 days);
        assertEq(vesting.claimable(id), 1200e18, "never more");
    }

    /// Anyone may trigger a claim; it always pays the beneficiary what vested since the last one, and never twice
    function test_claimTwiceAnyonePaysBeneficiary() public {
        uint256 id = vesting.lock(address(token), 100e18, 1, alice);
        vm.warp(block.timestamp + MONTH / 2);
        vm.prank(bob);
        vm.expectEmit(address(vesting));
        emit IFoboVesting.Claimed(id, 50e18);
        assertEq(vesting.claim(id), 50e18);
        assertEq(token.balanceOf(alice), 50e18);
        assertEq(token.balanceOf(bob), 0);
        vm.expectRevert(IFoboVesting.NothingToClaim.selector);
        vesting.claim(id);

        vm.warp(block.timestamp + MONTH); // past the end
        vm.prank(alice);
        assertEq(vesting.claim(id), 50e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(vesting.getLock(id).claimed, 100e18);
        assertEq(token.balanceOf(address(vesting)), 0);
        vm.expectRevert(IFoboVesting.NothingToClaim.selector);
        vesting.claim(id);
    }

    /// A fee-on-transfer token is locked at what arrived, so the last claim is always payable
    function test_feeOnTransferLocksWhatArrived() public {
        MockQuote fot = new MockQuote(18, 100); // 1% burned on every transfer
        fot.approve(address(vesting), type(uint256).max);
        uint256 id = vesting.lock(address(fot), 100e18, 3, alice);
        assertEq(vesting.getLock(id).amount, 99e18);
        assertEq(fot.balanceOf(address(vesting)), 99e18);
        vm.warp(block.timestamp + 3 * MONTH);
        assertEq(vesting.claim(id), 99e18);
        assertEq(fot.balanceOf(address(vesting)), 0);
    }

    function test_reentrancyRefused() public {
        ReentrantToken re = new ReentrantToken(vesting);
        re.approve(address(vesting), type(uint256).max);
        // a claim reentered from its payout
        vesting.lock(address(re), 10e18, 1, alice);
        vm.warp(block.timestamp + MONTH);
        re.arm(true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vesting.claim(0);
        assertEq(vesting.claimable(0), 10e18, "nothing paid");
        // a lock reentered from its own pull (the revert above undid nothing but the claim: re-arm for a lock)
        re.arm(false);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vesting.lock(address(re), 10e18, 1, alice);
        assertEq(vesting.lockCount(), 1);
    }

    /// Many locks of several tokens and beneficiaries: each keeps its own books, the enumerations find them
    function test_manyLocks() public {
        PlainToken other = new PlainToken();
        other.approve(address(vesting), type(uint256).max);
        uint8[4] memory months = [1, 3, 6, 12];
        for (uint256 i; i < 40; i++) {
            address who = i % 2 == 0 ? alice : bob;
            address t = i % 4 < 2 ? address(token) : address(other);
            vesting.lock(t, (i + 1) * 1e18, months[i % 4], who);
            vm.warp(block.timestamp + 1 days);
        }
        assertEq(vesting.lockCount(), 40);
        assertEq(vesting.locksOf(alice).length, 20);
        assertEq(vesting.locksOf(bob).length, 20);
        assertEq(vesting.locksOfToken(address(token)).length, 20);
        assertEq(vesting.locksOfToken(address(other)).length, 20);
        vm.warp(block.timestamp + 365 days);
        uint256 a0 = token.balanceOf(alice) + other.balanceOf(alice);
        uint256 total;
        uint256[] memory ids = vesting.locksOf(alice);
        for (uint256 i; i < ids.length; i++) {
            total += vesting.claim(ids[i]);
        }
        assertEq(token.balanceOf(alice) + other.balanceOf(alice) - a0, total);
        assertEq(total, 400e18, "alice's 20 locks: 1 + 3 + ... + 39 tokens");
        assertEq(token.balanceOf(address(vesting)) + other.balanceOf(address(vesting)), 420e18, "bob's still locked");
    }

    /// Huge amounts never overflow the math (mulDiv)
    function testFuzz_vestedNeverExceedsAmount(uint256 amount, uint32 elapsed) public {
        amount = bound(amount, 1, 1e30);
        uint256 id = vesting.lock(address(token), amount, 1, alice);
        vm.warp(block.timestamp + elapsed);
        uint256 c = vesting.claimable(id);
        assertLe(c, amount);
        if (elapsed >= MONTH) assertEq(c, amount);
        else assertEq(c, amount * elapsed / MONTH);
    }
}

/// FoboFactory.launch with LaunchParams.vestMonths: the dev buy goes into FoboVesting for the creator in the launch
/// transaction, on every kind of pair. Attack check: the creator can't get the tokens out early.
contract VestingLaunchTest is QuoteBase {
    uint256 constant MONTH = 365 days / 12;
    uint256 constant DEV = 20_000_000e18;

    receive() external payable {}

    function _vested(IFoboFactory.LaunchParams memory lp, uint8 months)
        internal
        pure
        returns (IFoboFactory.LaunchParams memory)
    {
        lp.vestMonths = months;
        return lp;
    }

    function _checkLocked(address token, address creator, uint256 dev, uint8 months, uint256 id) internal view {
        assertEq(FoboToken(token).balanceOf(creator), 0, "the creator holds none of it");
        assertEq(FoboToken(token).balanceOf(address(factory)), 0, "nothing left in the factory");
        assertEq(FoboToken(token).balanceOf(address(vesting)), dev, "all of it locked");
        IFoboVesting.Lock memory l = vesting.getLock(id);
        assertEq(l.token, token);
        assertEq(l.beneficiary, creator);
        assertEq(l.amount, dev);
        assertEq(l.duration, months * MONTH);
        assertEq(l.start, block.timestamp);
        assertEq(vesting.claimable(id), 0);
        assertEq(FoboToken(token).allowance(address(factory), address(vesting)), 0, "no allowance left over");
    }

    function test_foboLaunchVests() public {
        address creator = address(this);
        IFoboFactory.LaunchParams memory lp = _vested(_params("FOBO", "FOBO", bytes32(0), DEV, FOBO_TICK), 12);
        (fobo,) = factory.launch{value: 10 ether}(lp);
        _checkLocked(fobo, creator, DEV, 12, 0);
        vm.warp(block.timestamp + 6 * MONTH);
        vesting.claim(0);
        assertEq(FoboToken(fobo).balanceOf(creator), DEV / 2);
    }

    function test_ethPairEveryVestLength() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        uint8[4] memory months = [1, 3, 6, 12];
        for (uint256 i; i < months.length; i++) {
            address alice = _user(string.concat("eth", vm.toString(i)));
            string memory name = string.concat("E", vm.toString(i));
            bytes32 s = _saltAfter(alice, address(0), name, name);
            uint256 e0 = alice.balance;
            vm.prank(alice);
            (address t,) = factory.launch{value: 10 ether}(_vested(_signedEth(alice, name, name, s, DEV, FOBO_TICK), months[i]));
            _checkLocked(t, alice, DEV, months[i], vesting.lockCount() - 1);
            assertGt(e0 - alice.balance, FEE, "the dev buy was paid as usual");
        }
    }

    function test_foboPairEveryVestLength() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        uint8[4] memory months = [1, 3, 6, 12];
        for (uint256 i; i < months.length; i++) {
            address alice = _user(string.concat("fobo", vm.toString(i)));
            _fundFobo(alice, 1 ether);
            string memory name = string.concat("F", vm.toString(i));
            bytes32 s = _salt(alice, name, name);
            vm.prank(alice);
            uint256 dev = 2_000_000e18; // paid in $FOBO: a small buy keeps $FOBO (and so the start band) where it is
            (address t,) = factory.launch{value: FEE}(_vested(_signed(alice, name, name, s, dev, 0), months[i]));
            _checkLocked(t, alice, dev, months[i], vesting.lockCount() - 1);
        }
    }

    function test_sixDecimalPairEveryVestLength() public {
        _launchFobo();
        (MockQuote q, int24 mid) = _allowQuote(6, 0);
        uint8[4] memory months = [1, 3, 6, 12];
        for (uint256 i; i < months.length; i++) {
            address alice = _user(string.concat("usd", vm.toString(i)));
            _fund(q, alice, 1_000_000);
            string memory name = string.concat("U", vm.toString(i));
            bytes32 s = _saltAfter(alice, address(q), name, name);
            IFoboFactory.LaunchParams memory lp = _signedBy(
                startSignerKey, alice, address(q), name, name, s, DEV, mid / 60 * 60, vm.getBlockTimestamp() + 1 hours
            );
            vm.prank(alice);
            (address t,) = factory.launch{value: FEE}(_vested(lp, months[i]));
            _checkLocked(t, alice, DEV, months[i], vesting.lockCount() - 1);
        }
    }

    /// vestMonths 0: the dev buy goes to the creator, as before
    function test_noVestPaysCreator() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        bytes32 s = _saltAfter(alice, address(0), "Neko", "NEKO");
        vm.prank(alice);
        (address t,) = factory.launch{value: 10 ether}(_signedEth(alice, "Neko", "NEKO", s, DEV, FOBO_TICK));
        assertEq(FoboToken(t).balanceOf(alice), DEV);
        assertEq(vesting.lockCount(), 0);
    }

    function test_badMonthsRevert() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        bytes32 s = _saltAfter(alice, address(0), "Neko", "NEKO");
        uint8[4] memory bad = [2, 5, 24, 255];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(alice);
            vm.expectRevert(IFoboVesting.BadMonths.selector);
            factory.launch{value: 10 ether}(_vested(_signedEth(alice, "Neko", "NEKO", s, DEV, FOBO_TICK), bad[i]));
        }
    }

    /// A vest without a dev buy is a mistake (nothing to lock): refused, not ignored
    function test_vestWithoutDevBuyReverts() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _saltAfter(alice, address(0), "Neko", "NEKO");
        vm.prank(alice);
        vm.expectRevert(IFoboFactory.VestWithoutDevBuy.selector);
        factory.launch{value: FEE}(_vested(_signedEth(alice, "Neko", "NEKO", s, 0, FOBO_TICK), 3));
    }

    /// The vest length isn't signed: the same signed start launches with any of them (the digest is unchanged)
    function test_vestNotPartOfTheSignedStart() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        bytes32 s = _saltAfter(alice, address(0), "Neko", "NEKO");
        IFoboFactory.LaunchParams memory lp = _signedEth(alice, "Neko", "NEKO", s, DEV, FOBO_TICK);
        lp.vestMonths = 6;
        vm.prank(alice);
        factory.launch{value: 10 ether}(lp);
        assertEq(vesting.lockCount(), 1);
    }

    /// Attack check: a creator who locked can't sell, move or claim early, can't claim more than vested, and can't redirect
    /// the claim to anyone else
    function test_creatorCantGetTokensOutEarly() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        bytes32 s = _saltAfter(alice, address(0), "Neko", "NEKO");
        vm.prank(alice);
        (address t,) = factory.launch{value: 10 ether}(_vested(_signedEth(alice, "Neko", "NEKO", s, DEV, FOBO_TICK), 12));
        PoolKey memory k = hook.keyFor(address(0), t);

        // nothing to sell or move
        _approve(alice, t);
        vm.expectRevert();
        _swap(alice, k, false, -int256(1e18), 0);
        vm.prank(alice);
        vm.expectRevert();
        FoboToken(t).transfer(makeAddr("x"), 1);
        // the vesting contract gives no allowance and has no owner path
        assertEq(FoboToken(t).allowance(address(vesting), alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        FoboToken(t).transferFrom(address(vesting), alice, 1);
        // the factory holds none and approved nothing more
        assertEq(FoboToken(t).balanceOf(address(factory)), 0);
        // nothing claimable in the launch block
        vm.expectRevert(IFoboVesting.NothingToClaim.selector);
        vesting.claim(0);

        // a month in: only a twelfth, to alice only, whoever calls
        vm.warp(block.timestamp + MONTH);
        vm.prank(makeAddr("mallory"));
        uint256 got = vesting.claim(0);
        assertEq(got, DEV / 12);
        assertEq(FoboToken(t).balanceOf(alice), DEV / 12);
        assertEq(FoboToken(t).balanceOf(makeAddr("mallory")), 0);
        vm.expectRevert(IFoboVesting.NothingToClaim.selector);
        vesting.claim(0);
        // locking more doesn't unlock anything sooner
        vm.prank(alice);
        FoboToken(t).approve(address(vesting), type(uint256).max);
        vm.prank(alice);
        vesting.lock(t, DEV / 12, 1, alice);
        assertEq(vesting.claimable(0), 0);
        assertEq(FoboToken(t).balanceOf(address(vesting)), DEV - DEV / 12 + DEV / 12);
    }
}
