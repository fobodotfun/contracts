// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFoboFactory} from "./IFoboFactory.sol";
import {IFoboHook} from "./IFoboHook.sol";

/// @notice FoboQuoteGate: owns FoboFactory, so a quote can only be allowed after an on-chain probe. Spec:
///         packages/contracts/README.md §3.1.
interface IFoboQuoteGate {
    /// @notice `amount` of `quote` arrived in full and sits in the gate as its sample from block `blockNumber`.
    event Probed(address indexed quote, uint256 amount, uint256 blockNumber);
    /// @notice `quote` was allowed on the factory: ETH or $FOBO unprobed, any other quote with its sample (`sample`
    ///         raw units) unchanged for PROBE_BLOCKS.
    event Allowed(address indexed quote, uint256 sample);
    /// @notice A finished sample (allowed or disallowed) of `quote`, `amount` raw units, left the gate for `to`.
    event SampleSwept(address indexed quote, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    /// @notice The gate takes no ETH and has no other function.
    error BadCall();
    /// @notice ETH and $FOBO are never probed (already in use); nothing else is allowed without one.
    error NoProbeForThis();
    /// @notice A call reached the gate while a probe's transferFrom was running: the quote calls back on transfer.
    error Reentered();
    /// @notice The gate's balance rose by `received`, not the `expected` sent: a fee on transfer.
    error ProbeMismatch(uint256 expected, uint256 received);
    error NotProbed();
    /// @notice The sample has not sat for PROBE_BLOCKS yet: allow from block `readyAt`.
    error ProbeTooFresh(uint256 readyAt);
    /// @notice The sample's balance moved from `recorded` to `current` with no transfer by the gate: a rebasing quote.
    error SampleDrifted(uint256 recorded, uint256 current);
    /// @notice The sample is still under probe: allow or disallow the quote first.
    error SampleHeld();

    /// @notice Pulls `amount` of `quote` from the owner (approve the gate first) and keeps it as the sample `allow`
    ///         checks later. Reverts unless the gate's balance rises by exactly `amount`, or if anything calls the
    ///         gate during the transfer.
    function probe(address quote, uint256 amount) external;

    /// @notice Allows `quote` on the factory. ETH and $FOBO: straight through. Anything else: only with a sample at
    ///         least PROBE_BLOCKS old whose balance has not moved.
    function allow(address quote) external;

    /// @notice Disallows `quote` on the factory, at once (new launches only: the factory never touches live pools).
    function disallow(address quote) external;

    /// @notice Sends the gate's whole balance of `quote` to `to`, once the quote's probe is over (allowed or
    ///         disallowed); also whatever was sent to the gate without a probe.
    function sweepSample(address quote, address to) external;

    /// @notice Accepts the factory's ownership (two-step: after factory.transferOwnership(gate)).
    function acceptFactory() external;
    /// @notice Offers the factory to `to` (two-step: `to` accepts). The way out of the gate.
    function handFactoryTo(address to) external;

    // the factory's other owner functions, passed through unchanged
    function setHook(IFoboHook hook) external;
    function setStartSigner(address signer) external;
    function setStartBand(int24 low, int24 high) external;
    function setQuoteBand(address quote, int24 low, int24 high) external;
    function setDevBuyMax(uint256 tokens) external;
    function setLaunchFee(uint256 fee) external;
    function setTeam(address team) external;
    function setLaunchesPaused(bool paused) external;

    function factory() external view returns (IFoboFactory);
    /// @notice A quote's sample under probe: its balance and the block it was taken (0, 0 = none).
    function samples(address quote) external view returns (uint256 balance, uint256 blockNumber);
}
