// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The block number the hook's once-per-block rules key on (README §6). On an Arbitrum chain (Robinhood Chain is
///         an Arbitrum Orbit chain) the EVM's `block.number` is the parent chain's block number (Ethereum's, ~12 s); the
///         chain's own block number comes from the ArbSys precompile. Which one a hook reads is fixed when it is
///         deployed (FoboHook.isArbitrum).
library Blocks {
    /// @dev This block's number: ArbSys.arbBlockNumber() when `isArbitrum`, else block.number. ArbSys is Arbitrum's
    ///      system precompile at 0x64 (code 0xfe on chain: it answers calls, never runs EVM code); 0xa3b1b31d is
    ///      arbBlockNumber()'s selector.
    ///      Reverts when ArbSys doesn't answer with a word (a hook made for an Arbitrum chain running anywhere else):
    ///      never falls back to block.number.
    function current(bool isArbitrum) internal view returns (uint256 n) {
        if (!isArbitrum) return block.number;
        assembly ("memory-safe") {
            mstore(0, 0xa3b1b31d)
            let ok := staticcall(gas(), 0x64, 28, 4, 0, 32)
            if or(iszero(ok), lt(returndatasize(), 32)) { revert(0, 0) }
            n := mload(0)
        }
    }
}
