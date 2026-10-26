// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice A Uniswap v4 hook base with only the callbacks FoboHook's address enables (the PoolManager calls no other:
///         Hooks.callHook only calls a callback whose flag is set), each reverting Disabled unless the hook overrides it.
///         A hook overrides the callbacks it acts in; one its address enables only to refuse it (FoboHook's
///         beforeInitialize, beforeAddLiquidity and beforeDonate) keeps the revert, so the refusal has a clear error.
///         Checks the address's permission bits on deploy.
abstract contract BaseHook {
    error NotPoolManager();
    error Disabled();

    IPoolManager public immutable poolManager;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), _permissions());
    }

    /// @dev The callbacks this hook's address enables (the PoolManager calls only these). An enabled callback that isn't
    ///      overridden reverts Disabled: that refuses the action.
    function _permissions() internal pure virtual returns (Hooks.Permissions memory);

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert Disabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert Disabled();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert Disabled();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert Disabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert Disabled();
    }
}
