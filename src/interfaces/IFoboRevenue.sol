// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice FoboRevenue: shares out the protocol fee (and $FOBO's own creator fee) between revenue-share partners
///         (partnerBps of the gross), referrers (referralBps of the protocol fee) and the team (the rest), and keeps the referral registry. Spec: packages/contracts/README.md §5.1.
interface IFoboRevenue {
    struct Partner {
        address account;
        uint16 bps;
    }

    /// @dev Why registerBy skipped an entry: a zero trader, or a referrer that is zero, the trader itself or one that could
    ///      never claim (FoboRevenue, the hook, the PoolManager); the trader already had a referrer before this batch; it
    ///      was already set earlier in this batch
    enum SkipReason {
        BadReferrer,
        AlreadyReferred,
        Duplicate
    }

    /// @notice One per credit (one per taxed swap after the snipe window and per snipe-window swap of $FOBO's pool, and
    ///         one per FoboHook.claimCreator of $FOBO's pool for a fee a swap's credit failed on, trader zero): who
    ///         traded, its referrer (zero: none), what was shared out and where it went. toReferrer + toPartners + toTeam
    ///         == protocolFee + creatorFee.
    /// @param creatorFee $FOBO's own creator fee (only in the $FOBO pool; no referral on it)
    event Split(
        address indexed currency,
        address indexed trader,
        address indexed referrer,
        uint256 protocolFee,
        uint256 creatorFee,
        uint256 toReferrer,
        uint256 toPartners,
        uint256 toTeam
    );
    /// @notice A partner's share of one credit (one per partner with a non-zero share, before its Split).
    event PartnerCredited(address indexed account, address indexed currency, uint256 amount);
    /// @notice Named apart from FoboHook's Claimed so the two never share a topic. `account` is who was owed (the
    ///         recipient is the claim's `to`: the account unless it sent it elsewhere).
    event RevenueClaimed(address indexed account, address indexed currency, uint256 amount);
    /// @notice A registerBy entry that was not set, and why.
    event RegisterSkipped(address indexed trader, address indexed referrer, SkipReason reason);
    /// @notice The owner reset a trader to unreferred (clearReferrers: the recovery from a bad registrar). Only for a
    ///         trader that had a referrer.
    event ReferrerCleared(address indexed trader);
    event ReferrerSet(address indexed trader, address indexed referrer);
    /// @notice The partner list was replaced by this one (empty: no partners), shares in bps of the partner fee (adding
    ///         up to 10_000).
    event PartnersSet(address[] recipients, uint16[] bps);
    /// @notice Both fees, from now on: the partners' (bps of the gross) and the referrer's (bps of the protocol fee). Also
    ///         from the constructor, for the defaults (0, DEFAULT_REFERRAL_BPS).
    event FeePercentSet(uint16 partnerBps, uint16 referralBps);
    event TeamSet(address indexed team);
    event HookSet(address indexed hook);
    event RegistrarSet(address indexed registrar);

    error NotHook();
    error NotPoolManager();
    error HookAlreadySet();
    error BadHook();
    error ZeroAddress();
    error TooManyPartners();
    error BadShareTotal();
    error PartnerFeeActive();
    error NoPartners();
    error FeeTooHigh();
    error BadPartner();
    error LengthMismatch();
    error ZeroShare();
    error DuplicatePartner();
    error SelfAddress();
    error NotRegistrar();
    error BatchTooLarge();
    error NotAccount();

    /// @notice Shares out `protocolFee + creatorFee` of `currency`, taking exactly that much of the hook's ERC-6909 claims
    ///         (as the hook's ERC-6909 operator), and books every share (owed: nobody is paid in the swap). Only the hook:
    ///         inside the swap, or from claimCreator for a $FOBO creator fee a swap's credit failed on (no trader).
    /// @param currency the pool's quote (address(0) = ETH)
    /// @param trader the swap's tx.origin, or a FoboLimitOrders fill's order owner (address(0) from claimCreator: never
    ///        referred, registerBy skips a zero trader)
    /// @param protocolFee the protocol fee (referral applies)
    /// @param creatorFee $FOBO's own creator fee (partners only), 0 in every other pool
    function credit(address currency, address trader, uint256 protocolFee, uint256 creatorFee) external;

    /// @notice Pays everything `account` is owed in `currency` to `to`. Anyone can trigger it with `to` = `account`;
    ///         only the account can pick another `to`.
    function claim(address account, address currency, address to) external returns (uint256 amount);

    /// @notice The registrar binds unreferred traders to referrers, in batches of at most MAX_REGISTER_BATCH.
    /// @return set how many entries were set
    function registerBy(address[] calldata traders, address[] calldata referrers) external returns (uint256 set);

    function setHook(address hook) external;
    function setTeam(address team) external;
    function setPartners(address[] calldata recipients, uint16[] calldata bps) external;
    function setFeePercent(uint16 partnerBps, uint16 referralBps) external;
    function setRegistrar(address registrar) external;
    function clearReferrers(address[] calldata traders) external;

    function hook() external view returns (address);
    function team() external view returns (address);
    function registrar() external view returns (address);
    function partnerBps() external view returns (uint16);
    function referralBps() external view returns (uint16);
    function partnerCount() external view returns (uint8);
    function referrerOf(address trader) external view returns (address);
    function owed(address account, address currency) external view returns (uint256);
    function partners() external view returns (address[] memory recipients, uint16[] memory bps);
}
