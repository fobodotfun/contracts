// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {IFoboHook} from "../interfaces/IFoboHook.sol";
import {IFoboRevenue} from "../interfaces/IFoboRevenue.sol";
import {IFoboToken} from "../interfaces/IFoboToken.sol";
import {Blocks} from "../libraries/Blocks.sol";
import {Claims} from "../libraries/Claims.sol";
import {Curve, N_TRANCHES} from "../libraries/Curve.sol";
import {Tax} from "../libraries/Tax.sol";
import {Ticks} from "../libraries/Ticks.sol";

/// @title HookStorage
/// @notice FoboHook's state, constants and the helpers every part shares (the pool key, positions, tranche starts, the
///         start-of-block tick, where burn shares go). FoboHook = HookStorage <- HookFloor <- HookTax <- HookClaims.
abstract contract HookStorage is BaseHook, IFoboHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using Claims for IPoolManager;

    // ---- constants ----
    // internal unless an integrator reads them (RAISE_GAS, CREDIT_GAS): no getters, FoboHook is at the size limit
    int24 internal constant SPACING = Ticks.SPACING;
    int24 internal constant MIN_TICK = Ticks.MIN_TICK;
    /// @dev The snipe window's floor share (60% of its tax) joins the floor linearly over this, from launch: a sniper can't
    ///      sell straight back into a floor his own tax just built (a sim: an instant floor hands a 61 s dumper ~1 ETH more
    ///      of his own tax back). The base 1.5% floor share goes in at once. A price that falls below where the vested
    ///      money could put the floor doesn't strand it: the raise can't place the floor above the price, so each block's
    ///      raise spends what it can't use on a buyback (buys tokens and burns them, lifting the price).
    uint256 internal constant SNIPE_VEST = 10 minutes;
    /// @dev Snipe window split: 60% floor (vesting, snipePot) / 40% bought back and burned as $FOBO (_burnShare: burned
    ///      at once on a $FOBO pair, else to FoboBurner), nothing to the creator. The burn share is what a sniper can never
    ///      get back through the floor his own tokens are backed by (red team E1). In $FOBO's own pool the 40% is its
    ///      creator fee instead, shared out by FoboRevenue in the swap (partners and team).
    uint256 internal constant SNIPE_BURN_PCT = Tax.SNIPE_BURN_PCT;
    /// @dev A pool with less than this circulating (1,000 tokens, a millionth of supply) is empty: every holder sold. Its
    ///      floor money backs no one, so it goes to the burn (_drain) instead of lifting an empty pool or waiting under
    ///      the price for whoever buys next (red team E12).
    uint256 internal constant EMPTY_CIRCULATING = 1_000e18;
    /// @dev A floor that can't move drains what its holders can't carry (Ctx.cap) only once that is more than
    ///      1/DRAIN_SLACK of what they can (_planDrain), and then down to the cap: a pool sitting at it would otherwise
    ///      drain a few wei of every swap's tax each block (~95k gas and a FloorSwept, paid by the block's first swap).
    uint256 internal constant DRAIN_SLACK = 100;
    /// @dev Most tranche starts one raise may pass (each costs a position removal), so a raise's gas is bounded whatever
    ///      the price did. A floor that has more to climb continues in the next block's raise.
    uint256 internal constant MAX_PASS = 2;
    /// @dev Token dust kept out of every position at launch: pays rebuild rounding. A rebuild never takes more than it
    ///      holds (_rebuild cuts tranche 0 to fit), so a spent reserve never fails a raise.
    uint256 internal constant RESERVE = 1e6;
    uint256 internal constant BASE_TAX = Tax.BASE; // 2.5%: 1.5% floor / 0.6% creator / 0.4% protocol (team)
    uint256 internal constant SNIPE_START_TAX = Tax.SNIPE_START; // 90% at second 0, linear to 2.5% at 60 s
    uint256 internal constant SNIPE_SECONDS = Tax.SNIPE_SECONDS;
    /// @dev Gas budget for one raise (worst case measured ~556k: a cold poke passing MAX_PASS tranche starts with every
    ///      tranche reached, test_worstRaise --isolate; a buyback ~502k, test_gas_buyback --isolate; a buyback searching
    ///      the whole tick range ~476k, test_gas_worstBuyback --isolate; an empty pool's drain ~196k). A swap that
    ///      triggers a raise must leave room for it, so wallets' gas estimates include the raise instead of quietly
    ///      skipping it.
    uint256 public constant RAISE_GAS = 700_000;
    /// @dev Gas budget for FoboRevenue.credit (worst case measured ~226k cold: a referred trader with MAX_PARTNERS (5)
    ///      partners and every balance written for the first time; FoboRevenue pays no one in the swap;
    ///      test_gas_creditWorst --isolate, 50% headroom). Reserved like RAISE_GAS, so a wallet's gas estimate never finds the limit where the credit
    ///      quietly fails and the share goes to the team.
    uint256 public constant CREDIT_GAS = 400_000;

    bytes32 internal constant SALT_BAND = bytes32(uint256(3));
    /// @dev Transient: the pool the factory is launching in this transaction (the only one its swaps pay the base rate on)
    bytes32 internal constant LAUNCHING_SLOT = keccak256("fobo.hook.launching");
    uint256 internal constant SALT_TRANCHE0 = 16; // tranche i's position uses salt 16 + i

    uint8 internal constant ACTION_PLACE = 1;
    uint8 internal constant ACTION_POKE = 2;
    uint8 internal constant ACTION_CLAIM = 3;

    address public immutable factory;
    /// @notice Shares out the protocol fee (and $FOBO's own creator fee) in every swap: referrer, partners, team. The
    ///         hook's ERC-6909 operator: it takes each credit's claims itself (only in credit, which only the hook calls,
    ///         exactly the amount the hook passes, from the hook), so a credit that reverts moves nothing
    IFoboRevenue public immutable revenue;
    /// @notice FoboLimitOrders: on its swaps (and only on its swaps) the trader credited is the order's owner, which it
    ///         passes as hookData (_trader), not tx.origin (the keeper that filled it)
    address public immutable limitOrders;
    /// @notice FoboBurner: gets every burn share that isn't already $FOBO (the snipe tax's on other pairs, swept floor
    ///         money) as a transfer of the hook's ERC-6909 claims, and buys $FOBO with it and burns it later
    address public immutable burner;
    /// @notice The block numbers the once-per-block rules key on (lastRaiseBlock, refBlock, startOfBlockTick) are the
    ///         chain's own: ArbSys.arbBlockNumber() on an Arbitrum chain (true: Robinhood Chain, whose block.number is
    ///         Ethereum's), else block.number (libraries/Blocks.sol). Set at deploy from the chain id, never changed.
    bool public immutable isArbitrum;

    struct Pool {
        address token;
        address creator; // address(0) = the team (used for $FOBO itself)
        uint40 launchedAt;
        int24 tickStart;
        int24 tickF; // floor band is [tickF, tickF + 60]; tranche 0 (launch, plus every merged tranche) is [MIN_TICK, tickF]
        int24 refTick; // pool tick at the start of refBlock
        uint64 refBlock; // block numbers: _blockNumber()
        uint64 lastRaiseBlock;
        uint128 snipePot; // the snipe window's floor share, vesting into pot over SNIPE_VEST from launch
        uint128 snipeReleased; // the part of snipePot already moved into pot (or out of the floor: FloorSwept)
        // tranches 1..merged were merged into tranche 0 once the floor passed their start; the rest are still placed at
        // [MIN_TICK, tickStart - topOff] (libraries/Curve.sol)
        uint8 merged;
        uint128 liqBand;
        uint256 pot; // quote waiting for the floor (ERC-6909 claims)
        uint256 creatorOwed; // quote (claims)
        uint256 reserve; // token dust (claims)
        // liqs[0]: tranche 0's liquidity, which grows as tranches merge in; liqs[i > 0]: what tranche i was placed with
        // (live while i > merged, then part of liqs[0])
        uint128[N_TRANCHES] liqs;
    }

    mapping(PoolId => Pool) public pools;
    mapping(Currency => uint256) public teamOwed;
    /// @notice $FOBO, recorded when the factory launches it (the only pool whose creator is the team, address(0))
    address public fobo;

    constructor(
        IPoolManager _poolManager,
        address _factory,
        IFoboRevenue _revenue,
        address _limitOrders,
        address _burner,
        bool _isArbitrum
    ) BaseHook(_poolManager) {
        if (
            address(_poolManager) == address(0) || _factory == address(0) || address(_revenue) == address(0)
                || _limitOrders == address(0) || _burner == address(0)
        ) {
            revert ZeroAddress();
        }
        factory = _factory;
        revenue = _revenue;
        limitOrders = _limitOrders;
        burner = _burner;
        isArbitrum = _isArbitrum;
        _poolManager.setOperator(address(_revenue), true);
    }

    /// @notice The pool key for a pair: `quote` is currency0 (address(0) = ETH), `token` currency1, no LP fee.
    function keyFor(address quote, address token) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(quote),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: SPACING,
            hooks: IHooks(address(this))
        });
    }

    /// @dev Sends `amount` of quote (already held as claims) to the $FOBO buy-and-burn and returns true; or to the team
    ///      and returns false. $FOBO pair: the quote is $FOBO, burned now. Any other pair (ETH, or an owner-allowed ERC-20
    ///      quote such as USDG): the claims go to FoboBurner (an ERC-6909 transfer: nothing leaves the PoolManager and no
    ///      code runs there, so it is safe inside a swap), which buys $FOBO with them and burns it later. $FOBO's own pool
    ///      (its swept floor money; its snipe share never comes here, _collect): the team (buying itself back would only
    ///      move its own price).
    function _burnShare(Pool storage p, PoolId id, Currency quote, uint256 amount) internal returns (bool) {
        if (p.creator == address(0)) {
            teamOwed[quote] += amount;
            return false;
        }
        if (amount != 0) {
            address q = Currency.unwrap(quote);
            if (q == fobo) {
                poolManager.redeem(quote, address(this), amount);
                IFoboToken(q).burn(amount);
                emit FoboBurned(id, amount);
            } else {
                poolManager.transfer(burner, quote.toId(), amount);
            }
        }
        return true;
    }

    /// @dev This block's number, as the once-per-block rules count blocks. Robinhood Chain is an Arbitrum Orbit chain,
    ///      where block.number is Ethereum's (~12 s), so the chain's own block number comes from ArbSys (Blocks).
    ///      isArbitrum is fixed at deploy.
    function _blockNumber() internal view returns (uint256) {
        return Blocks.current(isArbitrum);
    }

    /// @dev Records the pool's tick as this block's reference on its first swap (or poke) of the block.
    ///      Returns the block number (_blockNumber).
    function _refreshRef(Pool storage p, PoolId id) internal returns (uint256 bn) {
        bn = _blockNumber();
        if (p.refBlock != bn) {
            (, int24 tick,,) = poolManager.getSlot0(id);
            p.refTick = tick;
            // forge-lint: disable-next-line(unsafe-typecast)
            p.refBlock = uint64(bn); // a block number: < 2^64
        }
    }

    function _modify(PoolKey memory key, int24 lower, int24 upper, int256 liq, bytes32 salt)
        internal
        returns (BalanceDelta delta)
    {
        if (liq == 0) return delta;
        (delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: salt}),
            ""
        );
    }

    /// @dev Start tick of tranche i (its position's upper tick until it's merged into tranche 0).
    function _start(Pool storage p, uint256 i) internal view returns (int24) {
        (, int24 topOff) = Curve.tranche(i);
        return p.tickStart - topOff;
    }

    function _salt(uint256 i) internal pure returns (bytes32) {
        return bytes32(SALT_TRANCHE0 + i);
    }
}
