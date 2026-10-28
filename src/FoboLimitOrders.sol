// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Owned} from "./base/Owned.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IFoboFactory} from "./interfaces/IFoboFactory.sol";
import {IFoboHook} from "./interfaces/IFoboHook.sol";
import {IFoboLimitOrders} from "./interfaces/IFoboLimitOrders.sol";

/// @title FoboLimitOrders
/// @notice Limit orders on FOBO tokens, paid in a pay token the owner whitelists (native ETH with Chainlink's ETH/USD,
///         later USDG at $1, ...). A BUY escrows the pay token and buys when the token's all-in price is at or below its
///         USD limit; a SELL escrows the token and sells it for the pay token when the all-in price is at or above the
///         limit (take-profit). Keepers (owner-set) fill: they pick each fill's size, its fee (pay-token units, at most
///         the order's maxFeePerFill) and its route (v4 pools from the pay token to the token or back, the hop touching
///         the token being its FOBO pool), all in one PoolManager unlock. Every fill must give the order's owner at
///         least its limit after the tax and the fee, on the amounts that actually moved, at the pay token's USD price
///         from the config the order was placed with: the one guarantee, checked on chain whatever the route. The FOBO
///         pools' hook credits the swaps' referral to the order's owner (read from this contract's hookData).
///         Spec: packages/contracts/README.md §15.
/// @dev Owner = the Owner Safe (two-step, renounce disabled): it whitelists pay tokens and keepers, never touches escrow.
///      Wired to the factory's hook (set once there): that hook must name this contract as its limitOrders (checked on
///      every place and fill). Holds exactly the open orders' escrow: pay tokens for BUYs, tokens for SELLs.
contract FoboLimitOrders is IFoboLimitOrders, IUnlockCallback, ReentrancyGuard, Owned {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 internal constant WAD = 1e18;
    /// @notice Most pools a fill's route may have.
    uint256 public constant MAX_HOPS = 4;
    /// @dev A pay token's decimals and a feed's, at most this (amounts and answers are scaled to 1e18)
    uint8 internal constant MAX_DECIMALS = 18;

    IPoolManager public immutable poolManager;
    /// @notice FoboFactory: its hook (set once) is the pools' hook and names this contract.
    IFoboFactory public immutable factory;
    /// @notice The L2 sequencer uptime feed (Chainlink's: answer 0 = up, 1 = down; startedAt = when that status began),
    ///         or address(0) for none. While the sequencer is down, or until sequencerGracePeriod after it came back,
    ///         no feed-priced fill goes through: the answer may be stale in a way updatedAt doesn't show.
    IAggregatorV3 public immutable sequencerUptimeFeed;
    /// @notice Seconds after the sequencer comes back up before fills resume (with a sequencerUptimeFeed).
    uint256 public immutable sequencerGracePeriod;

    uint256 public orderCount;
    mapping(uint256 => Order) internal _orders;
    mapping(address => Pricing) internal _pricing;
    mapping(address => bool) internal _payAllowed;
    mapping(address => bool) public keepers;

    /// @dev One fill's swaps, inside unlock. `amount` is exact-in: the pay token (a BUY's fill less the fee) or tokens.
    struct Swap {
        Hop[] route;
        address hook;
        address owner;
        Currency input;
        Currency output;
        address recipient; // the output's: a BUY's owner, a SELL's this contract (fill pays it out)
        uint256 amount;
    }

    /// @param _sequencerUptimeFeed the L2 sequencer uptime feed, address(0) for none (then `_sequencerGracePeriod` must
    ///        be 0); with one, `_sequencerGracePeriod` must be positive (Chainlink suggests 3600)
    constructor(
        IPoolManager _poolManager,
        IFoboFactory _factory,
        address _owner,
        IAggregatorV3 _sequencerUptimeFeed,
        uint256 _sequencerGracePeriod
    ) Owned(_owner) {
        if (address(_poolManager) == address(0) || address(_factory) == address(0)) {
            revert ZeroAddress();
        }
        if ((address(_sequencerUptimeFeed) == address(0)) != (_sequencerGracePeriod == 0)) revert BadGracePeriod();
        poolManager = _poolManager;
        factory = _factory;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
    }

    /// @dev ETH only from the PoolManager (a SELL's ETH proceeds, taken in unlock); a BUY's escrow comes with place().
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // =====================================================================================================
    // orders
    // =====================================================================================================

    /// @inheritdoc IFoboLimitOrders
    function place(
        Kind kind,
        address token,
        address payToken,
        uint256 amount,
        uint256 limitPriceUsdE18,
        uint256 expiry,
        uint256 maxFeePerFill
    ) external payable nonReentrant returns (uint256 id) {
        if (amount == 0) revert BadAmount();
        if (limitPriceUsdE18 == 0) revert BadPrice();
        if (expiry <= block.timestamp) revert BadExpiry();
        if (token == address(0) || token == payToken) revert BadToken();
        if (!_payAllowed[payToken]) revert NotPayToken();
        bool buy = kind == Kind.BUY;
        if (msg.value != (buy && payToken == address(0) ? amount : 0)) revert BadValue();
        _hook(); // NotWired: this contract's fills would credit no one's referral to the owner
        Pricing memory pricing = _pricing[payToken];
        id = ++orderCount;
        _orders[id] = Order({
            owner: msg.sender,
            expiry: expiry.toUint40(),
            kind: kind,
            token: token,
            maxFeePerFill: maxFeePerFill.toUint96(),
            remaining: amount.toUint128(),
            limitPriceUsdE18: limitPriceUsdE18.toUint128(),
            payToken: payToken,
            pricing: pricing
        });
        address escrow = buy ? payToken : token;
        if (escrow != address(0)) {
            // the escrow must be what arrived (FOBO tokens move exactly what is sent; a pay token is the owner's review)
            uint256 held = IERC20(escrow).balanceOf(address(this));
            IERC20(escrow).safeTransferFrom(msg.sender, address(this), amount);
            if (IERC20(escrow).balanceOf(address(this)) - held != amount) revert TransferShortfall();
        }
        emit OrderPlaced(
            id, msg.sender, token, kind, payToken, pricing.decimals, amount, limitPriceUsdE18, expiry, maxFeePerFill
        );
    }

    /// @notice Fills `amountIn` of an open, unexpired order's escrow along `route` and pays the keeper `fee` in the pay
    ///         token (at most maxFeePerFill). A BUY swaps `amountIn - fee` of the pay token for the token, straight to
    ///         the owner; a SELL swaps `amountIn` tokens for the pay token and pays the owner the proceeds less the fee.
    ///         Keepers only, any size up to what is left. Reverts LimitNotMet unless, at the pay token's USD price `p`
    ///         (USD per whole unit, from the order's snapshot config), all-in:
    ///         BUY:  amountIn (pay token, fee included) x p <= tokens the owner got x limit
    ///         SELL: pay token the owner got (fee taken) x p >= amountIn (tokens) x limit
    ///         each side converted to USD with FullMath, rounded against the keeper. The route is the keeper's: any v4
    ///         pools from the pay token to the token (BUY) or back (SELL), the hop touching the token its FOBO pool.
    function fill(uint256 id, uint256 amountIn, uint256 fee, Hop[] calldata route)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!keepers[msg.sender]) revert NotKeeper();
        Order storage o = _orders[id];
        Order memory order = o;
        if (order.owner == address(0)) revert UnknownOrder();
        if (order.remaining == 0) revert OrderClosed();
        if (block.timestamp > order.expiry) revert OrderExpired();
        if (amountIn == 0 || amountIn > order.remaining) revert BadAmount();
        bool buy = order.kind == Kind.BUY;
        // a BUY's fee comes out of its escrow: something must be left to swap
        if (fee > order.maxFeePerFill || (buy && fee >= amountIn)) revert FeeTooHigh();
        uint256 price = _price(order.pricing);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 left = order.remaining - uint128(amountIn); // amountIn <= remaining
        o.remaining = left;

        IFoboHook hook = _hook();
        _checkRoute(hook, order.token, order.payToken, buy, route);
        Currency pay = Currency.wrap(order.payToken);
        Currency tok = Currency.wrap(order.token);
        Swap memory s = Swap({
            route: route,
            hook: address(hook),
            owner: order.owner,
            input: buy ? pay : tok,
            output: buy ? tok : pay,
            recipient: buy ? order.owner : address(this),
            amount: buy ? amountIn - fee : amountIn
        });
        // what the owner actually received, measured: a BUY's tokens at the owner, a SELL's pay token here
        uint256 before = buy ? tok.balanceOf(order.owner) : pay.balanceOfSelf();
        poolManager.unlock(abi.encode(s));
        amountOut = _allIn(order, amountIn, fee, price, before);
        emit OrderFilled(id, msg.sender, amountIn, amountOut, fee, price, left);
        if (!buy) _send(order.payToken, order.owner, amountOut);
        _send(order.payToken, msg.sender, fee);
    }

    /// @dev What the owner got from a fill (measured against `before`), checked against its limit at `price`; reverts
    ///      LimitNotMet unless it holds, FeeTooHigh if a SELL's fee is more than its proceeds.
    function _allIn(Order memory order, uint256 amountIn, uint256 fee, uint256 price, uint256 before)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 unit = 10 ** uint256(order.pricing.decimals);
        if (order.kind == Kind.BUY) {
            amountOut = Currency.wrap(order.token).balanceOf(order.owner) - before;
            // the inputs are exact (_swap checks each hop took all of it): the escrow spent amountIn, fee included
            if (
                FullMath.mulDivRoundingUp(amountIn, price, unit)
                    > FullMath.mulDiv(amountOut, order.limitPriceUsdE18, WAD)
            ) {
                revert LimitNotMet();
            }
        } else {
            uint256 proceeds = Currency.wrap(order.payToken).balanceOfSelf() - before;
            if (fee > proceeds) revert FeeTooHigh();
            amountOut = proceeds - fee;
            if (
                FullMath.mulDiv(amountOut, price, unit)
                    < FullMath.mulDivRoundingUp(amountIn, order.limitPriceUsdE18, WAD)
            ) {
                revert LimitNotMet();
            }
        }
    }

    /// @notice Closes an open order and sends its escrow to `to`. The owner only, any time (expired or not). The site
    ///         always passes the owner's own wallet; another address is the way out for an owner that can't take the
    ///         escrow (one that rejects ETH, or is frozen by a pay token: refund always pays the owner).
    function cancel(uint256 id, address to) external nonReentrant {
        Order storage o = _orders[id];
        if (msg.sender != o.owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        uint256 refunded = _close(o);
        emit OrderCancelled(id, o.owner, refunded);
        _payBack(o, to, refunded);
    }

    /// @notice Returns an expired order's escrow to its owner. Anyone can call it once the order has expired (a keeper
    ///         sweeping the book, or the owner); it always pays the owner.
    function refund(uint256 id) external nonReentrant {
        Order storage o = _orders[id];
        if (o.owner == address(0)) revert UnknownOrder();
        if (block.timestamp <= o.expiry) revert NotExpired();
        uint256 refunded = _close(o);
        emit OrderRefunded(id, o.owner, refunded);
        _payBack(o, o.owner, refunded);
    }

    /// @dev Empties an open order; returns what its escrow held.
    function _close(Order storage o) internal returns (uint256 refunded) {
        refunded = o.remaining;
        if (refunded == 0) revert OrderClosed();
        o.remaining = 0;
    }

    /// @dev Sends a closed order's escrow to `to`: the pay token for a BUY, the token for a SELL.
    function _payBack(Order storage o, address to, uint256 amount) internal {
        _send(o.kind == Kind.BUY ? o.payToken : o.token, to, amount);
    }

    /// @dev Native ETH (address(0)) or an ERC-20
    function _send(address currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    // =====================================================================================================
    // swaps (inside unlock)
    // =====================================================================================================

    /// @dev A fill's route: exact-in hops, each one's output the next one's input, with no price limit (the FOBO hook
    ///      reverts a swap that stops early, PartialFill, and _swap any hop that doesn't take all its input; the all-in
    ///      check is the price bound). Intermediate currencies' deltas cancel out, so only the input paid in and the
    ///      output taken out are left to settle.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Swap memory s = abi.decode(data, (Swap));
        uint256 amount = _swaps(s);
        if (s.input.isAddressZero()) {
            poolManager.settle{value: s.amount}();
        } else {
            poolManager.sync(s.input);
            IERC20(Currency.unwrap(s.input)).safeTransfer(address(poolManager), s.amount);
            poolManager.settle();
        }
        poolManager.take(s.output, s.recipient, amount);
        return "";
    }

    /// @dev The route's hops in order; returns the last one's output. The FOBO hook credits the referral to the trader
    ///      in this contract's hookData (the order's owner); other pools' hooks get none.
    function _swaps(Swap memory s) internal returns (uint256 amount) {
        bytes memory ownerData = abi.encode(s.owner);
        bytes memory none;
        amount = s.amount;
        uint256 n = s.route.length;
        for (uint256 i; i < n; i++) {
            Hop memory h = s.route[i];
            amount = _swap(h, amount, address(h.key.hooks) == s.hook ? ownerData : none);
            // a hop too small to give anything leaves the owner nothing (and the next hop nothing to swap)
            if (amount == 0) revert LimitNotMet();
        }
    }

    /// @dev One exact-in hop of `amountIn`. Returns the output; reverts unless the hop took exactly `amountIn`, so the
    ///      escrow spent is exactly what the fill says.
    function _swap(Hop memory h, uint256 amountIn, bytes memory hookData) internal returns (uint256) {
        int256 exactIn = amountIn.toInt256();
        BalanceDelta d = poolManager.swap(
            h.key,
            IPoolManager.SwapParams({
                zeroForOne: h.zeroForOne,
                amountSpecified: -exactIn,
                sqrtPriceLimitX96: h.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
        (int128 paid, int128 got) = h.zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        if (-int256(paid) != exactIn) revert IncompleteSwap();
        return SafeCast.toUint256(got);
    }

    /// @dev A route must connect: a BUY's from the pay token to the token, a SELL's from the token to the pay token, each
    ///      hop's input the previous one's output, at most MAX_HOPS. The order's token appears in one hop only, the
    ///      route's last (BUY) or first (SELL), and that hop is the token's FOBO pool (the hook's key for its quote), so
    ///      the hook sees the fill as the owner's trade. Any other hop may be any v4 pool: the all-in check bounds what
    ///      the route gives.
    function _checkRoute(IFoboHook hook, address token, address payToken, bool buy, Hop[] calldata route)
        internal
        view
    {
        uint256 n = route.length;
        if (n == 0 || n > MAX_HOPS) revert BadRoute();
        uint256 tokenHop = buy ? n - 1 : 0;
        address cur = buy ? payToken : token;
        for (uint256 i; i < n; i++) {
            PoolKey calldata key = route[i].key;
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            (address input, address output) = route[i].zeroForOne ? (c0, c1) : (c1, c0);
            if (input != cur) revert BadRoute();
            if (i == tokenHop) {
                // the token is always currency1 of its FOBO pool (the hook's keyFor)
                if (c1 != token || PoolId.unwrap(key.toId()) != PoolId.unwrap(hook.keyFor(c0, token).toId())) {
                    revert BadRoute();
                }
            } else if (c0 == token || c1 == token) {
                revert BadRoute();
            }
            cur = output;
        }
        if (cur != (buy ? token : payToken)) revert BadRoute();
    }

    // =====================================================================================================
    // owner
    // =====================================================================================================

    /// @inheritdoc IFoboLimitOrders
    function setPayToken(address token, IAggregatorV3 feed, uint256 maxPriceAge, bool isStable, bool allowed)
        external
        onlyOwner
    {
        uint8 decimals = token == address(0) ? 18 : IERC20Metadata(token).decimals();
        if (decimals > MAX_DECIMALS) revert BadPayToken();
        uint8 feedDecimals;
        if (isStable) {
            // $1 a unit, no feed: native ETH never is
            if (token == address(0) || address(feed) != address(0) || maxPriceAge != 0) revert BadPayToken();
        } else {
            if (address(feed) == address(0)) revert BadFeed();
            if (maxPriceAge == 0) revert BadMaxAge();
            feedDecimals = feed.decimals();
            if (feedDecimals > MAX_DECIMALS) revert BadFeed();
        }
        _pricing[token] = Pricing({
            feed: feed,
            maxPriceAge: maxPriceAge.toUint40(),
            feedDecimals: feedDecimals,
            decimals: decimals,
            isStable: isStable
        });
        _payAllowed[token] = allowed;
        emit PayTokenSet(token, address(feed), maxPriceAge, isStable, allowed, decimals);
    }

    /// @inheritdoc IFoboLimitOrders
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    // =====================================================================================================
    // views
    // =====================================================================================================

    /// @inheritdoc IFoboLimitOrders
    function payTokens(address token) external view returns (Pricing memory pricing, bool allowed) {
        return (_pricing[token], _payAllowed[token]);
    }

    /// @inheritdoc IFoboLimitOrders
    function priceOf(address token) public view returns (uint256) {
        return _price(_pricing[token]);
    }

    /// @inheritdoc IFoboLimitOrders
    function ethUsd() external view returns (uint256) {
        return priceOf(address(0));
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    /// @dev A pay token's USD price (1e18 per whole unit) under `p`: $1 if stable, else its feed's answer after the
    ///      sequencer check (with a sequencerUptimeFeed: SequencerDown while it reports the sequencer down,
    ///      SequencerGracePeriod until sequencerGracePeriod has passed since it came back up or with no round yet).
    ///      FeedPriceInvalid unless the answer is positive, FeedPriceStale if older than p.maxPriceAge, never updated or
    ///      from the future. answeredInRound isn't read: Chainlink deprecated it and compatible feeds may report 0.
    ///      Fills only: cancel and refund never read a feed.
    function _price(Pricing memory p) internal view returns (uint256) {
        if (p.isStable) return WAD;
        if (address(p.feed) == address(0)) revert NotPayToken(); // never configured
        if (address(sequencerUptimeFeed) != address(0)) {
            (, int256 status, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
            if (status != 0) revert SequencerDown();
            // startedAt 0: no round yet (an uninitialised feed)
            if (startedAt == 0 || startedAt > block.timestamp || block.timestamp - startedAt <= sequencerGracePeriod) {
                revert SequencerGracePeriod();
            }
        }
        (, int256 answer,, uint256 updatedAt,) = p.feed.latestRoundData();
        if (answer <= 0) revert FeedPriceInvalid();
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > p.maxPriceAge) {
            revert FeedPriceStale();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer) * 10 ** (MAX_DECIMALS - p.feedDecimals); // answer > 0
    }

    /// @dev The hook (the factory's, which must name this contract).
    function _hook() internal view returns (IFoboHook hook) {
        hook = factory.hook();
        if (address(hook) == address(0) || hook.limitOrders() != address(this)) revert NotWired();
    }
}
