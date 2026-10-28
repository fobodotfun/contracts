// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IFoboHook} from "./IFoboHook.sol";

/// @notice FoboBurner: holds every "buy $FOBO and burn" amount (the launch fee, the snipe tax's burn share on pairs other
///         than $FOBO, floor money the hook sweeps) and spends it on $FOBO, which it burns, when a keeper calls
///         buybackAndBurn. Spec: packages/contracts/README.md §5.2.
interface IFoboBurner {
    /// @notice One buyback: `amountIn` of `quote` (address(0) = ETH) went along its route, `ethIn` of ETH bought
    ///         `foboBurned` $FOBO in the $FOBO pool (its price after: `sqrtPriceX96`), all of it burned.
    event BoughtAndBurned(
        address indexed keeper,
        address indexed quote,
        uint256 amountIn,
        uint256 ethIn,
        uint256 foboBurned,
        uint160 sqrtPriceX96
    );
    /// @notice The route a quote is bought back along to ETH (then always the $FOBO pool), as pool ids; empty: removed.
    ///         `usdPeg`: the quote is a USD stablecoin, so the ETH it buys is checked against the ETH/USD feed.
    event RouteSet(address indexed quote, bytes32[] poolIds, bool usdPeg);
    event KeeperSet(address indexed keeper, bool allowed);
    event HookSet(address indexed hook);
    /// @notice The owner took out everything held of `token` (address(0) = ETH): `claims` of ERC-6909 claims redeemed
    ///         and `balance` held outright, both sent to `to`.
    event EmergencyWithdrawn(address indexed token, address indexed to, uint256 claims, uint256 balance);
    /// @notice Native ETH received (the factory's launch fee, or anyone's).
    event Received(address indexed from, uint256 amount);

    error NotKeeper();
    error NotPoolManager();
    error ZeroAddress();
    error ZeroAmount();
    error HookAlreadySet();
    error BadHook();
    error HookNotSet();
    error NoFobo();
    error NoRoute();
    error BadRoute();
    error BurnBound();
    error TooLittleOut();
    error OffPeg();
    error NotEnough();

    /// @notice Spends `amountIn` of `quote` (its ERC-6909 claims first, then what is held outright) on $FOBO and burns
    ///         all of it. ETH buys $FOBO in the $FOBO pool; any other quote first goes along its route to ETH. Keepers
    ///         only. The $FOBO buy may not take the $FOBO pool's price more than BURN_MAX_TICKS (~1%) above its
    ///         start-of-block tick (BurnBound) and must buy at least `minFoboOut` (TooLittleOut); a route's legs to ETH
    ///         must give at least `minEthOut` (TooLittleOut), and a USD-pegged quote's at least its feed value less
    ///         PEG_MAX_LOSS_BPS (OffPeg). The keeper sizes its minimums from an eth_call of this same call (both
    ///         returned) less its slippage.
    /// @return ethIn the ETH that bought $FOBO (`amountIn` itself for ETH)
    /// @return foboBurned the $FOBO bought and burned
    function buybackAndBurn(address quote, uint256 amountIn, uint256 minEthOut, uint256 minFoboOut)
        external
        returns (uint256 ethIn, uint256 foboBurned);

    /// @notice The route `quote` is bought back along to ETH (any other quote: required; ETH needs none, $FOBO can't
    ///         have one). At most MAX_HOPS pools, none of them a FOBO pool (the hook's), each initialised, chained from
    ///         `quote` and ending in ETH; $FOBO's pool is always the last leg. An empty `path` removes the route.
    function setRoute(address quote, PoolKey[] calldata path, bool usdPeg) external;

    function setKeeper(address keeper, bool allowed) external;

    /// @notice The hook whose $FOBO pool the burner buys in (set once, to a hook built for this burner).
    function setHook(IFoboHook hook) external;

    /// @notice Sends everything held of `token` (address(0) = ETH), its ERC-6909 claims redeemed, to `to`. Owner only.
    function emergencyWithdraw(address token, address to) external;

    /// @notice A quote's route to ETH (empty for ETH and for a quote with none) and whether it is USD-pegged.
    function routeOf(address quote) external view returns (PoolKey[] memory path, bool usdPeg);

    function hook() external view returns (IFoboHook);
    function keepers(address keeper) external view returns (bool);
}
