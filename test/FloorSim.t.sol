// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoboBase} from "./Fobo.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {Curve} from "../src/libraries/Curve.sol";

/// Real-contract floor numbers: launch at $10k (ETH $2.6k), trade up to $100k mcap over 24 h with a given amount of
/// churn, then read the floor from the hook. Run: forge test --mc FloorSim -vv
contract FloorSim is FoboBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant ETH_USD = 2600;
    uint256 TARGET = 100_000; // $ mcap

    function test_sim() public {
        _run("1x volume ($100k)  ", 1, 0);
        _run("3x volume ($300k)  ", 3, 0);
        _run("5x volume ($500k)  ", 5, 0);
        _run("10x volume ($1m)   ", 10, 0);
        _run("3x + $2k sniped    ", 3, 2_000);
        _run("5x + $5k sniped    ", 5, 5_000);
    }

    function test_sim500k() public {
        TARGET = 500_000;
        _run("$500k, 1x ($500k)   ", 1, 0);
        _run("$500k, 3x ($1.5m)   ", 3, 0);
        _run("$500k, 5x ($2.5m)   ", 5, 0);
        _run("$500k, 10x ($5m)    ", 10, 0);
    }

    /// A 0.6% floor share = the real 1.5% (FoboHook: 60% of the 2.5% base tax) at 0.4x the churn volume (the pot only
    /// depends on share x volume); volMult10 is x10
    function test_sim_floorShare06() public {
        _run10("0.6%: 1x volume    ", 4, 0);
        _run10("0.6%: 3x volume    ", 12, 0);
        _run10("0.6%: 5x volume    ", 20, 0);
        _run10("0.6%: 10x volume   ", 40, 0);
    }

    function _run(string memory label, uint256 volMult, uint256 snipeUsd) internal {
        _run10(label, volMult * 10, snipeUsd);
    }

    function _run10(string memory label, uint256 volMult10, uint256 snipeUsd) internal {
        uint256 snap = vm.snapshotState();
        _launchFobo();
        address t = _user("trader");
        _approve(t, fobo);
        uint256 vol; // $ volume, gross

        if (snipeUsd != 0) {
            vm.warp(vm.getBlockTimestamp() + 10); // a sniper 10 s in (~42% tax)
            uint256 e = snipeUsd * 1e18 / ETH_USD;
            _swap(t, foboKey, true, -int256(e), e);
            vol += snipeUsd;
        }
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 steps = 144; // every 10 min for 24 h
        uint256 churnUsdPerStep = TARGET * volMult10 / 10 / steps / 2; // each round trip = 2 sides
        for (uint256 i = 1; i <= steps; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            // net buy along a geometric path to TARGET
            uint256 goal = _pathMcap(i, steps);
            uint256 m = _mcap();
            if (goal > m) {
                uint256 eth = _costEth(m, goal) * 100 / 99 + 1;
                _swap(t, foboKey, true, -int256(eth), eth);
                vol += eth * ETH_USD / 1e18;
            }
            // churn: buy then sell the same tokens back
            uint256 ce = churnUsdPerStep * 1e18 / ETH_USD;
            uint256 b0 = FoboToken(fobo).balanceOf(t);
            _swap(t, foboKey, true, -int256(ce), ce);
            uint256 got = FoboToken(fobo).balanceOf(t) - b0;
            BalanceDelta d = _swap(t, foboKey, false, -int256(got), 0);
            vol += ce * ETH_USD / 1e18 + uint256(int256(d.amount0())) * ETH_USD / 1e18;
        }
        uint256 mEnd = _mcap();
        uint256 fEnd = _floorMcap();
        // stop trading; let the floor catch up with what's in the pot (one raise a block, MAX_PASS starts each) by poking hourly
        uint256 hrs;
        uint256 f = fEnd;
        for (; hrs < 200; hrs++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            hook.poke(foboKey);
            uint256 nf = _floorMcap();
            if (nf == f) break;
            f = nf;
        }
        emit log_string(string.concat(
                label,
                " | volume $",
                vm.toString(vol / 1000),
                "k | mcap $",
                vm.toString(mEnd / 1000),
                "k | floor at 24h $",
                vm.toString(fEnd / 1000),
                "k (",
                vm.toString(fEnd * 100 / mEnd),
                "%) | floor once caught up $",
                vm.toString(f / 1000),
                "k (",
                vm.toString(f * 100 / mEnd),
                "%) after +",
                vm.toString(hrs),
                "h"
            ));
        vm.revertToState(snap);
    }

    // mcap in $ from a sqrtPriceX96 of the pool (tokens per ETH)
    function _mcapAt(uint160 s) internal pure returns (uint256) {
        // price ETH per token = 2^192 / s^2 ; mcap = 1e9 tokens * price * ETH_USD
        uint256 sq = uint256(s) * uint256(s) >> 96; // tokens per ETH * 2^96
        return (uint256(1e9) * ETH_USD << 96) / sq;
    }

    function _mcap() internal view returns (uint256) {
        (uint160 s,,,) = pm.getSlot0(foboKey.toId());
        return _mcapAt(s);
    }

    function _floorMcap() internal view returns (uint256) {
        (, uint160 s,) = hook.floorOf(foboKey);
        return _mcapAt(s);
    }

    function _pathMcap(uint256 i, uint256 n) internal view returns (uint256) {
        // 10k * 10^(i/n), via exp of ln
        int256 x = int256(i * 1e18 / n) * _ln(TARGET / 10_000) / 1e18; // i/n * ln(target / start)
        return 10_000 * _exp(x) / 1e18;
    }

    // ETH (wei, pool side) to move the launch range from mcap a to b: T*p0*(sqrt(b/M0) - sqrt(a/M0))
    function _costEth(uint256 a, uint256 b) internal pure returns (uint256) {
        (uint256 bps,) = Curve.tranche(0);
        uint256 tp0 = bps * 100_000 * uint256(1e18) * 10_000 / 1e9 / ETH_USD; // the launch tranche's supply at $10k, in wei
        return tp0 * (_sqrt(b * 1e36 / 10_000) - _sqrt(a * 1e36 / 10_000)) / 1e18;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) (z, y) = (y, (x / y + y) >> 1);
    }

    function _ln(uint256 k) internal pure returns (int256) {
        if (k == 10) return 2302585092994045684;
        if (k == 50) return 3912023005428146059;
        revert("ln");
    }

    function _exp(int256 x) internal pure returns (uint256 r) {
        // e^x for 0 <= x <= ~3 (1e18 fixed point), Taylor series
        r = 1e18;
        uint256 term = 1e18;
        for (uint256 k = 1; k < 40; k++) {
            term = term * uint256(x) / 1e18 / k;
            r += term;
        }
    }
}
