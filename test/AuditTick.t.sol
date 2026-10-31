// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FoboBase} from "./Fobo.t.sol";
import {Ticks} from "../src/libraries/Ticks.sol";

/// Protocol auditor L1: the lowest start tick that launches is Ticks.MIN_START_TICK (createPool's check), not the much lower
/// bound the old tranche-offset check allowed (those starts reverted inside v4 with TickLiquidityOverflow).
contract AuditTickTest is FoboBase {
    function _try(int24 t) external {
        factory.launch(_params("FOBO", "FOBO", bytes32(0), 0, t));
    }

    function test_lowestWorkingStart() public {
        int24 lo = -610800;
        int24 hi = 0;
        // binary search the lowest tickStart that launches
        while (hi - lo > 60) {
            int24 mid = ((lo + hi) / 2) / 60 * 60;
            uint256 snap = vm.snapshotState();
            bool ok;
            try this._try(mid) {
                ok = true;
            } catch {}
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_int("lowest tickStart that launches", hi);
        assertEq(hi, Ticks.MIN_START_TICK);
        uint256 snap2 = vm.snapshotState();
        try this._try(lo) {}
        catch (bytes memory err) {
            emit log_bytes(err);
        }
        vm.revertToState(snap2);
    }
}
