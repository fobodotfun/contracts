// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FoboFactory} from "../src/FoboFactory.sol";
import {FoboHook} from "../src/FoboHook.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {FoboBase} from "./Fobo.t.sol";

/// Attack tests, kept as regression tests: buy into a buyback (same
/// transaction, same block, or held 1-100 blocks), with and without the old MAX_BACKING_RATIO state, after a rug and
/// after flat organic volume. Every attacker must lose (the 2.5% tax each way) and the honest holder must never exit
/// worse than after an honest poke. Each scenario logs its numbers: forge test --mc Audit -vv
abstract contract AuditBase is FoboBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // rug scenario from test_pinnedFloorCannotBeHarvested, stopping right before the 2h-later poke
    function _rugSetup(uint256 snipe, uint256 organic) internal returns (address carol) {
        _launchFobo();
        address bob = _user("bob");
        carol = _user("carol");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _swap(bob, foboKey, true, -int256(snipe), snipe);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -int256(organic), organic);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
    }

    function _exit(address who) internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        uint256 b0 = who.balance;
        _swap(who, foboKey, false, -int256(FoboToken(fobo).balanceOf(who)), 0);
        got = who.balance - b0;
        vm.revertToState(snap);
    }

    /// eve's PnL must be negative, and carol's exit at least what an honest poke gave her
    function _check(address eve, uint256 e0, address carol, uint256 carolFair) internal {
        assertLt(eve.balance, e0, "the attacker loses");
        if (carol != address(0)) {
            assertGe(_exit(carol) + 2, carolFair, "the holder exits at least as after an honest poke");
        }
    }
}

contract AuditTest is AuditBase {
    /// H1: the buyback used to read the CURRENT tick, not the start-of-block refTick. The block's first swap is an
    /// attacker's buy: its own afterSwap ran the buyback against the pumped price; the attacker sells in the same block.
    /// Now the raise runs in the first swap's beforeSwap, on the state the block started with.
    function test_atomicPumpBuybackDump() public {
        address carol = _rugSetup(2 ether, 1 ether);
        uint256 carolFair;
        {
            uint256 snap = vm.snapshotState();
            hook.poke(foboKey);
            carolFair = _exit(carol);
            vm.revertToState(snap);
        }
        emit log_named_uint("carol exit after honest poke", carolFair);
        uint256[10] memory sizes = [
            uint256(0.01 ether),
            0.05 ether,
            0.1 ether,
            0.25 ether,
            0.5 ether,
            1 ether,
            2 ether,
            4 ether,
            8 ether,
            30 ether
        ];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            address eve = _user("eve");
            _approve(eve, fobo);
            uint256 e0 = eve.balance;
            uint256 sup0 = FoboToken(fobo).totalSupply();
            _swap(eve, foboKey, true, -int256(sizes[i]), sizes[i]); // first swap of the block: buyback runs here
            bool bought = FoboToken(fobo).totalSupply() < sup0;
            _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0); // same block
            int256 pnl = int256(eve.balance) - int256(e0);
            emit log_named_uint("size", sizes[i]);
            emit log_named_int("  eve pnl", pnl);
            emit log_named_uint("  bought back in eve's tx (the raise before her buy)", bought ? 1 : 0);
            emit log_named_int("  carol exit vs honest", int256(_exit(carol)) - int256(carolFair));
            _check(eve, e0, carol, carolFair);
            vm.revertToState(snap);
        }
    }

    /// H1b: no buyback used to run while almost nobody held (MAX_BACKING_RATIO), and a buyer's own swap could unlock it in
    /// the same block. The gate is gone: the raise before the buyer's swap pays the holder.
    function test_atomicUnlockBackingRatio() public {
        address carol = _rugSetup(100 ether, 0.1 ether);
        {
            uint256 snap = vm.snapshotState();
            uint256 s0 = FoboToken(fobo).totalSupply();
            hook.poke(foboKey);
            emit log_named_uint("honest poke burned", s0 - FoboToken(fobo).totalSupply());
            vm.revertToState(snap);
        }
        (uint128 sp,) = _snipe(foboKey);
        emit log_named_uint("snipe pot", sp);
        uint256[8] memory sizes =
            [uint256(0.5 ether), 1 ether, 2 ether, 5 ether, 10 ether, 20 ether, 50 ether, 100 ether];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            address eve = _user("eve");
            _approve(eve, fobo);
            uint256 e0 = eve.balance;
            uint256 sup0 = FoboToken(fobo).totalSupply();
            _swap(eve, foboKey, true, -int256(sizes[i]), sizes[i]);
            bool bought = FoboToken(fobo).totalSupply() < sup0;
            _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
            emit log_named_uint("size", sizes[i]);
            emit log_named_int("  eve pnl", int256(eve.balance) - int256(e0));
            emit log_named_uint("  bought back in eve's tx (the raise before her buy)", bought ? 1 : 0);
            _check(eve, e0, address(0), 0);
            vm.revertToState(snap);
        }
        carol;
    }
}

contract AuditHoldTest is AuditBase {
    /// H1 with one block of holding: eve buys first thing in block N, sells in block N+1 after a poke.
    function test_holdOneBlockPumpBuybackDump() public {
        address carol = _rugSetup(2 ether, 1 ether);
        _holdLoop(carol);
    }

    function test_holdOneBlockUnlockBackingRatio() public {
        address carol = _rugSetup(100 ether, 0.1 ether);
        _holdLoop(carol);
    }

    function _holdLoop(address carol) internal {
        uint256 carolFair;
        {
            uint256 snap = vm.snapshotState();
            hook.poke(foboKey);
            carolFair = _exit(carol);
            vm.revertToState(snap);
        }
        uint256[8] memory sizes =
            [uint256(0.05 ether), 0.25 ether, 0.5 ether, 1 ether, 2 ether, 5 ether, 20 ether, 50 ether];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            address eve = _user("eve");
            _approve(eve, fobo);
            uint256 e0 = eve.balance;
            uint256 sup0 = FoboToken(fobo).totalSupply();
            _swap(eve, foboKey, true, -int256(sizes[i]), sizes[i]);
            bool boughtInSwap = FoboToken(fobo).totalSupply() < sup0;
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            hook.poke(foboKey);
            _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
            emit log_named_uint("size", sizes[i]);
            emit log_named_int("  eve pnl", int256(eve.balance) - int256(e0));
            emit log_named_uint("  buyback inside eve's own buy", boughtInSwap ? 1 : 0);
            emit log_named_int("  carol exit vs honest", int256(_exit(carol)) - int256(carolFair));
            _check(eve, e0, carol, carolFair);
            vm.revertToState(snap);
        }
    }
}

contract AuditMultiHoldTest is AuditBase {
    function test_holdNBlocks() public {
        address carol = _rugSetup(2 ether, 1 ether);
        _loop();
        carol;
    }

    function test_holdNBlocksRatio() public {
        address carol = _rugSetup(100 ether, 0.1 ether);
        _loop();
        carol;
    }

    function _loop() internal {
        uint256[4] memory sizes = [uint256(0.25 ether), 1 ether, 5 ether, 50 ether];
        uint256[4] memory holds = [uint256(1), 5, 25, 100];
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 h; h < holds.length; h++) {
                uint256 snap = vm.snapshotState();
                address eve = _user("eve");
                _approve(eve, fobo);
                uint256 e0 = eve.balance;
                _swap(eve, foboKey, true, -int256(sizes[i]), sizes[i]);
                for (uint256 b; b < holds[h]; b++) {
                    vm.roll(vm.getBlockNumber() + 1);
                    vm.warp(vm.getBlockTimestamp() + 12);
                    hook.poke(foboKey);
                }
                _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
                emit log_named_uint("size", sizes[i]);
                emit log_named_uint("  hold blocks", holds[h]);
                emit log_named_int("  eve pnl", int256(eve.balance) - int256(e0));
                _check(eve, e0, address(0), 0);
                vm.revertToState(snap);
            }
        }
    }
}

contract AuditOrganicTest is AuditBase {
    /// No rug, no snipe: heavy round-trip volume on a flat price fills the floor; spare money then appears and an
    /// atomic buy -> (buyback in own afterSwap) -> sell skims it.
    function test_organicSpareAtomicSkim() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address carol = _user("carol");
        address bob = _user("bob");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _swap(carol, foboKey, true, -1 ether, 1 ether);
        for (uint256 i; i < 150; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            _swap(bob, foboKey, true, -2 ether, 2 ether);
            _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        }
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        uint256 carolBefore = _exit(carol);
        emit log_named_uint("carol exit before", carolBefore);
        uint256[5] memory sizes = [uint256(0.1 ether), 0.3 ether, 1 ether, 3 ether, 10 ether];
        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            address eve = _user("eve");
            _approve(eve, fobo);
            uint256 e0 = eve.balance;
            uint256 s0 = FoboToken(fobo).totalSupply();
            _swap(eve, foboKey, true, -int256(sizes[i]), sizes[i]);
            bool bb = FoboToken(fobo).totalSupply() < s0;
            _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
            emit log_named_uint("size", sizes[i]);
            emit log_named_int("  eve pnl", int256(eve.balance) - int256(e0));
            emit log_named_uint("  buyback in eve's buy", bb ? 1 : 0);
            emit log_named_int("  carol exit change", int256(_exit(carol)) - int256(carolBefore));
            _check(eve, e0, carol, carolBefore);
            vm.revertToState(snap);
        }
    }
}
