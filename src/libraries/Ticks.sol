// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Tick bounds shared by the hook and the factory.
library Ticks {
    int24 internal constant SPACING = 60;
    int24 internal constant MIN_TICK = -887220; // TickMath.minUsableTick(SPACING)
    /// @dev Lowest start tick a pool may have (FoboHook.createPool, and every start band in FoboFactory): every tranche
    ///      shares the lower tick MIN_TICK, so their summed liquidity must fit v4's per-tick cap, with half of it left for
    ///      the floor band (test_minStartTickIsTheLiquidityBound pins the value to the curve). The liquidity falls as the
    ///      start tick rises, so a quote with fewer than 18 decimals (its ticks sit higher: FoboFactory.quotes) is
    ///      always inside it; only a quote worth millions per unit, or one with many more decimals, is not.
    int24 internal constant MIN_START_TICK = -54780;

    /// @dev Rounds down to a multiple of SPACING (towards negative infinity).
    function alignDown(int24 tick) internal pure returns (int24) {
        int24 r = tick % SPACING;
        return r < 0 ? tick - r - SPACING : tick - r;
    }
}
