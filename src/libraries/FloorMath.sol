// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// @notice Amount <-> liquidity helpers for single-sided ranges. Pool orientation (see FoboHook): currency0 = quote,
///         currency1 = launched token, so "quote" amounts are amount0 and "token" amounts are amount1.
library FloorMath {
    /// @dev Liquidity that `amount0` of quote buys over [sqrtA, sqrtB] (all of it above the price). Rounds down.
    function liquidityForQuote(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        uint256 inter = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        uint256 l = FullMath.mulDiv(amount0, inter, sqrtB - sqrtA);
        // forge-lint: disable-next-line(unsafe-typecast)
        return l > type(uint128).max ? type(uint128).max : uint128(l); // clamped
    }

    /// @dev Liquidity that `amount1` of token buys over [sqrtA, sqrtB] (all of it below the price). Rounds down.
    function liquidityForToken(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        uint256 l = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA);
        // forge-lint: disable-next-line(unsafe-typecast)
        return l > type(uint128).max ? type(uint128).max : uint128(l); // clamped
    }

    /// @dev Quote held by liquidity `l` over [sqrtA, sqrtB].
    function quote(uint160 sqrtA, uint160 sqrtB, uint128 l, bool roundUp) internal pure returns (uint256) {
        if (sqrtA >= sqrtB || l == 0) return 0;
        return SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, l, roundUp);
    }

    /// @dev Token held by liquidity `l` over [sqrtA, sqrtB].
    function token(uint160 sqrtA, uint160 sqrtB, uint128 l, bool roundUp) internal pure returns (uint256) {
        if (sqrtA >= sqrtB || l == 0) return 0;
        return SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, l, roundUp);
    }
}
