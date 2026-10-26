// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool as V4Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {N_TRANCHES} from "../libraries/Curve.sol";
import {FloorMath} from "../libraries/FloorMath.sol";
import {Ticks} from "../libraries/Ticks.sol";
import {IFoboToken} from "../interfaces/IFoboToken.sol";
import {HookStorage} from "./HookStorage.sol";

/// @title HookFloor
/// @notice The floor: a single-tick band of quote under the price that can buy back every circulating token. Once per
///         block, before the block's first swap and on the state the block started with, it moves up as far as the floor
///         money allows (a raise), buys back and burns tokens with money the band can't use under the price (a
///         buyback), or sends an empty pool's floor money to the burn (a drain). It never moves down.
abstract contract HookFloor is HookStorage {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @notice Raise entry used from beforeSwap (via try/catch). Only callable by the hook itself.
    function raiseFromHook(PoolKey calldata key) external {
        if (msg.sender != address(this)) revert NotSelf();
        _raise(key);
    }

    /// @notice Applies the pot to the floor now. Anyone can call it; trading normally does this already (a block's first
    ///         swap settles the block: a poke after it does nothing until the next block).
    function poke(PoolKey calldata key) external {
        if (pools[key.toId()].token == address(0)) revert UnknownPool();
        poolManager.unlock(abi.encode(ACTION_POKE, abi.encode(key)));
    }

    struct Ctx {
        uint160 sCur;
        int24 cur;
        uint256 circulating;
        int24 tLow;
        int24 tHigh;
        uint256 vested; // snipe tax vested since the last raise (moved into pot by this raise)
        // the most quote over the price (pot, vested snipe tax, band, tranche 0's curve) the circulating tokens can
        // carry: their worth at the highest price a buyback may lift to (_setCap). More would only wait under the price
        // for whoever buys past the next tranche's start (_rebuild and _planDrain send it to the burn)
        uint256 cap;
        bool go;
        // the floor money the circulating tokens can't carry leaves (_drain) without a raise: an empty pool's (all of it,
        // circulating < EMPTY_CIRCULATING), or one beyond `cap` that can't move this block. The band keeps `keep`, the
        // pot loses `potOut`, `swept` of the snipe pot leaves with them
        bool drain;
        uint128 keep;
        uint256 potOut;
        uint256 swept;
        // computed once per raise, read by every step of the search:
        uint160 sF; // sqrt price at tickF
        uint256 qBase; // the pot, the vested snipe tax and the old band's quote
        uint256 first; // first live tranche (merged + 1)
        uint256 last; // tranches first..last-1 may be passed by this raise (reached by the price, within MAX_PASS)
        int24[N_TRANCHES] start; // start tick of each passable tranche
        uint160[N_TRANCHES] sStart; // and its sqrt price
        uint256[N_TRANCHES] absorbKept; // tokens a passable tranche takes back above the price if it isn't passed
        uint256 absorbFixed; // the same, summed over the reached tranches this raise can't pass
        uint128 lbMax; // most liquidity the band may hold: v4's per-tick cap less everything placed at MIN_TICK
        // buyback: the backing can carry the floor above the price's cap. The floor goes to tBuyMin + 60..tBuy and the
        // price is lifted to two spacings over it
        bool buy;
        int24 tBuy;
        int24 tBuyMin;
    }

    /// @dev Can the floor move up at least one tick right now? View-only; _raise acts on it.
    function _plan(Pool storage p, PoolId id) internal view returns (Ctx memory c) {
        // no pot gate: the old band's quote, the vested snipe tax and the quote freed above can fund a climb too
        (c.sCur, c.cur,,) = poolManager.getSlot0(id);
        int24 tickF = p.tickF;
        c.circulating = _circulating(p, c.sCur);
        if (c.circulating < EMPTY_CIRCULATING) {
            // nothing an empty pool holds backs anyone (cap 0): the snipe pot leaves too, vested or not. Left vesting it
            // would only go to whoever buys next (E12)
            c.swept = p.snipePot - p.snipeReleased;
            _planDrain(p, c);
            return c;
        }
        // price past the band: nothing to do. Inside it (being eaten), only a buyback may move the floor: it burns the
        // tokens the band bought back and lifts the price over the new band
        if (c.cur >= tickF + SPACING) return c;
        // lowest candidate: one full spacing above both the start-of-block tick and the current tick
        int24 base = c.cur > p.refTick ? c.cur : p.refTick;
        c.tLow = Ticks.alignDown(base) + 2 * SPACING;
        // pass cap: the floor stops at the start of the (MAX_PASS + 1)-th live tranche; the next raise continues
        c.first = uint256(p.merged) + 1;
        c.last = c.first + MAX_PASS;
        if (c.last < N_TRANCHES) {
            int24 capLow = _start(p, c.last);
            if (c.tLow < capLow) c.tLow = capLow;
        } else {
            c.last = N_TRANCHES;
        }
        c.tHigh = tickF - SPACING;
        // buyback candidates: at least one spacing over the price, never lifting it past the next live tranche's start
        // (only while none is reached, so tranche 0 is all there is between the old and the new price), and never while
        // the price is above where the block started: a buyback only ever lifts a price no one has pumped this block
        c.tBuy = Ticks.alignDown(c.cur) + SPACING;
        if (c.tBuy > c.tHigh) c.tBuy = c.tHigh;
        int24 nextStart = c.first < N_TRANCHES ? _start(p, c.first) : MIN_TICK;
        c.tBuyMin = nextStart + 2 * SPACING; // every tranche merged: MIN_TICK + 120, the lowest a lifted price can go
        // every search below keeps a one-spacing margin: it lands one spacing under the tightest floor its rounding
        // allows, so the rebuilt positions never miss C by a wei (FloorBroken)
        bool canBuy = c.tBuyMin <= c.tBuy - SPACING && nextStart <= c.cur && c.cur >= p.refTick;
        c.sF = TickMath.getSqrtPriceAtTick(tickF);
        uint256 band = FloorMath.quote(
            c.sCur > c.sF ? c.sCur : c.sF, TickMath.getSqrtPriceAtTick(tickF + SPACING), p.liqBand, false
        );
        c.vested = _vested(p);
        c.qBase = p.pot + c.vested + band;
        if (c.tLow > c.tHigh - SPACING && !canBuy) {
            _drainIfOver(p, c);
            return c;
        }
        // every tranche's lower tick is MIN_TICK, and the band's ticks hold at most those same positions' upper ends: a
        // band within this always fits v4's per-tick cap (a floor that can't use all its money leaves the rest in pot)
        (uint128 placed,) = poolManager.getTickLiquidity(id, MIN_TICK);
        c.lbMax = V4Pool.tickSpacingToMaxLiquidityPerTick(SPACING) - placed;
        // Only tranches the price has reached (cur < start) can be passed: every candidate t is above the current tick.
        // Starts only rise with i, so the first one not reached ends the reached ones.
        uint256 i = c.first;
        for (; i < N_TRANCHES; i++) {
            int24 s = _start(p, i);
            if (c.cur >= s) break;
            uint160 sS = TickMath.getSqrtPriceAtTick(s);
            uint256 kept = FloorMath.token(c.sCur, sS, p.liqs[i], false);
            if (i < c.last) {
                c.start[i] = s;
                c.sStart[i] = sS;
                c.absorbKept[i] = kept;
            } else {
                c.absorbFixed += kept;
            }
        }
        if (i < c.last) c.last = i;
        if (canBuy && _okBuy(p, c, c.tBuy - SPACING)) {
            c.buy = true;
            c.go = true;
        } else if (c.tLow <= c.tHigh - SPACING) {
            c.go = _ok(p, c, c.tHigh - SPACING);
        }
        if (!c.go) _drainIfOver(p, c);
    }

    /// @dev Ctx.cap: the circulating tokens' worth at the highest price a buyback may lift to, the next live tranche's
    ///      start (tBuyMin - 120, _plan), unless the price is already past it. Only an almost empty pool (a few tokens
    ///      left after an exit) gets near it: a real holder base is worth far more there than the floor holds.
    function _setCap(Ctx memory c) internal pure {
        int24 s = c.tBuyMin - 2 * SPACING;
        uint160 sCap = s <= c.cur ? TickMath.getSqrtPriceAtTick(s) : c.sCur;
        c.cap = FullMath.mulDiv(FullMath.mulDiv(c.circulating, FixedPoint96.Q96, sCap), FixedPoint96.Q96, sCap);
    }

    /// @dev A floor that can't move this block but holds more than the holders can carry (tranche 0's quote over the
    ///      price counted: they sell into it first) drains the rest instead (_planDrain).
    function _drainIfOver(Pool storage p, Ctx memory c) internal view {
        _setCap(c);
        if (c.qBase + FloorMath.quote(c.sCur, c.sF, p.liqs[0], true) > c.cap) _planDrain(p, c);
    }

    /// @dev Floor money beyond what the circulating tokens can carry (_plan's c.cap; an empty pool: all of it) leaves for
    ///      the burn (_drain) without a raise: the band is cut to _bandMax (never below what absorbs every circulating
    ///      token tranche 0 doesn't, so the invariant still holds and the dust can still sell), then the pot and then the
    ///      vested snipe tax keep what that leaves of c.cap. The rest leaves (an empty pool's unvested snipe tax too,
    ///      c.swept), once it is more than 1/DRAIN_SLACK of c.cap (an empty pool's: anything).
    function _planDrain(Pool storage p, Ctx memory c) internal view {
        c.drain = true;
        c.keep = p.liqBand;
        uint160 sF = TickMath.getSqrtPriceAtTick(p.tickF);
        uint160 sF1 = TickMath.getSqrtPriceAtTick(p.tickF + SPACING);
        uint160 sLow = c.sCur > sF ? c.sCur : sF;
        uint256 band = FloorMath.quote(sLow, sF1, c.keep, true);
        (uint256 lMax, uint256 room) = _bandMax(c, c.sCur, sLow, sF1, p.liqs[0], band);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (lMax < c.keep) c.keep = uint128(lMax); // lMax < keep, a uint128
        // cut or not, the band takes `band` of the room or all of it (a cut band's quote was more than the room)
        room = room > band ? room - band : 0;
        uint256 pot = p.pot;
        if (pot > room) c.potOut = pot - room;
        room -= pot - c.potOut;
        if (c.vested > room) (c.swept, c.vested) = (c.swept + c.vested - room, room);
        // the snipe tax and pot that leave, and the band's quote above `keep` (both rounded up, so 0 if it isn't cut)
        c.go = c.swept + c.potOut + band - FloorMath.quote(sLow, sF1, c.keep, true) > c.cap / DRAIN_SLACK;
    }

    /// @dev Most liquidity a band over [sA, sB] may hold: what c.cap buys after the quote tranche 0 (liquidity `l0`) holds
    ///      between the price sP and sA, which the circulating tokens sell into first, but never less than what absorbs
    ///      every circulating token that curve doesn't (the invariant; rounds against itself). No limit (the uint256 max)
    ///      while the band's quote `q` fits: c.cap can be astronomically large, so its liquidity is only computed when
    ///      it is below a real amount. Also returns the quote c.cap leaves after the curve, for the band and the pot.
    function _bandMax(Ctx memory c, uint160 sP, uint160 sA, uint160 sB, uint128 l0, uint256 q)
        internal
        pure
        returns (uint256 lMax, uint256 room)
    {
        uint256 qc = FloorMath.quote(sP, sA, l0, true);
        room = c.cap > qc ? c.cap - qc : 0;
        if (q <= room) return (type(uint256).max, room);
        lMax = FloorMath.liquidityForQuote(sA, sB, room);
        uint256 tc = FloorMath.token(sP, sA, l0, false);
        if (c.circulating > tc) {
            uint256 need = uint256(FloorMath.liquidityForToken(sA, sB, c.circulating - tc)) + 1;
            if (need > lMax) lMax = need;
        }
    }

    /// @dev Snipe tax vested since the last release: snipePot x min(elapsed, SNIPE_VEST) / SNIPE_VEST - snipeReleased,
    ///      or 0 while that is below what has left already: a drain releases the whole snipe pot at once (_plan), so tax
    ///      paid after it vests only once the schedule passes what left, still all of it by SNIPE_VEST. Never reverts:
    ///      _plan runs outside the raise's try/catch, so a revert here would block every swap.
    function _vested(Pool storage p) internal view returns (uint256) {
        uint256 e = block.timestamp - uint256(p.launchedAt);
        if (e > SNIPE_VEST) e = SNIPE_VEST;
        uint256 v = uint256(p.snipePot) * e / SNIPE_VEST;
        uint256 r = p.snipeReleased;
        return v > r ? v - r : 0;
    }

    function _raise(PoolKey memory key) internal {
        PoolId id = key.toId();
        Pool storage p = pools[id];
        uint256 bn = _blockNumber();
        if (p.lastRaiseBlock == bn) return;
        Ctx memory c = _plan(p, id);
        if (!c.go) return;
        // this block's raise (or drain): a revert below rolls it back with everything else. A block number: < 2^64
        // forge-lint: disable-next-line(unsafe-typecast)
        p.lastRaiseBlock = uint64(bn);
        if (c.drain) return _drain(key, p, c);
        // the vested snipe tax joins the pot; what the holders can't carry leaves in the rebuild (c.cap)
        p.pot += c.vested;
        p.snipeReleased += c.vested.toUint128();
        // binary search for the lowest t (highest floor) that still absorbs everything; hi always satisfies the check.
        // The floor goes one spacing under it (the margin, see _plan)
        int256 lo = int256((c.buy ? c.tBuyMin : c.tLow) / SPACING);
        int256 hi = int256((c.buy ? c.tBuy : c.tHigh) / SPACING) - 1;
        while (lo < hi) {
            int256 mid = (lo + hi) >> 1; // arithmetic shift = floor division, also for negatives
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 m = int24(mid * SPACING); // lo <= mid <= hi: between two int24 ticks
            if (c.buy ? _okBuy(p, c, m) : _ok(p, c, m)) hi = mid;
            else lo = mid + 1;
        }
        int24 t = int24((hi + 1) * SPACING);
        _setCap(c);
        (uint256 bandQuote, uint256 burned) = _rebuild(key, p, t, c);
        // re-check against what the positions actually hold now
        (uint160 sNow,,,) = poolManager.getSlot0(id);
        if (_absorbNow(p, sNow) < _circulating(p, sNow)) revert FloorBroken();
        if (c.buy) emit BoughtBack(id, burned, sNow);
        emit FloorRaised(id, t, TickMath.getSqrtPriceAtTick(t + SPACING), bandQuote, c.circulating);
    }

    /// @dev Floor money the circulating tokens can't carry (_planDrain) leaves for the burn: `swept` of the snipe pot (the
    ///      rest of what vested joins the pot), `potOut` of the pot and the band's liquidity above `keep`. Tokens that
    ///      liquidity held (a band the price is inside) join the dust reserve, so circulating doesn't change. No price
    ///      impact: only the band moves, and never below what absorbs every circulating token.
    function _drain(PoolKey memory key, Pool storage p, Ctx memory c) internal {
        PoolId id = key.toId();
        uint256 amount = c.swept + c.potOut;
        p.snipeReleased += (c.vested + c.swept).toUint128();
        p.pot = p.pot + c.vested - c.potOut;
        if (c.keep < p.liqBand) {
            BalanceDelta d = _modify(key, p.tickF, p.tickF + SPACING, -int256(uint256(p.liqBand - c.keep)), SALT_BAND);
            p.liqBand = c.keep;
            // removing liquidity only ever pays out
            uint256 q = uint256(int256(d.amount0()));
            uint256 t = uint256(int256(d.amount1()));
            if (q != 0) poolManager.mint(address(this), key.currency0.toId(), q);
            if (t != 0) {
                poolManager.mint(address(this), key.currency1.toId(), t);
                p.reserve += t;
            }
            amount += q;
            // every token left can still sell into what remains of the band
            if (_absorbNow(p, c.sCur) < c.circulating) revert FloorBroken();
        }
        if (amount != 0) emit FloorSwept(id, amount, _burnShare(p, id, key.currency0, amount));
    }

    /// @dev Would a band at [t, t+60] (funded by the pot, the old band and the quote freed above t) plus the curve
    ///      between the price and t absorb every circulating token? Rounds against itself. Tranche 0 is cut from tickF
    ///      to t, and every live tranche starting above t is merged into it: their liquidity ends up in [MIN_TICK, t]
    ///      and their quote in [t, start] moves into the band. t is always above the current tick. (_okBuy is the buyback
    ///      version.)
    function _ok(Pool storage p, Ctx memory c, int24 t) internal view returns (bool) {
        uint160 sT = TickMath.getSqrtPriceAtTick(t);
        uint160 sT1 = TickMath.getSqrtPriceAtTick(t + SPACING);
        uint128 lCut = p.liqs[0];
        uint256 q = c.qBase + FloorMath.quote(sT, c.sF, lCut, false);
        uint256 absorb = c.absorbFixed;
        for (uint256 i = c.first; i < c.last; i++) {
            if (c.start[i] > t) {
                uint128 l = p.liqs[i];
                q += FloorMath.quote(sT, c.sStart[i], l, false);
                lCut += l;
            } else {
                absorb += c.absorbKept[i];
            }
        }
        absorb += FloorMath.token(c.sCur, sT, lCut, false);
        absorb += FloorMath.token(sT, sT1, _bandLiquidity(sT, sT1, q, c.lbMax), false);
        return absorb >= c.circulating;
    }

    /// @dev Liquidity `q` of quote buys in the band at [sT, sT1], capped at lbMax (_plan).
    function _bandLiquidity(uint160 sT, uint160 sT1, uint256 q, uint128 lbMax) internal pure returns (uint128 lb) {
        lb = FloorMath.liquidityForQuote(sT, sT1, q);
        if (lb > lbMax) lb = lbMax;
    }

    /// @dev Buyback check: would a band at [t, t+60] absorb every circulating token if the price were lifted to t - 120
    ///      first? Tranche 0 then holds quote over [price, t] (taking back token(price, t)); everything else it held
    ///      above the old price, the pot, the vested snipe tax and the old band fund the band. The tokens tranche 0 no
    ///      longer holds below the new price are burned, so circulating doesn't change. Rounds against itself.
    function _okBuy(Pool storage p, Ctx memory c, int24 t) internal view returns (bool) {
        uint160 sP = TickMath.getSqrtPriceAtTick(t - 2 * SPACING);
        uint160 sT = TickMath.getSqrtPriceAtTick(t);
        uint160 sT1 = TickMath.getSqrtPriceAtTick(t + SPACING);
        uint128 l0 = p.liqs[0];
        uint256 q = c.qBase + FloorMath.quote(c.sCur, c.sF, l0, false);
        uint256 kept = FloorMath.quote(sP, sT, l0, true);
        if (kept >= q) return false;
        uint256 absorb = FloorMath.token(sP, sT, l0, false)
            + FloorMath.token(sT, sT1, _bandLiquidity(sT, sT1, q - kept, c.lbMax), false);
        return absorb >= c.circulating;
    }

    /// @dev Tokens the positions take back as the price falls from sCur to the far edge of the band.
    function _absorbNow(Pool storage p, uint160 sCur) internal view returns (uint256 absorb) {
        uint160 sF = TickMath.getSqrtPriceAtTick(p.tickF);
        absorb = FloorMath.token(sCur, sF, p.liqs[0], false)
            + FloorMath.token(sF, TickMath.getSqrtPriceAtTick(p.tickF + SPACING), p.liqBand, false);
        for (uint256 i = uint256(p.merged) + 1; i < N_TRANCHES; i++) {
            uint160 sS = TickMath.getSqrtPriceAtTick(_start(p, i));
            if (sCur >= sS) break; // not reached yet, and starts only rise from here
            absorb += FloorMath.token(sCur, sS, p.liqs[i], false);
        }
    }

    /// @dev Tokens outside this pool's positions and dust reserve. Anything else the hook holds counts as circulating.
    function _circulating(Pool storage p, uint160 sCur) internal view returns (uint256) {
        uint160 sMin = TickMath.getSqrtPriceAtTick(MIN_TICK);
        uint160 sF = TickMath.getSqrtPriceAtTick(p.tickF);
        uint256 held = FloorMath.token(sMin, sCur < sF ? sCur : sF, p.liqs[0], false) + p.reserve;
        for (uint256 i = uint256(p.merged) + 1; i < N_TRANCHES; i++) {
            uint160 sS = TickMath.getSqrtPriceAtTick(_start(p, i));
            held += FloorMath.token(sMin, sCur < sS ? sCur : sS, p.liqs[i], false);
        }
        if (sCur > sF) {
            uint160 sF1 = TickMath.getSqrtPriceAtTick(p.tickF + SPACING);
            held += FloorMath.token(sF, sCur < sF1 ? sCur : sF1, p.liqBand, false);
        }
        uint256 supply = IFoboToken(p.token).totalSupply();
        return supply > held ? supply - held : 0;
    }

    /// @dev Moves tranche 0's top down to t, merging in every live tranche that starts above t (removed, its liquidity
    ///      added to tranche 0's: the same amounts as cutting each to t, but later raises only rebuild tranche 0), and
    ///      puts the freed quote plus the pot into a band at [t, t+60]. Everything touched is above the current tick: no
    ///      price impact, except a buyback (c.buy), which moves the price to t - 120 while tranche 0 and the band are
    ///      out and burns the tokens they no longer need. The band never takes more than c.cap (what the circulating
    ///      tokens can carry); the rest leaves the pot for the burn. Settles exactly the deltas the PoolManager returned,
    ///      against the pot (quote) and the dust reserve or the burn (token).
    function _rebuild(PoolKey memory key, Pool storage p, int24 t, Ctx memory c)
        internal
        returns (uint256 bandQuote, uint256 burned)
    {
        int256 d0;
        int256 d1;
        BalanceDelta d;
        if (p.liqBand != 0) {
            d = _modify(key, p.tickF, p.tickF + SPACING, -int256(uint256(p.liqBand)), SALT_BAND);
            (d0, d1) = (d0 + d.amount0(), d1 + d.amount1());
        }
        uint128 l0 = p.liqs[0];
        uint128 added;
        uint256 i = uint256(p.merged) + 1;
        for (; i < N_TRANCHES; i++) {
            int24 s = _start(p, i);
            if (s <= t) break; // _plan's pass cap keeps this to at most MAX_PASS tranches
            uint128 l = p.liqs[i];
            d = _modify(key, MIN_TICK, s, -int256(uint256(l)), _salt(i));
            (d0, d1) = (d0 + d.amount0(), d1 + d.amount1());
            added += l;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        p.merged = uint8(i - 1); // i <= N_TRANCHES
        d = _modify(key, MIN_TICK, p.tickF, -int256(uint256(l0)), _salt(0));
        (d0, d1) = (d0 + d.amount0(), d1 + d.amount1());
        if (c.buy) {
            // buyback: nothing is placed between the old and the new price now, so lifting the price costs nothing;
            // re-placing tranche 0 under the new price needs fewer tokens and the rest is burned below
            d = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -1,
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(t - 2 * SPACING)
                }),
                ""
            );
            (d0, d1) = (d0 + d.amount0(), d1 + d.amount1());
        }
        // tranche 0 back, now [MIN_TICK, t] with every merged tranche in it. The tokens it holds under the price are paid
        // from what the removals above freed (d1: they and a lift only ever pay out) plus the dust reserve. Their rounding
        // (each removal rounds down, the add up) can cost a few wei more than was freed, so the liquidity is cut to what
        // those can pay: a raise never fails for want of reserve (it would revert every raise after, freezing the floor);
        // an empty reserve only places a few wei of tokens less, which the search's one-spacing margin covers (_raise
        // still re-checks FloorBroken)
        uint128 lNew = l0 + added;
        (uint160 sNow,,,) = poolManager.getSlot0(key.toId());
        {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 have = uint256(d1) + p.reserve; // d1 >= 0, see above
            // rounds down, so it never needs more than `have`
            uint128 lMax = FloorMath.liquidityForToken(TickMath.getSqrtPriceAtTick(MIN_TICK), sNow, have);
            if (lNew > lMax) lNew = lMax;
        }
        d = _modify(key, MIN_TICK, t, int256(uint256(lNew)), _salt(0));
        (d0, d1) = (d0 + d.amount0(), d1 + d.amount1());
        p.liqs[0] = lNew;
        uint160 sT = TickMath.getSqrtPriceAtTick(t);
        uint160 sT1 = TickMath.getSqrtPriceAtTick(t + SPACING);
        // forge-lint: disable-start(unsafe-typecast)
        // d0 and d1 are sums of a few int128 deltas: every cast below is of a non-negative value, by its sign check
        uint256 available = p.pot + (d0 > 0 ? uint256(d0) : 0);
        if (d0 < 0) available -= uint256(-d0);
        uint128 lb = _bandLiquidity(sT, sT1, available, c.lbMax);
        // beyond _bandMax (c.cap less tranche 0's quote over the price) the band's quote would only wait for whoever buys
        // past the next tranche's start: it stays in the pot and leaves below
        (uint256 lCap, uint256 room) = _bandMax(c, sNow, sT, sT1, lNew, available);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (lb > lCap) lb = uint128(lCap); // lCap < lb, a uint128
        d = _modify(key, t, t + SPACING, int256(uint256(lb)), SALT_BAND);
        (d0, d1) = (d0 + d.amount0(), d1 + d.amount1());
        bandQuote = uint256(int256(-d.amount0()));

        // settle: quote against the pot, token rounding against the reserve
        if (d0 < 0) {
            poolManager.burn(address(this), key.currency0.toId(), uint256(-d0));
            p.pot -= uint256(-d0);
        } else if (d0 > 0) {
            poolManager.mint(address(this), key.currency0.toId(), uint256(d0));
            p.pot += uint256(d0);
        }
        if (d1 < 0) {
            poolManager.burn(address(this), key.currency1.toId(), uint256(-d1));
            p.reserve -= uint256(-d1);
        } else if (d1 > 0) {
            if (c.buy) {
                burned = uint256(d1);
                poolManager.take(key.currency1, address(this), burned);
                IFoboToken(p.token).burn(burned);
            } else {
                poolManager.mint(address(this), key.currency1.toId(), uint256(d1));
                p.reserve += uint256(d1);
            }
        }
        // forge-lint: disable-end(unsafe-typecast)
        p.tickF = t;
        p.liqBand = lb;
        // the pot keeps what c.cap leaves after the band; the rest leaves for the burn
        room = room > bandQuote ? room - bandQuote : 0;
        uint256 pot = p.pot;
        if (pot > room) {
            p.pot = room;
            pot -= room;
            PoolId id = key.toId();
            emit FloorSwept(id, pot, _burnShare(p, id, key.currency0, pot));
        }
    }
}
