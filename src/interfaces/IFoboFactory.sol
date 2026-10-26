// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IFoboHook} from "./IFoboHook.sol";
import {IFoboVesting} from "./IFoboVesting.sol";

/// @notice FoboFactory: launches tokens into FoboHook pools. Spec: packages/contracts/README.md.
interface IFoboFactory {
    struct LaunchParams {
        string name;
        string ticker;
        string metadataURI;
        bytes32 salt; // the token is deployed at CREATE2(keccak(creator, salt)) (predictToken); it must sort after the quote
        // the pair: an allowed quote (quotes[quote].allowed; address(0) = ETH). $FOBO itself (the first launch) is ETH
        address quote;
        uint256 devBuyTokens; // creator's initial buy, <= 5% of supply; 0 = none
        // the most the initial buy may cost, in the pair's quote (ETH, $FOBO or another token): the site's quote plus a
        // little slippage
        uint256 devBuyMaxCost;
        // $FOBO (the owner's first launch): the start tick, unsigned. Every later launch: the start tick the start signer
        // signed for (creator, salt, quote, name, ticker), valid until `deadline` (unix seconds). In ticks of
        // tokens per quote
        int24 tickStart;
        uint256 deadline;
        // 65-byte EIP-712 signature of LaunchStart(creator, salt, quote, name, ticker, tickStart, deadline);
        // empty for $FOBO
        bytes signature;
        // lock the dev buy in FoboVesting for the creator, vesting linearly over 1, 3, 6 or 12 months; 0 = no lock (the
        // tokens go to the creator). The creator's choice: not part of the signed start. Needs a dev buy (VestWithoutDevBuy)
        uint8 vestMonths;
    }

    struct QuoteConfig {
        bool allowed;
        // quotes other than ETH and $FOBO: the start band in ticks of raw token units per raw quote unit
        int24 bandLow;
        int24 bandHigh;
        // the quote's ERC-20 decimals (18 for ETH and $FOBO), read by setQuoteAllowed: what its pools are priced in
        uint8 decimals;
    }

    event TokenLaunched(
        address indexed token,
        PoolId indexed poolId,
        address indexed creator,
        address quote,
        int24 tickStart,
        uint256 devBuyTokens,
        string name,
        string ticker,
        string metadataURI
    );
    event ConfigChanged(bytes32 indexed what, uint256 value);
    event QuoteAllowed(address indexed quote, bool allowed);
    event QuoteBandSet(address indexed quote, int24 low, int24 high);

    error NotPoolManager();
    error Paused();
    error HookSet();
    error BadHook();
    error BadTick();
    error BadStartSignature();
    error StartExpired();
    error StartUsed();
    error StartOutOfBand();
    error FeeNotPaid();
    error DevBuyTooBig();
    error DevBuyTooExpensive();
    error DevBuyUnderpaid();
    error BadSalt();
    error BadQuote();
    error NoBand();
    error RefundFailed();
    error FeeTransferFailed();
    error ZeroAddress();
    error VestWithoutDevBuy();

    /// @notice Launch a token. Send the launch fee plus enough ETH for the dev buy; the rest is refunded. On a pair other
    ///         than ETH or $FOBO the dev buy is paid in the quote itself: approve this factory for it first.
    function launch(LaunchParams calldata lp) external payable returns (address token, PoolId poolId);

    /// @notice The EIP-712 digest the start signer signs for a launch.
    function launchStartDigest(
        address creator,
        bytes32 salt,
        address quote,
        string calldata name,
        string calldata ticker,
        int24 tickStart,
        uint256 deadline
    ) external view returns (bytes32);

    /// @notice The start ticks (tokens per quote) a signed launch on this pair may use right now.
    function startTickRange(address quote) external view returns (int24 low, int24 high);

    /// @notice CREATE2 address a launch with these params will deploy the token at (for the front end's salt search).
    /// @param creator the launch's creator: the launching wallet
    function predictToken(address creator, bytes32 salt, string calldata name, string calldata ticker)
        external
        view
        returns (address);

    function setHook(IFoboHook hook) external;
    function setStartSigner(address signer) external;
    function setStartBand(int24 low, int24 high) external;
    function setQuoteAllowed(address quote, bool allowed) external;
    function setQuoteBand(address quote, int24 low, int24 high) external;
    function setLaunchFee(uint256 fee) external;
    function setDevBuyMax(uint256 tokens) external;
    function setTeam(address team) external;
    function setLaunchesPaused(bool paused) external;

    /// @notice Where team balances (and $FOBO's creator fees) are paid.
    function team() external view returns (address);
    function hook() external view returns (IFoboHook);
    /// @notice FoboBurner, which every launch fee is sent to (the hook's, set with it).
    function burner() external view returns (address);
    function fobo() external view returns (address);
    /// @notice FoboVesting, where a launch locks its dev buy when LaunchParams.vestMonths is set (immutable).
    function vesting() external view returns (IFoboVesting);
}
