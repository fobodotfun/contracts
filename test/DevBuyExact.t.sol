// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {StartTick} from "../script/StartTick.sol";
import {FoboBase} from "./Fobo.t.sol";
import {MockQuote} from "./QuoteDecimals.t.sol";

/// The site quotes a creator's dev buy exactly (devBuyCostExact in packages/core: the fresh pool's tranches, Uniswap v4's
/// exact-out swap and the hook's base tax, in bigint) and sends exactly that as LaunchParams.devBuyMaxCost, with no
/// buffer. This proves its numbers are the factory's `quoteOwed` to the raw unit: every pair kind (ETH, $FOBO, a 6-decimal
/// quote), three start ticks across each band, dev buys from 1 raw unit to 5% of supply. At each, a bound one unit under
/// the quote reverts DevBuyTooExpensive and the quote itself goes through, paid with exactly it: msg.value = fee + cost on
/// an ETH pair (no refund left), an allowance of exactly cost on a token pair (used up). The constants are printed by
/// `pnpm --filter core dev-buy:table` (packages/core/scripts/dev-buy-table.ts); src/devBuy.test.ts asserts the same.
contract DevBuyExactTest is FoboBase {
    using PoolIdLibrary for *;

    uint256 constant N_TICKS = 9;
    uint256 constant N_SIZES = 6;

    /// The start ticks, in the order of _costs: ETH (FOBO_TICK ± BAND_HALF), $FOBO (around 0: tokens per $FOBO at the
    /// $10k start with $FOBO itself at $10k), a 6-decimal $1 quote (StartTick.forQuote(1e8, 6) ± BAND_HALF)
    function _ticks() internal pure returns (int24[N_TICKS] memory) {
        return [int24(186_840), 193_800, 200_760, -6_000, 0, 6_000, 384_540, 391_500, 398_460];
    }

    function _sizes() internal pure returns (uint256[N_SIZES] memory) {
        return [uint256(1), 1e18, 7e18, 1_000_000e18, 12_345_678e18, 50_000_000e18];
    }

    /// devBuyCostExact(size, tick), raw quote units
    function _costs() internal pure returns (uint256[N_SIZES][N_TICKS] memory c) {
        c[0] = [uint256(2), 7889381849, 55225673883, 7911987503923605, 100961001980448890, 460213939811556279];
        c[1] = [uint256(2), 3933590348, 27535132904, 3944861368503317, 50338446090890760, 229459436267942916];
        c[2] = [uint256(2), 1961260505, 13728823765, 1966880156091325, 25098395470918730, 114406862412645329];
        c[3] = [
            uint256(3),
            1868783739996097511,
            13081486404226735860,
            1874138415844843520742034,
            23914963493043151651191302,
            109012384521641731455184829
        ];
        c[4] = [
            uint256(3),
            1025641028571428581,
            7179487323076925950,
            1028579825141429725956787,
            13125203965710962094059459,
            59829059829059829059287076
        ];
        c[5] = [
            uint256(2),
            562900616574957299,
            3940304383572776428,
            564513510711559993647987,
            7203480749265132241305852,
            32835869206389072963641272
        ];
        c[6] = [uint256(2), 21, 144, 20545324, 262168808, 1195052911];
        c[7] = [uint256(2), 11, 72, 10243754, 130715526, 595844983];
        c[8] = [uint256(2), 6, 36, 5107464, 65173843, 297084122];
    }

    function test_devBuyCostMatchesTheSiteExactly() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        _fundFobo(alice, 5 ether);
        MockQuote usd = new MockQuote(6, 0);
        int24 mid = StartTick.forQuote(1e8, 6);
        factory.setQuoteBand(address(usd), mid - BAND_HALF, mid + BAND_HALF);
        factory.setQuoteAllowed(address(usd), true);
        usd.transfer(alice, 1_000_000e6);
        // the $FOBO pair's band follows the $FOBO pool's start-of-block tick (FoboFactory._startRange)
        int24 ref = hook.startOfBlockTick(foboKey.toId());

        int24[N_TICKS] memory ticks = _ticks();
        uint256[N_SIZES] memory sizes = _sizes();
        uint256[N_SIZES][N_TICKS] memory costs = _costs();
        for (uint256 t; t < N_TICKS; t++) {
            address quote = t < 3 ? address(0) : t < 6 ? fobo : address(usd);
            if (quote == fobo) {
                assertGe(ticks[t], FOBO_TICK - BAND_HALF - ref, "$FOBO tick in its band");
                assertLe(ticks[t], FOBO_TICK + BAND_HALF - ref, "$FOBO tick in its band");
            }
            for (uint256 s; s < N_SIZES; s++) {
                _launchExact(alice, quote, ticks[t], sizes[s], costs[t][s]);
            }
        }
    }

    /// `creator` launches on `quote` at `tick` buying `tokens`: a bound of cost - 1 reverts, cost goes through paid
    /// with exactly cost. State is rolled back after.
    function _launchExact(address creator, address quote, int24 tick, uint256 tokens, uint256 cost) internal {
        uint256 snap = vm.snapshotState();
        bytes32 salt = _saltAfter(creator, quote, "Exact", "EXACT");
        IFoboFactory.LaunchParams memory lp = _signedBy(
            startSignerKey, creator, quote, "Exact", "EXACT", salt, tokens, tick, vm.getBlockTimestamp() + 1 hours
        );
        bool isEth = quote == address(0);
        uint256 value = isEth ? FEE + cost : FEE;
        if (!isEth) {
            vm.prank(creator);
            FoboToken(quote).approve(address(factory), cost);
        }

        lp.devBuyMaxCost = cost - 1;
        vm.prank(creator);
        vm.expectRevert(IFoboFactory.DevBuyTooExpensive.selector);
        factory.launch{value: value}(lp);

        lp.devBuyMaxCost = cost;
        uint256 factoryEth = address(factory).balance;
        vm.prank(creator);
        (address token,) = factory.launch{value: value}(lp);
        assertEq(FoboToken(token).balanceOf(creator), tokens, "bought exactly the tokens");
        assertEq(address(factory).balance, factoryEth, "nothing left in the factory");
        if (!isEth) assertEq(FoboToken(quote).allowance(creator, address(factory)), 0, "pulled exactly the quote");
        vm.revertToState(snap);
    }
}
