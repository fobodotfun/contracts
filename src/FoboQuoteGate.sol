// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Owned} from "./base/Owned.sol";
import {IFoboFactory} from "./interfaces/IFoboFactory.sol";
import {IFoboHook} from "./interfaces/IFoboHook.sol";
import {IFoboQuoteGate} from "./interfaces/IFoboQuoteGate.sol";

/// @title FoboQuoteGate
/// @notice Owns FoboFactory, so `setQuoteAllowed(quote, true)` can only be reached through `allow`, which takes an
///         on-chain probe first: the gate pulls a known amount of the quote and must receive exactly that (a fee on
///         transfer fails), nothing may call the gate while the transfer runs (a quote with transfer hooks fails), and
///         the sample must still be the same balance PROBE_BLOCKS later (a rebasing quote fails). The PoolManager's
///         accounting can't hold any of those, so the factory's README asked the owner to check them by hand; now the
///         chain does. ETH and $FOBO are already in use and never probed. Disallowing is immediate, and every other
///         owner function of the factory passes through unchanged. Spec: packages/contracts/README.md §3.1.
/// @dev Owner = the Owner Safe (two-step, renounce disabled), so pausing launches, rotating the start signer and
///      refusing a quote stay immediate; only the burner sits behind the timelock (README §8). What a probe can't see:
///      a quote that calls the payer rather than the gate, or a rebase that nets to zero over the window. A third party
///      sending the quote to the gate during the window also fails `allow` (the balance moved): probe again, the window
///      restarts. The sample stays in the gate until swept, so the probe costs nothing but time.
contract FoboQuoteGate is IFoboQuoteGate, Owned {
    using SafeERC20 for IERC20;

    /// @notice Blocks a sample must sit before `allow` reads it again: about 24 hours. On Robinhood Chain (an
    ///         Arbitrum chain) `block.number` is Ethereum's block number, one every ~12 s (measured on a fork:
    ///         886 L1 blocks over 10,668 s), so 7,200 of them is a day; the chain's own ~0.1 s blocks are not what the
    ///         EVM counts here. The hook counts those with ArbSys because it needs block-level precision; a day's wait
    ///         does not.
    uint256 public constant PROBE_BLOCKS = 7_200;

    IFoboFactory public immutable factory;

    struct Sample {
        uint256 balance; // the gate's whole balance of the quote right after the probe
        uint256 blockNumber; // when; 0 = no sample
    }

    /// @inheritdoc IFoboQuoteGate
    mapping(address => Sample) public samples;
    /// @dev Set for the length of a probe's transferFrom: any call into the gate meanwhile is the quote calling back.
    bool internal probing;

    constructor(IFoboFactory _factory, address _owner) Owned(_owner) {
        if (address(_factory) == address(0)) revert ZeroAddress();
        factory = _factory;
    }

    /// @dev Every function of the gate: a quote's transfer code that reaches any of them is a hook on transfer.
    modifier notProbing() {
        if (probing) revert Reentered();
        _;
    }

    /// @dev The gate takes no ETH and answers no other selector; while probing, this is the quote calling back.
    fallback() external notProbing {
        revert BadCall();
    }

    // =====================================================================================================
    // quotes
    // =====================================================================================================

    /// @inheritdoc IFoboQuoteGate
    function probe(address quote, uint256 amount) external notProbing onlyOwner {
        if (quote == address(0) || quote == factory.fobo()) revert NoProbeForThis();
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(quote);
        uint256 before = token.balanceOf(address(this));
        probing = true;
        token.safeTransferFrom(msg.sender, address(this), amount);
        probing = false;
        uint256 balance = token.balanceOf(address(this));
        uint256 received = balance > before ? balance - before : 0;
        if (received != amount) revert ProbeMismatch(amount, received);
        samples[quote] = Sample({balance: balance, blockNumber: block.number});
        emit Probed(quote, amount, block.number);
    }

    /// @inheritdoc IFoboQuoteGate
    function allow(address quote) external notProbing onlyOwner {
        uint256 sample;
        // ETH and $FOBO: the pairs every pool is priced against since launch, past any probe
        if (quote != address(0) && quote != factory.fobo()) {
            Sample memory s = samples[quote];
            if (s.blockNumber == 0) revert NotProbed();
            if (block.number < s.blockNumber + PROBE_BLOCKS) revert ProbeTooFresh(s.blockNumber + PROBE_BLOCKS);
            uint256 balance = IERC20(quote).balanceOf(address(this));
            if (balance != s.balance) revert SampleDrifted(s.balance, balance);
            sample = s.balance;
            delete samples[quote]; // the probe is over: the sample may be swept
        }
        factory.setQuoteAllowed(quote, true);
        emit Allowed(quote, sample);
    }

    /// @inheritdoc IFoboQuoteGate
    function disallow(address quote) external notProbing onlyOwner {
        delete samples[quote]; // a probe in flight is void with it
        factory.setQuoteAllowed(quote, false);
    }

    /// @inheritdoc IFoboQuoteGate
    function sweepSample(address quote, address to) external notProbing onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (samples[quote].blockNumber != 0) revert SampleHeld();
        uint256 amount = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransfer(to, amount);
        emit SampleSwept(quote, to, amount);
    }

    // =====================================================================================================
    // the factory's ownership and its other owner functions
    // =====================================================================================================

    /// @inheritdoc IFoboQuoteGate
    function acceptFactory() external notProbing onlyOwner {
        Ownable2Step(address(factory)).acceptOwnership();
    }

    /// @inheritdoc IFoboQuoteGate
    function handFactoryTo(address to) external notProbing onlyOwner {
        Ownable2Step(address(factory)).transferOwnership(to);
    }

    function setHook(IFoboHook hook) external notProbing onlyOwner {
        factory.setHook(hook);
    }

    function setStartSigner(address signer) external notProbing onlyOwner {
        factory.setStartSigner(signer);
    }

    function setStartBand(int24 low, int24 high) external notProbing onlyOwner {
        factory.setStartBand(low, high);
    }

    function setQuoteBand(address quote, int24 low, int24 high) external notProbing onlyOwner {
        factory.setQuoteBand(quote, low, high);
    }

    function setDevBuyMax(uint256 tokens) external notProbing onlyOwner {
        factory.setDevBuyMax(tokens);
    }

    function setLaunchFee(uint256 fee) external notProbing onlyOwner {
        factory.setLaunchFee(fee);
    }

    function setTeam(address team) external notProbing onlyOwner {
        factory.setTeam(team);
    }

    function setLaunchesPaused(bool paused) external notProbing onlyOwner {
        factory.setLaunchesPaused(paused);
    }
}
