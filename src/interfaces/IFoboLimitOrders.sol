// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

/// @notice FoboLimitOrders: escrowed limit orders on FOBO tokens, paid in an owner-whitelisted pay token (native ETH,
///         USDG, ...), filled by the owner's keepers along a route they pick, for a capped fee in the pay token. Every
///         fill is checked against the order's USD limit at the pay token's price (a Chainlink USD feed, or exactly $1
///         for a stablecoin), after tax and fee. Spec: packages/contracts/README.md §15.
interface IFoboLimitOrders {
    /// @dev BUY: escrows the pay token, buys the token when its all-in price is at or below the limit. SELL: escrows the
    ///      token, sells it for the pay token when its all-in price is at or above the limit (take-profit).
    enum Kind {
        BUY,
        SELL
    }

    /// @dev How a pay token is priced in USD: a Chainlink AggregatorV3 USD feed (decimals <= 18, answers no older than
    ///      maxPriceAge), or isStable: exactly $1 a whole unit, no feed (feed, maxPriceAge and feedDecimals are 0).
    ///      `decimals` is the pay token's own (18 for native ETH). One slot.
    struct Pricing {
        IAggregatorV3 feed;
        uint40 maxPriceAge; // seconds
        uint8 feedDecimals;
        uint8 decimals;
        bool isStable;
    }

    /// @dev Five slots. `remaining` is the escrow left: pay-token units for a BUY, token units for a SELL; 0 = closed
    ///      (filled, cancelled or refunded). `pricing` is the pay token's price config as it was at placement: later
    ///      owner changes (setPayToken) never reach an open order.
    struct Order {
        address owner;
        uint40 expiry; // unix seconds: fills while block.timestamp <= expiry, refundable by anyone after
        Kind kind;
        address token;
        uint96 maxFeePerFill; // pay-token units: the most a keeper may take per fill
        uint128 remaining;
        uint128 limitPriceUsdE18; // USD per whole token (1e18 units), 1e18-scaled
        address payToken; // address(0) = native ETH
        Pricing pricing;
    }

    /// @dev One hop of a fill's route: an exact-in swap through `key`, `zeroForOne` its direction. A BUY's route runs
    ///      from the pay token to the order's token, a SELL's from the token to the pay token.
    struct Hop {
        PoolKey key;
        bool zeroForOne;
    }

    /// @param amount the escrow: pay-token units for a BUY, token units for a SELL
    /// @param payDecimals the pay token's decimals (its amounts' unit)
    event OrderPlaced(
        uint256 indexed id,
        address indexed owner,
        address indexed token,
        Kind kind,
        address payToken,
        uint8 payDecimals,
        uint256 amount,
        uint256 limitPriceUsdE18,
        uint256 expiry,
        uint256 maxFeePerFill
    );
    /// @param amountIn escrow the fill used: a BUY's pay token (the swap plus the fee), a SELL's tokens
    /// @param amountOut what the owner got: a BUY's tokens, a SELL's pay token (after the fee)
    /// @param fee pay token paid to the keeper
    /// @param payUsdE18 the pay token's price the fill was checked at (USD per whole unit, 1e18-scaled)
    /// @param remaining the order's escrow left after this fill (0: filled, closed)
    event OrderFilled(
        uint256 indexed id,
        address indexed filler,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 payUsdE18,
        uint256 remaining
    );
    /// @notice The owner closed the order and got its escrow back (`refunded`, as in OrderPlaced.amount).
    event OrderCancelled(uint256 indexed id, address indexed owner, uint256 refunded);
    /// @notice The order expired and someone (anyone) sent its escrow back to the owner.
    event OrderRefunded(uint256 indexed id, address indexed owner, uint256 refunded);
    /// @notice The owner set a pay token's price config and whether new orders may use it.
    event PayTokenSet(
        address indexed token, address feed, uint256 maxPriceAge, bool isStable, bool allowed, uint8 decimals
    );
    event KeeperSet(address indexed keeper, bool allowed);

    error NotPoolManager();
    error ZeroAddress();
    error BadFeed();
    error BadMaxAge();
    error BadPayToken();
    error NotPayToken();
    error NotKeeper();
    error NotWired();
    error BadToken();
    error BadRoute();
    error BadAmount();
    error BadPrice();
    error BadExpiry();
    error BadValue();
    error TransferShortfall();
    error UnknownOrder();
    error OrderClosed();
    error OrderExpired();
    error NotExpired();
    error NotOwner();
    error FeeTooHigh();
    error LimitNotMet();
    error IncompleteSwap();
    error FeedPriceInvalid();
    error FeedPriceStale();
    error SequencerDown();
    error SequencerGracePeriod();
    error BadGracePeriod();
    error EthTransferFailed();

    /// @notice Places an order and escrows it: a BUY escrows `amount` of `payToken` (native ETH: sent with the call; an
    ///         ERC-20: pulled, approve this contract first), a SELL pulls `amount` of the token. `payToken` must be
    ///         whitelisted (setPayToken); the order snapshots its price config. Any FOBO token can be ordered: a fill
    ///         needs a route through its FOBO pool.
    /// @param limitPriceUsdE18 USD per whole token, 1e18-scaled (the site's FDV / 1B)
    /// @param expiry unix seconds, in the future
    /// @param maxFeePerFill the most (pay-token units) a keeper may take for one fill
    function place(
        Kind kind,
        address token,
        address payToken,
        uint256 amount,
        uint256 limitPriceUsdE18,
        uint256 expiry,
        uint256 maxFeePerFill
    ) external payable returns (uint256 id);

    /// @notice Fills `amountIn` of an open order's escrow (exact-in) along `route` and pays the keeper `fee` in the pay
    ///         token (at most the order's maxFeePerFill; a BUY's fee comes out of `amountIn`, a SELL's out of the
    ///         proceeds). Keepers only. The hop touching the order's token must be its FOBO pool; the others may be any
    ///         v4 pools. Reverts LimitNotMet unless the owner gets at least its limit price, all-in, at the pay token's
    ///         USD price (its snapshot config).
    /// @return amountOut what the owner got: tokens for a BUY, the pay token for a SELL (after the fee)
    function fill(uint256 id, uint256 amountIn, uint256 fee, Hop[] calldata route) external returns (uint256 amountOut);

    /// @notice Closes an open order and sends its escrow to `to` (the site passes the owner). The owner only, any time.
    function cancel(uint256 id, address to) external;

    /// @notice Returns an expired order's escrow to its owner. Anyone can call it, after expiry.
    function refund(uint256 id) external;

    /// @notice Owner: sets `token`'s price config (a Chainlink USD feed with its max age, or isStable at $1 with no
    ///         feed and age 0) and whether new orders may pay with it. Open orders keep the config they were placed with.
    function setPayToken(address token, IAggregatorV3 feed, uint256 maxPriceAge, bool isStable, bool allowed) external;

    /// @notice Owner: adds or removes a keeper (fill is keepers only; several may be set).
    function setKeeper(address keeper, bool allowed) external;

    /// @notice A pay token's current config, and whether new orders may use it.
    function payTokens(address token) external view returns (Pricing memory pricing, bool allowed);

    /// @notice A pay token's USD price as a fill with its current config would check it: USD per whole unit,
    ///         1e18-scaled. A feed-priced token reverts while the L2 sequencer (if a sequencerUptimeFeed is set) is down
    ///         or within its grace period after coming back, and if the feed's answer is not positive, older than its
    ///         maxPriceAge, never updated or dated in the future; a stable one is 1e18. NotPayToken if never configured.
    function priceOf(address token) external view returns (uint256);

    /// @notice priceOf(native ETH): the ETH/USD price (FoboBurner's peg check and the launch script read it).
    function ethUsd() external view returns (uint256);

    function getOrder(uint256 id) external view returns (Order memory);
    /// @notice Orders placed so far; ids run from 1 to orderCount.
    function orderCount() external view returns (uint256);
    function keepers(address keeper) external view returns (bool);
    /// @notice The L2 sequencer uptime feed feed-priced fills check first; address(0) = none.
    function sequencerUptimeFeed() external view returns (IAggregatorV3);
    /// @notice Seconds after the sequencer comes back up before fills resume; 0 with no sequencerUptimeFeed.
    function sequencerGracePeriod() external view returns (uint256);
}
