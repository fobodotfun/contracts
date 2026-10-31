// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FoboQuoteGate} from "../src/FoboQuoteGate.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {Owned} from "../src/base/Owned.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {IFoboQuoteGate} from "../src/interfaces/IFoboQuoteGate.sol";
import {StartTick} from "../script/StartTick.sol";
import {MockQuote, QuoteBase} from "./QuoteDecimals.t.sol";

/// A quote with a hook on transfer: every transfer calls `target` with `data` and bubbles up whatever it reverts with
/// (an ERC-777-style token calling the recipient).
contract CallbackQuote is ERC20 {
    address public target;
    bytes public data;

    constructor() ERC20("Hooked USD", "HUSD") {
        _mint(msg.sender, 1e30);
    }

    function setCallback(address _target, bytes calldata _data) external {
        target = _target;
        data = _data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target == address(0)) return;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// A rebasing quote: every balance is the shares held times `factor` (1e18 = none), which anyone may move.
contract RebasingQuote is ERC20 {
    uint256 public factor = 1e18;

    constructor() ERC20("Rebasing USD", "RUSD") {
        _mint(msg.sender, 1e30);
    }

    function rebase(uint256 _factor) external {
        factor = _factor;
    }

    function balanceOf(address who) public view override returns (uint256) {
        return super.balanceOf(who) * factor / 1e18;
    }
}

/// FoboQuoteGate owns the factory: a plain ERC-20 is allowed only after a probe and the wait, a fee-on-transfer, a
/// transfer-hook or a rebasing quote never is, disallowing is immediate, the factory's other owner functions pass
/// through, the factory can be handed on, and nobody but the gate's owner reaches any of it.
contract QuoteGateTest is QuoteBase {
    FoboQuoteGate gate;
    address stranger = makeAddr("stranger");
    address out = makeAddr("out");

    function setUp() public override {
        super.setUp();
        _launchFobo(); // $FOBO's launch is the factory owner's: before the gate takes the factory
        gate = new FoboQuoteGate(IFoboFactory(address(factory)), address(this));
        factory.transferOwnership(address(gate));
        gate.acceptFactory();
        assertEq(factory.owner(), address(gate));
    }

    /// `q`'s band around the $10k start of a $1 quote with `decimals`, set through the gate
    function _band(address q, uint8 decimals) internal {
        int24 mid = StartTick.forQuote(USD_E8, decimals);
        gate.setQuoteBand(q, mid - BAND_HALF, mid + BAND_HALF);
    }

    /// The owner (this test) approves and probes `amount` of `q`
    function _probe(address q, uint256 amount) internal {
        ERC20(q).approve(address(gate), amount);
        gate.probe(q, amount);
    }

    function _allowed(address q) internal view returns (bool allowed) {
        (allowed,,,) = factory.quotes(q);
    }

    function _wait() internal {
        vm.roll(vm.getBlockNumber() + gate.PROBE_BLOCKS());
    }

    // ---------------------------------------------------------------- the happy path

    /// A plain ERC-20: the probe records the sample, allow refuses until PROBE_BLOCKS have passed and the sample can't
    /// be swept meanwhile; then the factory has the quote allowed with its decimals and a launch on it works, and the
    /// sample goes back.
    function test_plainQuotePassesProbeAndAllow() public {
        MockQuote q = new MockQuote(6, 0);
        _band(address(q), 6);
        uint256 b0 = vm.getBlockNumber();
        q.approve(address(gate), 1_000e6);
        vm.expectEmit(true, false, false, true, address(gate));
        emit IFoboQuoteGate.Probed(address(q), 1_000e6, b0);
        gate.probe(address(q), 1_000e6);
        (uint256 bal, uint256 at) = gate.samples(address(q));
        assertEq(bal, 1_000e6);
        assertEq(at, b0);
        assertEq(q.balanceOf(address(gate)), 1_000e6, "the sample stays in the gate");

        vm.expectRevert(abi.encodeWithSelector(IFoboQuoteGate.ProbeTooFresh.selector, b0 + gate.PROBE_BLOCKS()));
        gate.allow(address(q));
        vm.roll(b0 + gate.PROBE_BLOCKS() - 1);
        vm.expectRevert(abi.encodeWithSelector(IFoboQuoteGate.ProbeTooFresh.selector, b0 + gate.PROBE_BLOCKS()));
        gate.allow(address(q));
        vm.expectRevert(IFoboQuoteGate.SampleHeld.selector);
        gate.sweepSample(address(q), out);
        assertFalse(_allowed(address(q)));

        vm.roll(b0 + gate.PROBE_BLOCKS());
        vm.expectEmit(true, false, false, true, address(factory));
        emit IFoboFactory.QuoteAllowed(address(q), true);
        vm.expectEmit(true, false, false, true, address(gate));
        emit IFoboQuoteGate.Allowed(address(q), 1_000e6);
        gate.allow(address(q));
        (bool allowed,,, uint8 d) = factory.quotes(address(q));
        assertTrue(allowed);
        assertEq(d, 6, "the factory read its decimals");
        (bal, at) = gate.samples(address(q));
        assertEq(bal + at, 0, "the sample is spent");

        // the pair is live
        address alice = _user("alice");
        _fund(q, alice, 1_000);
        (, PoolKey memory k) = _launchOn(q, alice, "Neko", "NEKO", 1_000_000e18, StartTick.forQuote(USD_E8, 6));
        assertEq(_creatorOf(k), alice);

        vm.expectEmit(true, true, false, true, address(gate));
        emit IFoboQuoteGate.SampleSwept(address(q), out, 1_000e6);
        gate.sweepSample(address(q), out);
        assertEq(q.balanceOf(out), 1_000e6);
        assertEq(q.balanceOf(address(gate)), 0);
    }

    /// ETH and $FOBO are allowed without a probe (and can't be probed: nothing to learn); anything else needs one.
    function test_ethAndFoboNeedNoProbe() public {
        gate.disallow(address(0));
        gate.disallow(fobo);
        assertFalse(_allowed(address(0)));
        assertFalse(_allowed(fobo));
        gate.allow(address(0));
        gate.allow(fobo);
        assertTrue(_allowed(address(0)));
        assertTrue(_allowed(fobo));
        vm.expectRevert(IFoboQuoteGate.NoProbeForThis.selector);
        gate.probe(address(0), 1);
        vm.expectRevert(IFoboQuoteGate.NoProbeForThis.selector);
        gate.probe(fobo, 1);

        MockQuote q = new MockQuote(6, 0);
        _band(address(q), 6);
        vm.expectRevert(IFoboQuoteGate.NotProbed.selector);
        gate.allow(address(q));
        vm.expectRevert(IFoboQuoteGate.ZeroAmount.selector);
        gate.probe(address(q), 0);
    }

    // ---------------------------------------------------------------- what the probe refuses

    /// A fee on transfer: less arrives than was sent, the probe reverts with both numbers and nothing is recorded.
    function test_feeOnTransferFailsProbe() public {
        MockQuote q = new MockQuote(6, 100); // 1%
        _band(address(q), 6);
        q.approve(address(gate), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IFoboQuoteGate.ProbeMismatch.selector, 1_000e6, 990e6));
        gate.probe(address(q), 1_000e6);
        (uint256 bal, uint256 at) = gate.samples(address(q));
        assertEq(bal + at, 0);
        _wait();
        vm.expectRevert(IFoboQuoteGate.NotProbed.selector);
        gate.allow(address(q));
        assertFalse(_allowed(address(q)));
    }

    /// A transfer hook that calls the gate, whether one of its functions or an unknown selector, reverts the probe.
    function test_callbackFailsProbe() public {
        CallbackQuote q = new CallbackQuote();
        _band(address(q), 18);
        q.approve(address(gate), 1e18);
        q.setCallback(address(gate), abi.encodeCall(IFoboQuoteGate.allow, (address(q))));
        vm.expectRevert(IFoboQuoteGate.Reentered.selector);
        gate.probe(address(q), 1e18);
        q.setCallback(address(gate), abi.encodeCall(IFoboQuoteGate.probe, (address(q), 1)));
        vm.expectRevert(IFoboQuoteGate.Reentered.selector);
        gate.probe(address(q), 1e18);
        q.setCallback(address(gate), hex"deadbeef");
        vm.expectRevert(IFoboQuoteGate.Reentered.selector);
        gate.probe(address(q), 1e18);
        (uint256 bal, uint256 at) = gate.samples(address(q));
        assertEq(bal + at, 0);

        // the same token without its hook passes: it was the callback that failed it
        q.setCallback(address(0), "");
        gate.probe(address(q), 1e18);
        _wait();
        gate.allow(address(q));
        assertTrue(_allowed(address(q)));
    }

    /// A balance that moves between the probe and the allow, with no transfer by the gate, fails the allow: up or down.
    /// Only a sample that reads exactly as recorded passes.
    function test_rebasingFailsAllow() public {
        RebasingQuote q = new RebasingQuote();
        _band(address(q), 18);
        _probe(address(q), 1e18);
        _wait();
        q.rebase(1.01e18);
        vm.expectRevert(abi.encodeWithSelector(IFoboQuoteGate.SampleDrifted.selector, 1e18, 1.01e18));
        gate.allow(address(q));
        q.rebase(0.5e18);
        vm.expectRevert(abi.encodeWithSelector(IFoboQuoteGate.SampleDrifted.selector, 1e18, 0.5e18));
        gate.allow(address(q));
        assertFalse(_allowed(address(q)));
        // a plain ERC-20's balance also moves if someone sends it some: the probe is redone, the window restarts
        MockQuote p = new MockQuote(6, 0);
        _band(address(p), 6);
        _probe(address(p), 1_000e6);
        _wait();
        p.transfer(address(gate), 1);
        vm.expectRevert(abi.encodeWithSelector(IFoboQuoteGate.SampleDrifted.selector, 1_000e6, 1_000e6 + 1));
        gate.allow(address(p));
        _probe(address(p), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(IFoboQuoteGate.ProbeTooFresh.selector, vm.getBlockNumber() + gate.PROBE_BLOCKS())
        );
        gate.allow(address(p));
        _wait();
        gate.allow(address(p));
        assertTrue(_allowed(address(p)));
    }

    // ---------------------------------------------------------------- disallow and the sample

    /// Disallowing takes effect at once, voids a probe in flight and frees the sample.
    function test_disallowIsImmediate() public {
        MockQuote q = new MockQuote(6, 0);
        _band(address(q), 6);
        _probe(address(q), 1_000e6);
        _wait();
        gate.allow(address(q));
        assertTrue(_allowed(address(q)));
        vm.expectEmit(true, false, false, true, address(factory));
        emit IFoboFactory.QuoteAllowed(address(q), false);
        gate.disallow(address(q));
        assertFalse(_allowed(address(q)));

        _probe(address(q), 1e6); // a new probe, on top of the old sample
        (uint256 bal,) = gate.samples(address(q));
        assertEq(bal, 1_001e6, "the sample is the gate's whole balance");
        gate.disallow(address(q));
        (bal,) = gate.samples(address(q));
        assertEq(bal, 0, "voided");
        _wait();
        vm.expectRevert(IFoboQuoteGate.NotProbed.selector);
        gate.allow(address(q));
        gate.sweepSample(address(q), out);
        assertEq(q.balanceOf(out), 1_001e6);
        vm.expectRevert(IFoboQuoteGate.ZeroAddress.selector);
        gate.sweepSample(address(q), address(0));
    }

    // ---------------------------------------------------------------- the factory's other owner functions

    /// Every pass-through reaches the factory, and the factory answers to nobody else.
    function test_passThroughsReachTheFactory() public {
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        factory.setQuoteAllowed(address(0), false);

        address signer = makeAddr("signer");
        gate.setStartSigner(signer);
        assertEq(factory.startSigner(), signer);
        gate.setStartBand(FOBO_TICK - 600, FOBO_TICK + 600);
        assertEq(factory.startBandLow(), FOBO_TICK - 600);
        assertEq(factory.startBandHigh(), FOBO_TICK + 600);
        MockQuote q = new MockQuote(6, 0);
        gate.setQuoteBand(address(q), 391_500 - 60, 391_500 + 60);
        (, int24 lo, int24 hi,) = factory.quotes(address(q));
        assertEq(lo, 391_500 - 60);
        assertEq(hi, 391_500 + 60);
        gate.setDevBuyMax(1e18);
        assertEq(factory.devBuyMax(), 1e18);
        gate.setLaunchFee(1 ether);
        assertEq(factory.launchFeeEth(), 1 ether);
        address t = makeAddr("team2");
        gate.setTeam(t);
        assertEq(factory.team(), t);
        gate.setLaunchesPaused(true);
        assertTrue(factory.launchesPaused());
        // the hook is set once; the factory's own refusal comes back through the gate
        vm.expectRevert(IFoboFactory.HookSet.selector);
        gate.setHook(IFoboHook(address(hook)));
        vm.expectRevert(IFoboFactory.BadTick.selector);
        gate.setStartBand(100, 10);
    }

    /// The way out: the gate offers the factory, the new owner accepts (two-step), and the gate is out of the loop.
    function test_handFactoryToStartsTheTwoStepTransfer() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, false, false, address(factory));
        emit Ownable2Step.OwnershipTransferStarted(address(gate), next);
        gate.handFactoryTo(next);
        assertEq(factory.owner(), address(gate), "still the gate's until accepted");
        assertEq(factory.pendingOwner(), next);
        vm.prank(next);
        factory.acceptOwnership();
        assertEq(factory.owner(), next);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        gate.setLaunchesPaused(true);
    }

    // ---------------------------------------------------------------- access

    /// Nobody but the owner reaches anything; the gate itself is two-step owned, can't renounce, takes no ETH.
    function test_nonOwnerCallsRevert() public {
        MockQuote q = new MockQuote(6, 0);
        bytes[] memory calls = new bytes[](14);
        calls[0] = abi.encodeCall(IFoboQuoteGate.probe, (address(q), 1));
        calls[1] = abi.encodeCall(IFoboQuoteGate.allow, (address(q)));
        calls[2] = abi.encodeCall(IFoboQuoteGate.disallow, (address(q)));
        calls[3] = abi.encodeCall(IFoboQuoteGate.sweepSample, (address(q), stranger));
        calls[4] = abi.encodeCall(IFoboQuoteGate.acceptFactory, ());
        calls[5] = abi.encodeCall(IFoboQuoteGate.handFactoryTo, (stranger));
        calls[6] = abi.encodeCall(IFoboQuoteGate.setHook, (IFoboHook(address(hook))));
        calls[7] = abi.encodeCall(IFoboQuoteGate.setStartSigner, (stranger));
        calls[8] = abi.encodeCall(IFoboQuoteGate.setStartBand, (0, 60));
        calls[9] = abi.encodeCall(IFoboQuoteGate.setQuoteBand, (address(q), 0, 60));
        calls[10] = abi.encodeCall(IFoboQuoteGate.setDevBuyMax, (0));
        calls[11] = abi.encodeCall(IFoboQuoteGate.setLaunchFee, (0));
        calls[12] = abi.encodeCall(IFoboQuoteGate.setTeam, (stranger));
        calls[13] = abi.encodeCall(IFoboQuoteGate.setLaunchesPaused, (true));
        for (uint256 i; i < calls.length; i++) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(gate).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), Ownable.OwnableUnauthorizedAccount.selector);
        }

        (bool sent,) = address(gate).call{value: 1}("");
        assertFalse(sent, "no ETH");
        vm.expectRevert(IFoboQuoteGate.BadCall.selector);
        (sent,) = address(gate).call(hex"deadbeef");

        vm.expectRevert(Owned.RenounceDisabled.selector);
        gate.renounceOwnership();
        address timelock = makeAddr("timelock");
        gate.transferOwnership(timelock);
        assertEq(gate.owner(), address(this));
        vm.prank(timelock);
        gate.acceptOwnership();
        assertEq(gate.owner(), timelock);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        gate.disallow(address(0));

        vm.expectRevert(IFoboQuoteGate.ZeroAddress.selector);
        new FoboQuoteGate(IFoboFactory(address(0)), address(this));
    }
}
