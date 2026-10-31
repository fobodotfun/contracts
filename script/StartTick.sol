// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// The tick a pool starts at for a $10k market cap, from its quote's USD price and decimals: $FOBO's own start tick
/// (LaunchFobo.s.sol), the middle of the factory's ETH start band (Deploy.s.sol) and of any other quote's band
/// (QuoteBand.s.sol). All in the pool's unit: raw token units per raw quote unit (packages/core/src/fees.ts
/// startTickFor is the same maths for the site).
library StartTick {
    /// Most ETH_USD (an env value) may be off the ETH/USD feed's answer, in percent: it sets the launch fee, the start
    /// band (Deploy.s.sol) and $FOBO's own start tick (LaunchFobo.s.sol), so a mistyped price fails the script instead.
    uint256 internal constant ETH_USD_MAX_DEVIATION_PCT = 5;

    /// Whether `given` is within ETH_USD_MAX_DEVIATION_PCT of `live` either way (both in the same unit).
    function nearFeed(uint256 given, uint256 live) internal pure returns (bool) {
        return given * 100 >= live * (100 - ETH_USD_MAX_DEVIATION_PCT)
            && given * 100 <= live * (100 + ETH_USD_MAX_DEVIATION_PCT);
    }

    uint256 internal constant SUPPLY = 1e9; // whole tokens minted
    uint256 internal constant MCAP_USD = 1e4; // every pool starts at a $10k market cap
    uint256 internal constant TOKEN_DECIMALS = 18;

    /// @param ethUsd ETH price in whole dollars
    /// @return t tokens per ETH = 1e9 * ethUsd / 1e4 as a tick, rounded up the 60-tick grid (mcap <= $10k)
    function forEthUsd(uint256 ethUsd) internal pure returns (int24 t) {
        return forQuote(ethUsd * 1e8, 18);
    }

    /// @param quoteUsdE8 USD per whole quote unit, 8 decimals (1e8 = $1, like Chainlink's USD feeds)
    /// @param quoteDecimals the quote's ERC-20 decimals
    /// @return t raw tokens per raw quote unit = 1e9 * 1e18 * quoteUsdE8 / (1e4 * 1e8 * 10^quoteDecimals) as a tick,
    ///         rounded up the 60-tick grid (mcap <= $10k)
    function forQuote(uint256 quoteUsdE8, uint8 quoteDecimals) internal pure returns (int24 t) {
        require(quoteUsdE8 != 0, "quote price");
        // 64 fractional bits of sqrt precision: sqrt(ratio x 2^128) = sqrt(ratio) x 2^64, then x 2^32 for Q96
        uint256 ratioX128 = FullMath.mulDiv(
            SUPPLY * 10 ** TOKEN_DECIMALS * quoteUsdE8, 1 << 128, MCAP_USD * 1e8 * 10 ** uint256(quoteDecimals)
        );
        uint160 sqrtX96 = uint160(sqrt(ratioX128) << 32);
        t = TickMath.getTickAtSqrtPrice(sqrtX96);
        int24 r = t % 60;
        if (r != 0) t = t - r + (t > 0 ? int24(60) : int24(0));
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) (z, y) = (y, (x / y + y) >> 1);
    }
}
