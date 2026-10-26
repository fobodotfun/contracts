// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Tax} from "../libraries/Tax.sol";
import {HookFloor} from "./HookFloor.sol";

/// @title HookTax
/// @notice The swap callbacks: run the block's floor raise first, then tax the quote leg of every swap (no LP fee) and
///         split it: floor, creator, protocol (shared out by FoboRevenue), and in the snipe window the $FOBO burn.
///         Nobody is paid in a swap: the creator's share is owed (claimCreator), the burn share goes to FoboBurner as
///         claims (or, already $FOBO, is burned).
abstract contract HookTax is HookFloor {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        Pool storage p = pools[id];
        if (p.token == address(0)) revert UnknownPool();
        uint256 bn = _refreshRef(p, id);
        // The block's raise (or buyback) runs before its first swap, on the state the block started with, so no swap
        // can buy into a raise it triggers itself. Reserve its gas up front (so estimates include it), then run it in
        // its own frame: if it fails for any other reason it rolls back on its own and the swap still goes through.
        // Only the block's first swap looks: one that finds nothing to move, or whose raise failed, still settles the
        // block, so its later swaps don't pay for the check again (the next block's first swap looks again)
        if (p.lastRaiseBlock != bn) {
            if (_plan(p, id).go) {
                if (gasleft() < RAISE_GAS * 64 / 63 + 40_000) revert NeedGas();
                try this.raiseFromHook{gas: RAISE_GAS}(key) {}
                catch (bytes memory reason) {
                    emit RaiseFailed(id, reason);
                }
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            p.lastRaiseBlock = uint64(bn); // a block number: < 2^64
        }
        int128 specified;
        if (params.zeroForOne == (params.amountSpecified < 0)) {
            // quote is the specified currency: buy exact-in (quote in) or sell exact-out (quote out)
            (uint256 r, bool snipe) = _rate(p, id, sender);
            // |amountSpecified| (negating type(int256).min reverts)
            uint256 amt =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            // buy: r of the gross input; sell: gross up the output
            uint256 volume = params.zeroForOne ? amt : Tax.grossUp(amt, r);
            uint256 tax = params.zeroForOne ? Tax.ofGross(amt, r) : volume - amt;
            _collect(p, id, key.currency0, sender, params.zeroForOne, volume, tax, snipe, _trader(sender, hookData));
            specified = tax.toInt128();
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        Pool storage p = pools[id];
        (uint256 r, bool snipe) = _rate(p, id, sender);
        // the unspecified leg's tax, when quote is the unspecified currency (none when beforeSwap took it)
        uint256 volume;
        uint256 tax;
        if (params.zeroForOne) {
            if (params.amountSpecified < 0) {
                // buy exact-in: the whole (input - tax) must have been swapped. Compared in int256: amt is a negated
                // int256 (< 2^255), so the cast can't wrap
                uint256 amt = uint256(-params.amountSpecified);
                // forge-lint: disable-next-line(unsafe-typecast)
                if (delta.amount0() != -int256(amt - Tax.ofGross(amt, r))) revert PartialFill();
            } else {
                // buy exact-out: charge r of the gross on top of the quote the pool took
                if (delta.amount1() != params.amountSpecified) revert PartialFill();
                uint256 quoteIn = uint256(int256(-delta.amount0())); // a buy's amount0 is <= 0
                volume = Tax.grossUp(quoteIn, r);
                tax = volume - quoteIn;
            }
        } else {
            if (params.amountSpecified < 0) {
                // sell exact-in: keep r of the quote the pool released
                if (delta.amount1() != params.amountSpecified) revert PartialFill();
                volume = uint256(int256(delta.amount0())); // a sell's amount0 is >= 0
                tax = Tax.ofGross(volume, r);
            } else {
                // sell exact-out: the pool must have released the grossed-up amount
                if (delta.amount0() != Tax.grossUp(uint256(params.amountSpecified), r).toInt256()) {
                    revert PartialFill();
                }
            }
        }
        _collect(p, id, key.currency0, sender, params.zeroForOne, volume, tax, snipe, _trader(sender, hookData));
        return (IHooks.afterSwap.selector, tax.toInt128());
    }

    /// @dev Tax rate in pips and whether it's the snipe window. The factory pays the base rate on the pool it is launching
    ///      in this transaction (the creator's buy, before anyone else can trade it), and the normal rate everywhere else,
    ///      so a launch is no way into another pool's snipe window.
    function _rate(Pool storage p, PoolId id, address sender) internal view returns (uint256, bool) {
        if (sender == factory) {
            bytes32 slot = LAUNCHING_SLOT;
            bytes32 launching;
            assembly ("memory-safe") {
                launching := tload(slot)
            }
            if (launching == PoolId.unwrap(id)) return (BASE_TAX, false);
        }
        return Tax.rate(block.timestamp - p.launchedAt);
    }

    /// @dev Takes `tax` of quote as ERC-6909 claims (offsetting the hook delta the PoolManager books after afterSwap)
    ///      and splits it. Snipe window: 60% floor, vesting over SNIPE_VEST (snipePot), 40% to the $FOBO burn
    ///      (_burnShare: FoboBurner's claims, or burned at once on a $FOBO pair), nothing to the creator; in $FOBO's own
    ///      pool the 40% is its creator fee instead. After: 60% floor / 24% creator / 16% team (of a 2.5% tax: 1.5% /
    ///      0.6% / 0.4% of the trade), the floor share straight into pot. The protocol fee (the team's share after the
    ///      window) and $FOBO's creator fee are shared out by FoboRevenue in this swap (_credit), on `trader`'s referral
    ///      (_trader; of the protocol fee only). Every other creator fee is owed (creatorOwed), never paid in the swap:
    ///      claimCreator pays it (the keeper's payouts).
    function _collect(
        Pool storage p,
        PoolId id,
        Currency quote,
        address swapper,
        bool buy,
        uint256 volume,
        uint256 tax,
        bool snipe,
        address trader
    ) internal {
        if (tax == 0) return;
        poolManager.mint(address(this), quote.toId(), tax);
        uint256 toCreator;
        uint256 toTeam;
        uint256 toBurn;
        uint256 fee; // the protocol fee (none in the snipe window)
        if (snipe) {
            uint256 share = Tax.snipeBurn(tax);
            // $FOBO's own pool can't buy itself back: the share is its creator fee
            if (p.creator == address(0)) {
                toCreator = share;
            } else {
                _burnShare(p, id, quote, share);
                toBurn = share;
            }
            p.snipePot += (tax - share).toUint128();
        } else {
            toCreator = Tax.creatorShare(tax);
            toTeam = fee = Tax.protocolShare(tax);
            p.pot += tax - toCreator - toTeam;
        }
        // $FOBO's creator fee is FOBO's revenue: FoboRevenue shares it out with the protocol fee, in this swap
        p.creatorOwed += toCreator - _credit(id, quote, trader, fee, p.creator == address(0) ? toCreator : 0);
        emit TaxPaid(id, swapper, buy, volume, tax - toCreator - toTeam - toBurn, toCreator, toTeam, toBurn);
    }

    /// @dev Shares out the protocol fee and `creatorFee` (already held as claims) through FoboRevenue: it takes exactly
    ///      those claims from the hook itself (its ERC-6909 operator, HookStorage's constructor), so a credit that
    ///      reverts never moved them, and books the partners', `trader`'s referrer's (_trader) and the team's shares
    ///      (it pays no one). Runs in its own frame with CREDIT_GAS, reserved up front like the raise's; if it
    ///      reverts anyway the swap still goes through and the protocol fee stays the team's here (teamOwed: no referral
    ///      or partner share of it, accepted, README §5.1). Returns the creator fee FoboRevenue took (`creatorFee`, or 0
    ///      if it failed: the caller keeps it in the creator balance, which claimCreator credits to FoboRevenue later).
    function _credit(PoolId id, Currency quote, address trader, uint256 protocolFee, uint256 creatorFee)
        internal
        returns (uint256)
    {
        uint256 amount = protocolFee + creatorFee;
        if (amount == 0) return 0;
        if (gasleft() < CREDIT_GAS * 64 / 63 + 20_000) revert NeedGas();
        try revenue.credit{gas: CREDIT_GAS}(Currency.unwrap(quote), trader, protocolFee, creatorFee) {
            return creatorFee;
        } catch {
            emit CreditFailed(id, amount);
            teamOwed[quote] += protocolFee;
            return 0;
        }
    }

    /// @dev The trader a swap's referral is credited to. A FoboLimitOrders fill: the order's owner, which it passes as
    ///      hookData (`sender` is the PoolManager's caller, so no one else's hookData is ever read). Anything else: the
    ///      swap's tx.origin (the hook can't see the wallet behind a router): smart-wallet or bundled swaps credit the
    ///      bundler's EOA, which normally has no referrer. Only ever used to pick a referrer, never for authorization.
    function _trader(address sender, bytes calldata hookData) internal view returns (address) {
        if (sender == limitOrders) return abi.decode(hookData, (address));
        return tx.origin;
    }
}
