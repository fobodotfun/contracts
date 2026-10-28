// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Owned} from "./base/Owned.sol";
import {IFoboBurner} from "./interfaces/IFoboBurner.sol";
import {IFoboHook} from "./interfaces/IFoboHook.sol";
import {IFoboLimitOrders} from "./interfaces/IFoboLimitOrders.sol";
import {IFoboToken} from "./interfaces/IFoboToken.sol";

/// @title FoboBurner
/// @notice Every "buy $FOBO and burn" amount ends up here: the factory's launch fee (native ETH, sent in the launch), the
///         snipe tax's 40% burn share on pairs other than $FOBO and the floor money the hook sweeps (an empty pool's, or
///         beyond what its holders can carry), both handed over by the hook as PoolManager ERC-6909 claims (a claims
///         transfer: nothing leaves the PoolManager and no code here runs inside a swap). A keeper spends it whenever it
///         likes with buybackAndBurn: ETH buys $FOBO in the $FOBO pool; any other quote first goes along the route the
///         owner set for it to ETH. Every $FOBO bought is burned in the same call. The $FOBO buy can never take the $FOBO
///         pool's price more than BURN_MAX_TICKS (~1%) above where its block started, so a sandwich around it gains at
///         most that and pays the pool's 2.5% tax both ways; the keeper's minimums bound the rest. Nothing a keeper does
///         can send anything anywhere but into $FOBO that is burned. Spec: packages/contracts/README.md §5.2.
/// @dev Owner = the Owner Safe (two-step, renounce disabled). The $FOBO buy is a normal swap through the hook: it pays
///      the pool's tax like any trader's (as the factory's launch-fee swap always did).
contract FoboBurner is IFoboBurner, IUnlockCallback, Owned {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /// @notice A buyback never takes the $FOBO pool's price more than this many ticks (~1%) above where the block started
    ///         (the hook's startOfBlockTick): less than the 5% a sandwich pays in tax both ways.
    int24 public constant BURN_MAX_TICKS = 100;
    /// @notice Most pools a route to ETH may have.
    uint256 public constant MAX_HOPS = 3;
    /// @notice A USD-pegged quote's route must give at least its value at $1 a unit, at the ETH/USD feed's price, less
    ///         this (3%: the feed's 0.5% deviation, the pool's fee and its price impact, with room to spare).
    uint256 public constant PEG_MAX_LOSS_BPS = 300;
    uint256 internal constant BPS = 10_000;

    uint8 internal constant ACTION_BUY = 1;
    uint8 internal constant ACTION_WITHDRAW = 2;

    IPoolManager public immutable poolManager;
    /// @notice The hook whose $FOBO pool the burner buys in (set once).
    IFoboHook public hook;
    mapping(address => bool) public keepers;

    struct Route {
        bool usdPeg;
        uint8 decimals; // the quote's (usdPeg only)
        PoolKey[] path;
    }

    mapping(address => Route) internal _routes;

    struct Buy {
        Currency quote;
        uint256 amountIn;
        uint256 minEthOut;
        uint256 minFoboOut;
    }

    constructor(IPoolManager _poolManager, address _owner) Owned(_owner) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
    }

    /// @notice The launch fee arrives as native ETH (and anyone may send more to burn).
    receive() external payable {
        // the PoolManager only ever pays ETH here on an emergencyWithdraw to this contract itself: not a deposit
        if (msg.sender != address(poolManager)) emit Received(msg.sender, msg.value);
    }

    // =====================================================================================================
    // keeper
    // =====================================================================================================

    /// @inheritdoc IFoboBurner
    function buybackAndBurn(address quote, uint256 amountIn, uint256 minEthOut, uint256 minFoboOut)
        external
        returns (uint256 ethIn, uint256 foboBurned)
    {
        if (!keepers[msg.sender]) revert NotKeeper();
        if (amountIn == 0) revert ZeroAmount();
        uint160 sqrtPriceX96;
        Buy memory b =
            Buy({quote: Currency.wrap(quote), amountIn: amountIn, minEthOut: minEthOut, minFoboOut: minFoboOut});
        (ethIn, foboBurned, sqrtPriceX96) =
            abi.decode(poolManager.unlock(abi.encode(ACTION_BUY, abi.encode(b))), (uint256, uint256, uint160));
        emit BoughtAndBurned(msg.sender, quote, amountIn, ethIn, foboBurned, sqrtPriceX96);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, bytes memory args) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_WITHDRAW) {
            (Currency c, address to, uint256 amount) = abi.decode(args, (Currency, address, uint256));
            poolManager.burn(address(this), c.toId(), amount);
            poolManager.take(c, to, amount);
            return "";
        }
        return _buyBurn(abi.decode(args, (Buy)));
    }

    /// @dev buybackAndBurn inside unlock: every leg is an exact-in swap whose output is the next one's input, so only the
    ///      quote paid in and the $FOBO taken out are left to settle.
    function _buyBurn(Buy memory b) internal returns (bytes memory) {
        IFoboHook h = hook;
        if (address(h) == address(0)) revert HookNotSet();
        address fobo = h.fobo();
        if (fobo == address(0)) revert NoFobo();
        uint256 ethIn = b.amountIn;
        if (!b.quote.isAddressZero()) {
            Route storage r = _routes[Currency.unwrap(b.quote)];
            uint256 n = r.path.length;
            if (n == 0) revert NoRoute();
            Currency cur = b.quote;
            for (uint256 i; i < n; i++) {
                PoolKey memory key = r.path[i];
                bool zeroForOne = cur == key.currency0;
                (ethIn, cur) = (_swapIn(key, zeroForOne, ethIn), zeroForOne ? key.currency1 : key.currency0);
            }
            // setRoute only takes paths that end in ETH
            if (ethIn < b.minEthOut) revert TooLittleOut();
            if (r.usdPeg) _checkPeg(h, b.amountIn, r.decimals, ethIn);
        }

        // the $FOBO leg: bounded against the pool's start-of-block tick (read before this swap can move it; a raise the
        // swap runs first counts against the bound too). A buy moves the tick down
        PoolKey memory fk = h.keyFor(address(0), fobo);
        PoolId id = fk.toId();
        uint160 sBound = TickMath.getSqrtPriceAtTick(h.startOfBlockTick(id) - BURN_MAX_TICKS);
        uint256 bought = _swapIn(fk, true, ethIn);
        (uint160 sNow,,,) = poolManager.getSlot0(id);
        if (sNow < sBound) revert BurnBound();
        if (bought < b.minFoboOut) revert TooLittleOut();
        poolManager.take(fk.currency1, address(this), bought);
        IFoboToken(fobo).burn(bought);

        _payIn(b.quote, b.amountIn);
        return abi.encode(ethIn, bought, sNow);
    }

    /// @dev An exact-in swap of `amountIn` with no price limit (the caller's bounds check the outcome). Returns the output.
    ///      A FOBO pool's hook reverts a partial fill, and the routes' pools are deep: every leg fills in full.
    function _swapIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        BalanceDelta d = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn), // a token amount the burner holds: far below 2^255
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 out = zeroForOne ? d.amount1() : d.amount0();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(out)); // the output leg of a swap is >= 0
    }

    /// @dev A USD-pegged quote: the ETH its route bought, at the ETH/USD feed's price (FoboLimitOrders', which reverts if
    ///      it is stale or broken), must be worth at least `amountIn` at $1 a unit less PEG_MAX_LOSS_BPS.
    function _checkPeg(IFoboHook h, uint256 amountIn, uint8 decimals, uint256 ethOut) internal view {
        uint256 ethUsd = IFoboLimitOrders(h.limitOrders()).ethUsd(); // 1e18 USD per ETH
        uint256 usdOut = ethOut * ethUsd / 1e18; // 1e18 USD
        uint256 usdIn = amountIn * 10 ** (18 - decimals); // 1e18 USD at $1
        if (usdOut * BPS < usdIn * (BPS - PEG_MAX_LOSS_BPS)) revert OffPeg();
    }

    /// @dev Pays `amount` of `quote` into the PoolManager: its ERC-6909 claims first (the hook's transfers), the rest
    ///      from what is held outright (the launch fee's native ETH, or tokens sent here).
    function _payIn(Currency quote, uint256 amount) internal {
        uint256 claims = poolManager.balanceOf(address(this), quote.toId());
        uint256 fromClaims = claims < amount ? claims : amount;
        if (fromClaims != 0) poolManager.burn(address(this), quote.toId(), fromClaims);
        uint256 rest = amount - fromClaims;
        if (rest == 0) return;
        if (rest > quote.balanceOfSelf()) revert NotEnough();
        if (quote.isAddressZero()) {
            poolManager.settle{value: rest}();
        } else {
            poolManager.sync(quote);
            IERC20(Currency.unwrap(quote)).safeTransfer(address(poolManager), rest);
            poolManager.settle();
        }
    }

    // =====================================================================================================
    // owner
    // =====================================================================================================

    /// @inheritdoc IFoboBurner
    function setHook(IFoboHook _hook) external onlyOwner {
        if (address(hook) != address(0)) revert HookAlreadySet();
        if (address(_hook) == address(0)) revert ZeroAddress();
        if (_hook.burner() != address(this)) revert BadHook();
        hook = _hook;
        emit HookSet(address(_hook));
    }

    /// @inheritdoc IFoboBurner
    function setRoute(address quote, PoolKey[] calldata path, bool usdPeg) external onlyOwner {
        IFoboHook h = hook;
        if (address(h) == address(0)) revert HookNotSet();
        // ETH needs no route (the $FOBO pool is always the last leg) and $FOBO is never bought with itself
        if (quote == address(0) || quote == h.fobo()) revert BadRoute();
        uint256 n = path.length;
        if (n > MAX_HOPS) revert BadRoute();
        Route storage r = _routes[quote];
        delete r.path;
        bytes32[] memory ids = new bytes32[](n);
        Currency cur = Currency.wrap(quote);
        for (uint256 i; i < n; i++) {
            PoolKey calldata key = path[i];
            // a FOBO pool is only ever the last leg, the bounded $FOBO buy: never an unbounded leg on the way
            if (address(key.hooks) == address(h)) revert BadRoute();
            PoolId id = key.toId();
            (uint160 s,,,) = poolManager.getSlot0(id);
            if (s == 0) revert BadRoute(); // not initialised
            if (cur == key.currency0) cur = key.currency1;
            else if (cur == key.currency1) cur = key.currency0;
            else revert BadRoute();
            r.path.push(key);
            ids[i] = PoolId.unwrap(id);
        }
        if (n != 0 && !cur.isAddressZero()) revert BadRoute();
        r.usdPeg = n != 0 && usdPeg;
        r.decimals = r.usdPeg ? _decimalsOf(quote) : 0;
        emit RouteSet(quote, ids, r.usdPeg);
    }

    /// @dev A USD-pegged quote's decimals, at most 18 (the peg check scales it up to 18).
    function _decimalsOf(address quote) internal view returns (uint8 d) {
        d = IERC20Metadata(quote).decimals();
        if (d > 18) revert BadRoute();
    }

    /// @inheritdoc IFoboBurner
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @inheritdoc IFoboBurner
    function emergencyWithdraw(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        Currency c = Currency.wrap(token);
        uint256 claims = poolManager.balanceOf(address(this), c.toId());
        if (claims != 0) poolManager.unlock(abi.encode(ACTION_WITHDRAW, abi.encode(c, to, claims)));
        uint256 balance = c.balanceOfSelf();
        if (balance != 0) c.transfer(to, balance);
        emit EmergencyWithdrawn(token, to, claims, balance);
    }

    // =====================================================================================================
    // views
    // =====================================================================================================

    /// @inheritdoc IFoboBurner
    function routeOf(address quote) external view returns (PoolKey[] memory path, bool usdPeg) {
        Route storage r = _routes[quote];
        return (r.path, r.usdPeg);
    }
}
