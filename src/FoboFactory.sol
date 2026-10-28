// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Owned} from "./base/Owned.sol";
import {IFoboFactory} from "./interfaces/IFoboFactory.sol";
import {IFoboHook} from "./interfaces/IFoboHook.sol";
import {IFoboVesting} from "./interfaces/IFoboVesting.sol";
import {Ticks} from "./libraries/Ticks.sol";
import {FoboToken} from "./FoboToken.sol";

/// @title FoboFactory
/// @notice Launches tokens. The first launch is owner-only, pairs with ETH and becomes $FOBO; every launch after it pairs
///         with a quote the creator picks from the owner's allowlist (ETH and $FOBO by default), pays a small ETH launch
///         fee that goes to FoboBurner (which buys and burns $FOBO with it), and may include a creator buy of up to 5%.
///         Every launch after $FOBO starts at a price the start signer signed for it (creator, salt, pair, name and
///         ticker: EIP-712), checked against the pair's start band. The owner can't touch live pools. Spec: packages/contracts/README.md.
contract FoboFactory is IFoboFactory, IUnlockCallback, EIP712, ReentrancyGuard, Owned {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant DEV_BUY_MAX = 50_000_000e18; // 5% of the 1B supply: the most devBuyMax can ever be
    /// @dev Widest start band the owner can set (in ticks of tokens per ETH): 13,920 ticks is ~4x, i.e. ~2x either side
    ///      of a $10k start at the ETH price it was set for.
    int24 public constant MAX_START_BAND = 13_920;
    /// @notice Fewest decimals a quote may have (USDG has 6); setQuoteAllowed refuses fewer, BadQuote.
    uint8 public constant MIN_QUOTE_DECIMALS = 6;
    bytes32 public constant LAUNCH_START_TYPEHASH = keccak256(
        "LaunchStart(address creator,bytes32 salt,address quote,string name,string ticker,int24 tickStart,uint256 deadline)"
    );

    IPoolManager public immutable poolManager;
    /// @notice FoboVesting: a launch with LaunchParams.vestMonths locks its dev buy there for the creator
    IFoboVesting public immutable vesting;

    address public team;
    IFoboHook public hook; // set once
    /// @notice FoboBurner, where every launch fee goes (the hook's burner, read when the hook is set)
    address public burner;
    address public fobo; // set once, by the first launch
    uint256 public launchFeeEth;
    /// @notice The most a creator may buy in its launch transaction (tokens, 18 decimals): DEV_BUY_MAX (5%) from deploy,
    ///         the owner can lower it (setDevBuyMax) and raise it back, never above DEV_BUY_MAX.
    uint256 public devBuyMax = DEV_BUY_MAX;
    // one slot: the start signer, the start band and the pause flag
    address public startSigner; // signs every launch's start tick after $FOBO (EIP-712 LaunchStart)
    /// @notice A signed start must put the new token at a price in tokens per ETH (an ETH pair's tickStart; a $FOBO pair's
    ///         tickStart plus the $FOBO pool's start-of-block tick) within [startBandLow, startBandHigh]: ~2x either side
    ///         of a $10k start in ETH.
    int24 public startBandLow;
    int24 public startBandHigh;
    bool public launchesPaused;
    /// @notice The pairs a launch may pick, by quote (address(0) = ETH). ETH is allowed from deploy and $FOBO from its
    ///         launch; the owner allows more (plain ERC-20s of any decimals) or disallows any, which only stops new
    ///         launches on it. ETH and $FOBO pairs check their start against the ETH band (startBandLow/High); every
    ///         other quote against its own band here, in ticks of raw token units per raw quote unit (a quote with d
    ///         decimals sits (18 - d) x log1.0001(10) ticks above an 18-decimal one at the same price). `decimals` is the
    ///         quote's, read when it is allowed: what the site and the indexer price its pools in.
    mapping(address => QuoteConfig) public quotes;
    /// @notice A signed start is good for one launch: creator => salt => used. The token's CREATE2 salt is keyed by the
    ///         same creator (predictToken), so one (creator, salt) is one address.
    mapping(address => mapping(bytes32 => bool)) public startUsed;

    struct DevBuy {
        PoolKey key;
        uint256 tokens;
        address to;
        address payer; // a token quote: who pays it
        uint256 maxEth; // an ETH pair: what msg.value has left for it
        uint256 maxCost; // the launcher's bound (LaunchParams.devBuyMaxCost)
    }

    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _team,
        uint256 _launchFeeEth,
        IFoboVesting _vesting
    ) EIP712("FoboFactory", "1") Owned(_owner) {
        // team balances (and $FOBO's creator share) are paid to `team` by a permissionless claim: never zero
        if (address(_poolManager) == address(0) || _team == address(0) || address(_vesting) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = _poolManager;
        vesting = _vesting;
        team = _team;
        launchFeeEth = _launchFeeEth;
        quotes[address(0)] = QuoteConfig({allowed: true, bandLow: 0, bandHigh: 0, decimals: 18});
        emit QuoteAllowed(address(0), true);
    }

    // =====================================================================================================
    // launch
    // =====================================================================================================

    /// @notice Launch a token. Send the launch fee plus enough ETH for the dev buy; the rest is refunded. On a pair other
    ///         than ETH or $FOBO the dev buy is paid in the quote itself: approve this factory for it first.
    function launch(LaunchParams calldata lp) external payable nonReentrant returns (address token, PoolId poolId) {
        return _launch(lp, msg.sender);
    }

    function _launch(LaunchParams calldata lp, address creator) internal returns (address token, PoolId poolId) {
        if (launchesPaused) revert Paused();
        if (lp.devBuyTokens > devBuyMax) revert DevBuyTooBig();
        if (lp.vestMonths != 0 && lp.devBuyTokens == 0) revert VestWithoutDevBuy();
        bool first = fobo == address(0);
        address quote = lp.quote;
        uint256 spent;
        if (first) {
            _checkOwner(); // $FOBO is the owner's launch
            if (quote != address(0)) revert BadQuote(); // $FOBO pairs with ETH
        } else {
            if (!quotes[quote].allowed) revert BadQuote();
            if (msg.value < launchFeeEth) revert FeeNotPaid();
            spent = launchFeeEth;
            _useStart(lp, creator);
        }
        int24 tickStart = lp.tickStart;

        token = address(new FoboToken{salt: keccak256(abi.encode(creator, lp.salt))}(lp.name, lp.ticker));
        if (token <= quote) revert BadSalt();
        if (first) {
            fobo = token;
            quotes[token] = QuoteConfig({allowed: true, bandLow: 0, bandHigh: 0, decimals: 18}); // FoboToken: 18
            emit QuoteAllowed(token, true);
        }

        // 1) launch fee: native ETH to FoboBurner, which buys $FOBO with it and burns it later (whatever the new token's
        //    pair). It only emits Received: nothing it does can reenter a launch
        if (spent != 0) {
            (bool sent,) = burner.call{value: spent}("");
            if (!sent) revert FeeTransferFailed();
        }

        // 2) pool + positions (the hook owns them). FoboToken (OpenZeppelin ERC20) reverts on failure
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        FoboToken(token).transfer(address(hook), FoboToken(token).totalSupply());
        PoolKey memory key = hook.createPool(quote, token, first ? address(0) : creator, tickStart);
        poolId = key.toId();

        // 3) creator's initial buy: exact-out tokens, paid in the pair's quote: ETH out of msg.value, or the quote token
        //    ($FOBO or any other) from msg.sender. Locked (vestMonths): bought to this factory, then locked in FoboVesting
        //    for the creator in this transaction (FoboVesting checks the months), so the creator never holds them unlocked
        bool vests = lp.vestMonths != 0;
        if (lp.devBuyTokens != 0) {
            DevBuy memory b = DevBuy({
                key: key,
                tokens: lp.devBuyTokens,
                to: vests ? address(this) : creator,
                payer: msg.sender,
                maxEth: msg.value - spent,
                maxCost: lp.devBuyMaxCost
            });
            spent += abi.decode(poolManager.unlock(abi.encode(b)), (uint256));
            if (vests) {
                // FoboToken (OpenZeppelin ERC20): plain approve, exactly what FoboVesting pulls
                FoboToken(token).approve(address(vesting), lp.devBuyTokens);
                vesting.lock(token, lp.devBuyTokens, lp.vestMonths, creator);
            }
        }
        hook.endLaunch(); // no more base rate for this factory's swaps on the new pool

        emit TokenLaunched(
            token, poolId, creator, quote, tickStart, lp.devBuyTokens, lp.name, lp.ticker, lp.metadataURI
        );

        if (msg.value > spent) {
            (bool ok,) = msg.sender.call{value: msg.value - spent}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev A launch's start (every launch after $FOBO): signed by the start signer for this creator, salt, pair,
    ///      name and ticker (what the site checked before signing), not expired, not used before, and inside the pair's
    ///      start band (_startRange).
    function _useStart(LaunchParams calldata lp, address creator) internal {
        if (block.timestamp > lp.deadline) revert StartExpired();
        if (startUsed[creator][lp.salt]) revert StartUsed();
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(
            launchStartDigest(creator, lp.salt, lp.quote, lp.name, lp.ticker, lp.tickStart, lp.deadline), lp.signature
        );
        // tryRecover never yields address(0) without an error, so an unset signer matches nothing
        if (err != ECDSA.RecoverError.NoError || signer != startSigner) revert BadStartSignature();
        (int24 low, int24 high) = _startRange(lp.quote);
        if (lp.tickStart < low || lp.tickStart > high) revert StartOutOfBand();
        startUsed[creator][lp.salt] = true;
    }

    /// @dev The start ticks (tokens per quote) a launch on this allowed pair may use right now. ETH: the ETH band. $FOBO:
    ///      the ETH band less the $FOBO pool's start-of-block tick (tokens per $FOBO + $FOBO per ETH = tokens per ETH, so
    ///      neither a bad signature nor a $FOBO pump inside the launch's own transaction can start a token far from $10k).
    ///      Any other quote: its own band.
    function _startRange(address quote) internal view returns (int24 low, int24 high) {
        if (quote == address(0)) return (startBandLow, startBandHigh);
        if (quote == fobo) {
            int24 ref = hook.startOfBlockTick(hook.keyFor(address(0), fobo).toId());
            return (startBandLow - ref, startBandHigh - ref);
        }
        QuoteConfig storage c = quotes[quote];
        return (c.bandLow, c.bandHigh);
    }

    /// @notice The EIP-712 digest the start signer signs for a launch: LaunchStart(creator, salt, quote, name, ticker,
    ///         tickStart, deadline) in this factory's domain ("FoboFactory", "1", chain id, this address). `quote` is the
    ///         pair (address(0) = ETH, $FOBO or another allowed quote), so a start signed for one pair, name or ticker can't
    ///         launch another.
    ///         `name` and `ticker` are hashed as EIP-712 strings (keccak256 of their bytes).
    function launchStartDigest(
        address creator,
        bytes32 salt,
        address quote,
        string calldata name,
        string calldata ticker,
        int24 tickStart,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LAUNCH_START_TYPEHASH,
                    creator,
                    salt,
                    quote,
                    keccak256(bytes(name)),
                    keccak256(bytes(ticker)),
                    tickStart,
                    deadline
                )
            )
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        // the only unlock: the creator's initial buy, exact-out tokens
        DevBuy memory b = abi.decode(data, (DevBuy));
        uint256 quoteOwed = uint256(int256(-_buy(b.key, int256(b.tokens)).amount0()));
        if (quoteOwed > b.maxCost) revert DevBuyTooExpensive();
        if (Currency.unwrap(b.key.currency0) != address(0)) {
            // a token quote ($FOBO or any other): paid in it, straight from the launcher to the PoolManager
            poolManager.sync(b.key.currency0);
            IERC20(Currency.unwrap(b.key.currency0)).safeTransferFrom(b.payer, address(poolManager), quoteOwed);
            poolManager.settle();
            poolManager.take(b.key.currency1, b.to, b.tokens);
            return abi.encode(uint256(0));
        }
        // an ETH pair: paid out of msg.value
        if (quoteOwed > b.maxEth) revert DevBuyUnderpaid();
        poolManager.settle{value: quoteOwed}();
        poolManager.take(b.key.currency1, b.to, b.tokens);
        return abi.encode(quoteOwed);
    }

    /// @dev A buy (quote for token) with no price limit: exact-out tokens (`amountSpecified` > 0).
    function _buy(PoolKey memory key, int256 amountSpecified) internal returns (BalanceDelta) {
        return poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
    }

    // =====================================================================================================
    // owner
    // =====================================================================================================

    /// @notice The hook every launch creates its pool through. Once, and only a hook built for this factory (its
    ///         `factory()` is this contract): a wrong one could never be replaced. Its FoboBurner (immutable in the hook)
    ///         becomes the launch fee's recipient, so the two can never disagree.
    function setHook(IFoboHook _hook) external onlyOwner {
        if (address(hook) != address(0)) revert HookSet();
        if (address(_hook) == address(0)) revert ZeroAddress();
        if (_hook.factory() != address(this)) revert BadHook();
        hook = _hook;
        address b = _hook.burner();
        burner = b;
        emit ConfigChanged("hook", uint256(uint160(address(_hook))));
        emit ConfigChanged("burner", uint256(uint160(b)));
    }

    /// @notice The key that signs every launch's start tick after $FOBO (a hot key on the site's server). Rotating it voids
    ///         every start the old key signed, unless that key is set again: its unexpired, unused starts then work again
    ///         (never rotate back to a key that leaked).
    function setStartSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        startSigner = signer;
        emit ConfigChanged("startSigner", uint256(uint160(signer)));
    }

    /// @notice The ETH band: where a signed start on an ETH or $FOBO pair may put a new token, in ticks of tokens per ETH
    ///         (an ETH pair's start tick; a $FOBO pair's start tick plus the $FOBO pool's start-of-block tick); at most
    ///         MAX_START_BAND wide. Set it around the $10k start at today's ETH price (script/Deploy.s.sol does) and move
    ///         it when ETH leaves the band.
    function setStartBand(int24 low, int24 high) external onlyOwner {
        _checkBand(low, high);
        startBandLow = low;
        startBandHigh = high;
        // a negative tick is logged as its two's complement on purpose: read the value back as an int256
        // forge-lint: disable-next-line(unsafe-typecast)
        emit ConfigChanged("startBandLow", uint256(int256(low)));
        // forge-lint: disable-next-line(unsafe-typecast)
        emit ConfigChanged("startBandHigh", uint256(int256(high)));
    }

    /// @notice Allow or disallow a pair for new launches. Disallowing never touches existing pools (nothing here can).
    ///         ETH and $FOBO need nothing else; any other quote must have a start band (setQuoteBand) and answer
    ///         `decimals()` (any value: the band is in raw units, so a 6-decimal quote's band simply sits ~276k ticks
    ///         higher; its decimals are stored for the site and the indexer), and must be a plain ERC-20: no fee on
    ///         transfer, no rebasing, no hooks on transfer (an owner review step, see the README: the PoolManager's
    ///         accounting can't hold such a token).
    function setQuoteAllowed(address quote, bool allowed) external onlyOwner {
        QuoteConfig storage c = quotes[quote];
        if (allowed && quote != address(0) && quote != fobo) {
            if (c.bandLow == 0 && c.bandHigh == 0) revert NoBand();
            c.decimals = _decimalsOf(quote);
        }
        c.allowed = allowed;
        emit QuoteAllowed(quote, allowed);
    }

    /// @notice A pair's start band, in ticks of raw token units per raw quote unit, for any quote but ETH and $FOBO (those
    ///         use the ETH band, setStartBand). Set it around a $10k start at the quote's price and decimals
    ///         (script/QuoteBand.s.sol computes it: ~391,500 for a $1 6-decimal quote); at most MAX_START_BAND wide.
    function setQuoteBand(address quote, int24 low, int24 high) external onlyOwner {
        if (quote == address(0) || quote == fobo) revert BadQuote();
        _checkBand(low, high);
        QuoteConfig storage c = quotes[quote];
        c.bandLow = low;
        c.bandHigh = high;
        emit QuoteBandSet(quote, low, high);
    }

    /// @dev A band is at most MAX_START_BAND wide and inside the start ticks the hook's createPool accepts.
    function _checkBand(int24 low, int24 high) internal pure {
        if (
            low >= high || low < Ticks.MIN_START_TICK || high >= TickMath.MAX_TICK - Ticks.SPACING
                || int256(high) - int256(low) > MAX_START_BAND
        ) revert BadTick();
        // A non-empty numeric interval may still contain no usable tick on the hook's 60-tick grid.
        int24 first = Ticks.alignDown(low);
        if (first < low) first += Ticks.SPACING;
        if (first > high) revert BadTick();
    }

    /// @dev A quote's `decimals()`: the site, the signer and the indexer price its pools with it (quotes(quote).decimals),
    ///      read once here when the quote is allowed and never again. A token without a usable one is refused, `BadQuote`
    ///      (nothing could price it): the call reverts, there is no code, it returns anything but one word, or a value
    ///      past uint8. A low-level call, so a bad answer is this error and not a bare ABI-decoding revert. Fewer than
    ///      MIN_QUOTE_DECIMALS is refused too: pots of a few raw units near the max tick round raises into FloorBroken.
    function _decimalsOf(address quote) internal view returns (uint8) {
        (bool ok, bytes memory data) = quote.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!ok || data.length != 32) revert BadQuote();
        uint256 d = abi.decode(data, (uint256));
        if (d > type(uint8).max || d < MIN_QUOTE_DECIMALS) revert BadQuote();
        return uint8(d);
    }

    /// @notice Sets the creator's launch-buy cap for new launches (0 = no dev buy), at most DEV_BUY_MAX.
    function setDevBuyMax(uint256 tokens) external onlyOwner {
        if (tokens > DEV_BUY_MAX) revert DevBuyTooBig();
        devBuyMax = tokens;
        emit ConfigChanged("devBuyMax", tokens);
    }

    function setLaunchFee(uint256 fee) external onlyOwner {
        launchFeeEth = fee;
        emit ConfigChanged("launchFeeEth", fee);
    }

    function setTeam(address _team) external onlyOwner {
        if (_team == address(0)) revert ZeroAddress();
        team = _team;
        emit ConfigChanged("team", uint256(uint160(_team)));
    }

    function setLaunchesPaused(bool paused) external onlyOwner {
        launchesPaused = paused;
        emit ConfigChanged("launchesPaused", paused ? 1 : 0);
    }

    /// @notice The start ticks (tokens per quote) a signed launch on this pair may use right now, what the start signer
    ///         checks before signing: the ETH band for ETH, the ETH band less the $FOBO pool's start-of-block tick for
    ///         $FOBO, its own band for any other quote. Reverts unless the pair is allowed and $FOBO is launched.
    function startTickRange(address quote) external view returns (int24 low, int24 high) {
        if (fobo == address(0) || !quotes[quote].allowed) revert BadQuote();
        return _startRange(quote);
    }

    /// @notice CREATE2 address a launch with these params will deploy the token at (for the front end's salt search).
    /// @param creator the launch's creator: the launching wallet
    function predictToken(address creator, bytes32 salt, string calldata name, string calldata ticker)
        external
        view
        returns (address)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(FoboToken).creationCode, abi.encode(name, ticker)));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), keccak256(abi.encode(creator, salt)), initHash)
                    )
                )
            )
        );
    }
}
