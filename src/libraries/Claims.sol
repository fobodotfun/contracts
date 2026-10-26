// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice The contracts hold their balances as PoolManager ERC-6909 claims; this pays them out. Only ever outside a
///         swap (a claim's own unlock): nobody is paid in a swap, every share is owed and claimed later.
library Claims {
    /// @dev Burns `amount` of the caller's claims on `currency` and sends the currency to `to`. Inside an unlock only.
    function redeem(IPoolManager poolManager, Currency currency, address to, uint256 amount) internal {
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }
}
