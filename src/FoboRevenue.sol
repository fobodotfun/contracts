// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Owned} from "./base/Owned.sol";
import {IFoboHook} from "./interfaces/IFoboHook.sol";
import {IFoboRevenue} from "./interfaces/IFoboRevenue.sol";
import {Claims} from "./libraries/Claims.sol";

/// @title FoboRevenue
/// @notice Shares out FOBO's protocol revenue: the protocol fee (the team's 0.4% of every swap, 16% of the 2.5% tax) and
///         $FOBO's own creator fee (0.6% of $FOBO's volume, and the 40% of $FOBO's snipe tax other pools burn). The hook
///         credits it here in the swap that paid it (a $FOBO creator fee whose credit failed: later, through
///         FoboHook.claimCreator, with no trader), as PoolManager ERC-6909 claims in the pool's quote (ETH or $FOBO). On a
///         credit the revenue-share partners get `partnerBps` of the gross (protocol fee + creator fee), split between them by
///         their list shares (which add up to 100%); on a swap by a referred trader the referrer gets `referralBps` of the
///         protocol fee (never of the creator fee); the team gets the rest (and every rounding remainder). partnerBps +
///         referralBps <= 100%, so the shares always fit, and a referral never dilutes the partners. Every share is
///         booked (owed) and nobody is paid in the swap: partners, referrers and the team claim whenever they like (pull;
///         anyone can trigger a claim to the account itself, which the site's keeper does). Also the referral registry: a trader's referrer is set by the registrar (the site, which
///         decides who qualifies: sign-in through a link is the trader's consent) for any trader with none, and never
///         changes after that. Only the owner can reset a trader (clearReferrers).
///         Spec: packages/contracts/README.md §5.1.
/// @dev The trader is the swap's tx.origin (the hook passes it), or on a FoboLimitOrders fill the order's owner (never
///      the keeper that filled it): swaps sent by a smart wallet or a bundler credit the bundler's EOA, which normally has
///      no referrer, so they pay no referral. Owner = the Owner Safe (two-step).
contract FoboRevenue is IFoboRevenue, IUnlockCallback, Owned {
    using Claims for IPoolManager;
    using CurrencyLibrary for Currency;

    uint256 public constant BPS = 10_000;
    /// @notice Most revenue-share partners at once (bounds the gas every swap spends crediting them: FoboHook.CREDIT_GAS
    ///         keeps 50% headroom over the worst credit with this many, ~226k cold).
    uint256 public constant MAX_PARTNERS = 5;
    /// @notice The referral fee at deploy: 25% of the protocol fee (0.1% of a referred trader's volume). The partner
    ///         fee starts at 0, with no partners.
    uint16 public constant DEFAULT_REFERRAL_BPS = 2_500;
    /// @notice Most entries one registerBy (or clearReferrers) call may hold: the site's registrar binds sign-ups to the
    ///         referrers whose links they came through, up to 200 per transaction, and sends more transactions for more.
    uint256 public constant MAX_REGISTER_BATCH = 200;

    IPoolManager public immutable poolManager;

    // one slot, read on every credit: the hook, both fees and how many partners there are
    /// @notice The FoboHook, the only caller of credit (set once).
    address public hook;
    /// @notice The partners' fee, in bps of the gross (protocol fee + creator fee), split by their list shares
    ///         (setFeePercent). Non-zero only with a non-empty partner list.
    uint16 public partnerBps;
    /// @notice The referrer's fee, in bps of the protocol fee (setFeePercent).
    uint16 public referralBps;
    uint8 public partnerCount;
    /// @notice Gets what the referrer and the partners don't (the Team Safe).
    address public team;
    /// @notice May bind unreferred traders to referrers (registerBy): the site's sign-in is the trader's consent, and the
    ///         site decides who qualifies. Owner-set; address(0) disables it.
    address public registrar;

    Partner[MAX_PARTNERS] internal _partners;
    /// @notice A trader's referrer, address(0) for none. Set once by the registrar; only the owner can reset it.
    mapping(address => address) public referrerOf;
    /// @notice account => currency (address(0) = ETH) => claimable. Backed one to one by this contract's ERC-6909 claims.
    mapping(address => mapping(address => uint256)) public owed;

    constructor(IPoolManager _poolManager, address _owner, address _team) Owned(_owner) {
        if (address(_poolManager) == address(0) || _team == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        team = _team;
        referralBps = DEFAULT_REFERRAL_BPS;
        emit TeamSet(_team);
        emit FeePercentSet(0, DEFAULT_REFERRAL_BPS);
    }

    // =====================================================================================================
    // credit (the hook, in the swap or from claimCreator)
    // =====================================================================================================

    /// @notice Shares out `protocolFee + creatorFee` of `currency`: takes exactly that much of the caller's (the hook's)
    ///         ERC-6909 claims as its operator (a credit that reverts never moved them), books the partners' share
    ///         (partnerBps of the gross, split by their list shares), the referrer's (referralBps of the protocol fee)
    ///         and the team's (the rest). Pays no one: every share is claimed later. Bounded gas (at most MAX_PARTNERS + 2
    ///         balances). Calls only the PoolManager (the claims transfer), never an account.
    /// @param trader the swap's tx.origin, or a FoboLimitOrders fill's order owner (address(0) from FoboHook.claimCreator:
    ///        never referred, registerBy skips a zero trader)
    /// @param protocolFee the protocol fee (referral applies)
    /// @param creatorFee $FOBO's own creator fee (partners only), 0 in every other pool
    function credit(address currency, address trader, uint256 protocolFee, uint256 creatorFee) external {
        if (msg.sender != hook) revert NotHook();
        uint256 gross = protocolFee + creatorFee;
        poolManager.transferFrom(msg.sender, address(this), Currency.wrap(currency).toId(), gross);
        address referrer = referrerOf[trader];
        uint256 toReferrer;
        if (referrer != address(0)) toReferrer = protocolFee * referralBps / BPS;
        uint256 toPartners;
        // partnerBps > 0 only with a non-empty list (setFeePercent / setPartners), whose shares add up to BPS
        uint256 partnerFee = gross * partnerBps / BPS;
        if (partnerFee != 0) {
            uint256 n = partnerCount;
            for (uint256 i; i < n; i++) {
                Partner memory pt = _partners[i];
                uint256 a = partnerFee * pt.bps / BPS;
                if (a == 0) continue;
                owed[pt.account][currency] += a;
                toPartners += a;
                emit PartnerCredited(pt.account, currency, a);
            }
        }
        // >= 0: toReferrer <= protocolFee * referralBps / BPS and toPartners <= gross * partnerBps / BPS, with
        // protocolFee <= gross and partnerBps + referralBps <= BPS (rounding remainders stay here, with the team)
        uint256 toTeam = gross - toReferrer - toPartners;
        if (toTeam != 0) owed[team][currency] += toTeam;
        if (toReferrer != 0) owed[referrer][currency] += toReferrer;
        emit Split(currency, trader, referrer, protocolFee, creatorFee, toReferrer, toPartners, toTeam);
    }

    // =====================================================================================================
    // claims
    // =====================================================================================================

    /// @notice Pays everything `account` is owed in `currency` (address(0) = ETH) to `to`. Anyone can trigger it to pay
    ///         the account itself (the keeper's payouts); only the account can send it elsewhere (a recipient that
    ///         can't take the currency, e.g. a contract rejecting ETH).
    function claim(address account, address currency, address to) external returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        if (to != account && msg.sender != account) revert NotAccount();
        amount = owed[account][currency];
        if (amount == 0) return 0;
        owed[account][currency] = 0;
        poolManager.unlock(abi.encode(currency, to, amount));
        emit RevenueClaimed(account, currency, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address currency, address to, uint256 amount) = abi.decode(data, (address, address, uint256));
        poolManager.redeem(Currency.wrap(currency), to, amount);
        return "";
    }

    // =====================================================================================================
    // referral registry
    // =====================================================================================================

    /// @notice The registrar binds traders to the referrers whose links they signed up through: the site's sign-in is
    ///         the consent, and the site decides who qualifies (it is the only way to get a referrer, for any trader with
    ///         none, whether or not it has traded; pre-launch sign-ups are bound in batches before trading opens). Entries that can't be set are skipped, not reverted, so one bad entry can't fail a batch;
    ///         each emits RegisterSkipped with its reason. At most MAX_REGISTER_BATCH entries.
    /// @return set how many entries were set
    function registerBy(address[] calldata traders, address[] calldata referrers) external returns (uint256 set) {
        if (msg.sender != registrar || msg.sender == address(0)) revert NotRegistrar();
        uint256 n = traders.length;
        if (n != referrers.length) revert LengthMismatch();
        if (n > MAX_REGISTER_BATCH) revert BatchTooLarge();
        for (uint256 i; i < n; i++) {
            (address t, address r) = (traders[i], referrers[i]);
            // a zero trader is no one: binding it would only waste the entry (no swap ever has tx.origin 0). FoboRevenue,
            // the hook and the PoolManager could never claim a referral share: it would be booked and stuck forever
            if (
                t == address(0) || r == address(0) || r == t || r == address(this) || r == hook
                    || r == address(poolManager)
            ) {
                emit RegisterSkipped(t, r, SkipReason.BadReferrer);
            } else if (referrerOf[t] != address(0)) {
                // set earlier in this same batch (transient mark below), or before it
                bool dup;
                assembly ("memory-safe") {
                    dup := tload(t)
                }
                emit RegisterSkipped(t, r, dup ? SkipReason.Duplicate : SkipReason.AlreadyReferred);
            } else {
                referrerOf[t] = r;
                assembly ("memory-safe") {
                    tstore(t, 1)
                }
                emit ReferrerSet(t, r);
                set++;
            }
        }
        // the marks only tell this batch's duplicates apart: clear them so a later call in the same transaction sees
        // AlreadyReferred, not Duplicate
        for (uint256 i; i < n; i++) {
            address t = traders[i];
            assembly ("memory-safe") {
                tstore(t, 0)
            }
        }
    }

    // =====================================================================================================
    // owner
    // =====================================================================================================

    /// @notice The hook that credits revenue. Once (the deploy script sets it right after deploying the hook), and only a
    ///         hook built for this FoboRevenue (its `revenue()` is this contract): a wrong one could never be replaced.
    function setHook(address _hook) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (_hook == address(0)) revert ZeroAddress();
        if (address(IFoboHook(_hook).revenue()) != address(this)) revert BadHook();
        hook = _hook;
        emit HookSet(_hook);
    }

    /// @notice Where the rest goes from now on (what it is already owed stays claimable by the old address).
    function setTeam(address _team) external onlyOwner {
        if (_team == address(0)) revert ZeroAddress();
        if (_team == address(this)) revert SelfAddress();
        team = _team;
        emit TeamSet(_team);
    }

    /// @notice Replaces the whole revenue-share partner list in one call: `recipients[i]` gets `bps[i]` of the partner
    ///         fee (partnerBps of the gross). Either empty (only while partnerBps is 0: set setFeePercent(0, x) first), or
    ///         at most MAX_PARTNERS, adding up to exactly BPS (100%), with no zero address, duplicate, zero share,
    ///         FoboRevenue, hook or PoolManager (none could claim). Applies to swaps from now on (what anyone is owed
    ///         stays owed).
    function setPartners(address[] calldata recipients, uint16[] calldata bps) external onlyOwner {
        uint256 n = recipients.length;
        if (n != bps.length) revert LengthMismatch();
        if (n > MAX_PARTNERS) revert TooManyPartners();
        if (n == 0 && partnerBps != 0) revert PartnerFeeActive();
        uint256 total;
        for (uint256 i; i < n; i++) {
            address a = recipients[i];
            if (a == address(0)) revert ZeroAddress();
            if (a == address(this)) revert SelfAddress();
            if (a == hook || a == address(poolManager)) revert BadPartner();
            if (bps[i] == 0) revert ZeroShare();
            for (uint256 j; j < i; j++) {
                if (recipients[j] == a) revert DuplicatePartner();
            }
            total += bps[i];
            _partners[i] = Partner(a, bps[i]);
        }
        if (n != 0 && total != BPS) revert BadShareTotal();
        for (uint256 i = n; i < partnerCount; i++) {
            delete _partners[i];
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        partnerCount = uint8(n); // n <= MAX_PARTNERS
        emit PartnersSet(recipients, bps);
    }

    /// @notice Both fees: the partners get `_partnerBps` of the gross (split by their list shares), a referred trader's
    ///         referrer `_referralBps` of the protocol fee, the team the rest. They add up to at most BPS; a partner fee
    ///         needs a partner list (setPartners first). Applies to swaps from now on.
    function setFeePercent(uint16 _partnerBps, uint16 _referralBps) external onlyOwner {
        if (uint256(_partnerBps) + _referralBps > BPS) revert FeeTooHigh();
        if (_partnerBps != 0 && partnerCount == 0) revert NoPartners();
        partnerBps = _partnerBps;
        referralBps = _referralBps;
        emit FeePercentSet(_partnerBps, _referralBps);
    }

    /// @notice The registrar (registerBy): the site's relayer key. address(0) disables it; set a new one to rotate.
    function setRegistrar(address _registrar) external onlyOwner {
        if (_registrar == address(this)) revert SelfAddress();
        registrar = _registrar;
        emit RegistrarSet(_registrar);
    }

    /// @notice Resets each trader to unreferred, so the right referrer can be bound again (by the
    ///         registrar). The recovery from a compromised registrar: rotate it (setRegistrar), then clear the bindings it
    ///         made. Nothing already credited moves. ReferrerCleared only for a trader that had a referrer (one with none
    ///         is skipped). At most MAX_REGISTER_BATCH traders.
    function clearReferrers(address[] calldata traders) external onlyOwner {
        uint256 n = traders.length;
        if (n > MAX_REGISTER_BATCH) revert BatchTooLarge();
        for (uint256 i; i < n; i++) {
            address t = traders[i];
            if (referrerOf[t] == address(0)) continue;
            delete referrerOf[t];
            emit ReferrerCleared(t);
        }
    }

    // =====================================================================================================
    // views
    // =====================================================================================================

    /// @notice The revenue-share partners and their shares (bps of the partner fee, adding up to BPS), as setPartners
    ///         last set them.
    function partners() external view returns (address[] memory recipients, uint16[] memory bps) {
        uint256 n = partnerCount;
        recipients = new address[](n);
        bps = new uint16[](n);
        for (uint256 i; i < n; i++) {
            recipients[i] = _partners[i].account;
            bps[i] = _partners[i].bps;
        }
    }
}
