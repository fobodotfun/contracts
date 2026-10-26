// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IFoboFactory} from "../interfaces/IFoboFactory.sol";
import {HookTax} from "./HookTax.sol";

/// @title HookClaims
/// @notice Paying out: creator and team balances, and handing a pool's creator fees on.
abstract contract HookClaims is HookTax {
    using PoolIdLibrary for PoolKey;

    /// @notice Pays a pool's creator balance to `to`: every creator fee is owed, never paid in a swap. Anyone can send it
    ///         to the creator (the keeper's payouts); only the creator can name another `to`.
    function claimCreator(PoolKey calldata key, address to) external {
        PoolId id = key.toId();
        Pool storage p = pools[id];
        uint256 amount = p.creatorOwed;
        if (amount == 0) return;
        address creator = p.creator;
        if (creator != address(0)) {
            if (to == address(0)) revert ZeroAddress();
            if (to != creator && msg.sender != creator) revert NotCreator();
        }
        p.creatorOwed = 0;
        if (creator == address(0)) {
            // $FOBO's creator fee is FOBO's revenue, credited in every swap: this is only what a swap couldn't credit
            // (CreditFailed). FoboRevenue shares it out with the partners at this claim (no trader, so no referral)
            revenue.credit(Currency.unwrap(key.currency0), address(0), 0, amount);
            return;
        }
        _pay(key.currency0, to, amount);
    }

    /// @notice Pays the team what the hook keeps for it ($FOBO's own pool's swept floor money, a protocol fee whose
    ///         credit failed): the protocol fee normally goes through FoboRevenue in the swap.
    function claimTeam(Currency currency) external {
        uint256 amount = teamOwed[currency];
        if (amount == 0) return;
        teamOwed[currency] = 0;
        _pay(currency, IFoboFactory(factory).team(), amount);
    }

    function setCreator(PoolKey calldata key, address creator) external {
        PoolId id = key.toId();
        Pool storage p = pools[id];
        if (p.creator == address(0) || msg.sender != p.creator || creator == address(0)) revert NotCreator();
        p.creator = creator;
        emit CreatorChanged(id, creator);
    }

    function _pay(Currency currency, address to, uint256 amount) internal {
        poolManager.unlock(abi.encode(ACTION_CLAIM, abi.encode(currency, to, amount)));
        emit Claimed(to, Currency.unwrap(currency), amount);
    }
}
