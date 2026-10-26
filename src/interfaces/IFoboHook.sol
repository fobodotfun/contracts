// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IFoboRevenue} from "./IFoboRevenue.sol";

/// @notice FoboHook: owns every FOBO pool's liquidity, taxes the quote leg of every swap and keeps the ratcheting floor.
///         Spec: packages/contracts/README.md.
interface IFoboHook {
    /// @param toBurn the snipe tax's $FOBO buy-and-burn share: burned at once on a $FOBO pair (FoboBurned), sent to
    ///        FoboBurner as claims on any other pair. toFloor + toCreator + toTeam + toBurn == the tax
    event TaxPaid(
        PoolId indexed poolId,
        address indexed swapper,
        bool buy,
        uint256 quoteVolume,
        uint256 toFloor,
        uint256 toCreator,
        uint256 toTeam,
        uint256 toBurn
    );
    /// @param sqrtPriceX96 worst-case price if everyone sells: the far edge of the band (tickF + 60)
    event FloorRaised(
        PoolId indexed poolId, int24 tickF, uint160 sqrtPriceX96, uint256 quoteInFloor, uint256 circulating
    );
    /// @notice The block's raise reverted (and rolled back); the swap went through. `reason` is the revert data: empty
    ///         when the raise ran out of its RAISE_GAS, else the error (FloorBroken, a PoolManager error, ...). It still
    ///         counts as the block's raise: the next block retries it
    event RaiseFailed(PoolId indexed poolId, bytes reason);
    /// @notice Floor money no one holds tokens for left the floor: an empty pool's pot, band and snipe pot (vested or
    ///         not), or floor money (pot, vested snipe tax, band) beyond what the circulating tokens can carry: their
    ///         worth at the highest price a buyback may lift to. Quote amount.
    /// @param burn it went to the $FOBO buy-and-burn, like TaxPaid.toBurn (burned at once on a $FOBO pair, else to
    ///        FoboBurner as claims); false: to the team, only in $FOBO's own pool (unlike its snipe share, which is its
    ///        creator fee)
    event FloorSwept(PoolId indexed poolId, uint256 amount, bool burn);
    /// @notice $FOBO burned at once by a $FOBO pair's burn share (its snipe tax's, or its swept floor money): `poolId` is
    ///         the pool it was paid in. Every other pair's burn share goes to FoboBurner, whose BoughtAndBurned logs its
    ///         burns.
    event FoboBurned(PoolId indexed poolId, uint256 foboBurned);
    /// @param burned tokens the spare floor money bought back and burned; sqrtPriceX96 the price it lifted the pool to
    event BoughtBack(PoolId indexed poolId, uint256 burned, uint160 sqrtPriceX96);
    event Claimed(address indexed account, address indexed currency, uint256 amount);
    event CreatorChanged(PoolId indexed poolId, address indexed creator);
    /// @notice FoboRevenue.credit reverted: this swap's protocol fee stayed with the team here (teamOwed; $FOBO's creator
    ///         fee in its creatorOwed, which claimCreator credits to FoboRevenue)
    event CreditFailed(PoolId indexed poolId, uint256 amount);

    error NotFactory();
    error ZeroAddress();
    error NotSelf();
    error NotCreator();
    error UnknownPool();
    error BadOrder();
    error BadTick();
    error PartialFill();
    error FloorBroken();
    error NeedGas();
    error BadTranche();

    /// @notice The pool key for a pair: `quote` is currency0 (address(0) = ETH), `token` currency1, no LP fee.
    function keyFor(address quote, address token) external view returns (PoolKey memory);

    /// @notice Creates the pool and places the launch curve. Factory only; it must have sent the full supply here first.
    /// @param creator address(0) for $FOBO (the team is its creator)
    function createPool(address quote, address token, address creator, int24 tickStart)
        external
        returns (PoolKey memory key);

    /// @notice Ends the launch createPool started: the factory's swaps pay the normal rate everywhere again.
    function endLaunch() external;

    /// @notice Raise entry used from beforeSwap (via try/catch). Only callable by the hook itself.
    function raiseFromHook(PoolKey calldata key) external;

    /// @notice Applies the pot to the floor now. Anyone can call it; trading normally does this already (a block's first
    ///         swap settles the block: a poke after it does nothing until the next block).
    function poke(PoolKey calldata key) external;

    /// @notice Pays a pool's creator balance to `to`. Every creator fee is owed (nobody is paid in a swap) until this
    ///         claims it. Anyone can send it to the creator (the keeper's payouts); only the creator can name another `to`. $FOBO's fees are FOBO's revenue, credited to FoboRevenue in every swap: what a swap
    ///         couldn't credit (CreditFailed) is credited to it here instead (`to` unused), shared out to the partners and
    ///         the team with no referral (reverts if FoboRevenue does: the fees stay owed).
    function claimCreator(PoolKey calldata key, address to) external;

    /// @notice Pays the team what it is owed in `currency`. Anyone can call it.
    function claimTeam(Currency currency) external;

    /// @notice Hands a pool's creator fees to a new address. The current creator only.
    function setCreator(PoolKey calldata key, address creator) external;

    /// @notice Tranche i of the launch curve as placed now: [MIN_TICK, top] with `liquidity`. Reverts BadTranche past the
    ///         last tranche.
    function trancheOf(PoolKey calldata key, uint256 i) external view returns (int24 top, uint128 liquidity);

    /// @notice The floor tick, the worst-case price (Q96 sqrt of token-per-quote at the band's far edge) and circulating supply.
    function floorOf(PoolKey calldata key)
        external
        view
        returns (int24 tickF, uint160 sqrtPriceX96, uint256 circulating);

    /// @notice A pool's tick at the start of this block (what the floor and the start bands measure against).
    function startOfBlockTick(PoolId id) external view returns (int24);

    /// @notice Blocks are counted with ArbSys.arbBlockNumber() (an Arbitrum chain: Robinhood Chain), not block.number.
    ///         Fixed at deploy.
    function isArbitrum() external view returns (bool);

    function factory() external view returns (address);
    /// @notice FoboRevenue, which shares out the protocol fee (and $FOBO's own creator fee) of every swap.
    function revenue() external view returns (IFoboRevenue);
    /// @notice FoboLimitOrders: the one swapper whose hookData names the trader FoboRevenue credits (the order's owner).
    function limitOrders() external view returns (address);
    /// @notice FoboBurner: gets every burn share that isn't already $FOBO, as ERC-6909 claims.
    function burner() external view returns (address);
    function fobo() external view returns (address);
    function teamOwed(Currency currency) external view returns (uint256);
}
