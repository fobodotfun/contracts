// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {FoboBase} from "./Fobo.t.sol";

/// Additional adversarial coverage from the October 2026 source review. No mocked pool accounting.
contract SecurityReviewTest is FoboBase {
    using PoolIdLibrary for PoolKey;

    function test_startBandRejectsTicksAboveHookRange() public {
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setStartBand(887220, 887280);
    }

    function test_quoteBandRejectsTicksAboveHookRange() public {
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setQuoteBand(makeAddr("quote"), 887220, 887280);
    }

    function test_startBandMustContainAnAlignedTick() public {
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setStartBand(193801, 193859);
        // Negative division must also round toward minus infinity.
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setQuoteBand(makeAddr("quote"), -59, -1);
    }

    function test_validNarrowAndBoundaryBands() public {
        factory.setStartBand(193799, 193801);
        factory.setStartBand(-54780, -54779);
        factory.setStartBand(887159, 887160);
        factory.setQuoteBand(makeAddr("quote"), -61, -59);
    }

    function test_callbacksAndHookClaimsRejectForgedCallers() public {
        _launchFobo();
        address attacker = _user("callback attacker");
        _swap(attacker, foboKey, true, -1 ether, 1 ether);
        bytes4 notManager = bytes4(keccak256("NotPoolManager()"));
        vm.startPrank(attacker);
        vm.expectRevert(notManager);
        factory.unlockCallback("");
        vm.expectRevert(notManager);
        hook.unlockCallback("");
        vm.expectRevert(notManager);
        revenue.unlockCallback("");
        vm.expectRevert(notManager);
        limitOrders.unlockCallback("");
        vm.expectRevert(IFoboHook.NotSelf.selector);
        hook.raiseFromHook(foboKey);
        vm.expectRevert(IFoboHook.NotFactory.selector);
        hook.endLaunch();
        vm.expectRevert();
        pm.transferFrom(address(hook), attacker, 0, 1);
        vm.expectRevert();
        pm.transferFrom(address(revenue), attacker, 0, 1);
        vm.stopPrank();
        _assertEthClaims();
    }

    function test_productionRuntimeCodeFitsEip170() public view {
        assertLe(address(factory).code.length, 24576);
        assertLe(address(hook).code.length, 24576);
        assertLe(address(revenue).code.length, 24576);
        assertLe(address(limitOrders).code.length, 24576);
    }

    /// Holders burning their own tokens, direct token donations and Uniswap's optional protocol fees must not
    /// strand other holders. Protocol tokens stay circulating until their recipient exits or burns them.
    function testFuzz_holderBurnsDonationsAndProtocolFees(uint256 seed) public {
        _launchFobo();
        address alice = _user("burner");
        address bob = _user("survivor");
        address collector = _user("protocol collector");
        pm.setProtocolFeeController(address(this));
        uint24 fee = uint24(seed % 1001); // v4 maximum: 1000 pips per direction
        pm.setProtocolFee(foboKey, fee | (fee << 12));
        vm.recordLogs();
        _swap(alice, foboKey, true, -2 ether, 2 ether);
        _swap(bob, foboKey, true, -1 ether, 1 ether);
        uint256 bag = FoboToken(fobo).balanceOf(alice);
        uint256 burned = bag * ((seed >> 16) % 10001) / 10000;
        vm.prank(alice);
        FoboToken(fobo).burn(burned);
        uint256 donated = (bag - burned) / 7;
        vm.prank(alice);
        FoboToken(fobo).transfer(address(hook), donated);
        int24 lastFloor;
        (lastFloor,,) = hook.floorOf(foboKey);
        for (uint256 i; i < 12; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 61);
            hook.poke(foboKey);
            (int24 next,,) = hook.floorOf(foboKey);
            assertLe(next, lastFloor, "floor may only rise");
            lastFloor = next;
        }
        uint256 left = FoboToken(fobo).balanceOf(alice);
        if (left != 0) _swap(alice, foboKey, false, -int256(left), 0);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        pm.collectProtocolFees(collector, Currency.wrap(fobo), 0);
        // Turn the fee off to close out the collector without leaving a new residual protocol balance.
        pm.setProtocolFee(foboKey, 0);
        uint256 collected = FoboToken(fobo).balanceOf(collector);
        if (collected != 0) _swap(collector, foboKey, false, -int256(collected), 0);
        assertLe(_tick(foboKey), lastFloor + 60, "all sellable tokens exit within floor");
        assertEq(FoboToken(fobo).balanceOf(address(hook)), donated, "donations cannot be stolen");
        _assertEthClaims();
        _assertNoFailures();
    }

    /// Holding output as v4 claims (and later paying with claims) must not hide circulating supply from the floor.
    function test_claimBalancesRemainBackedAndCanExit() public {
        _launchFobo();
        address alice = _user("claims trader");
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(alice, alice);
        BalanceDelta buy = router.swap{value: 1 ether}(
            foboKey,
            IPoolManager.SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
        uint256 tokens = uint256(int256(buy.amount1()));
        assertEq(FoboToken(fobo).balanceOf(alice), 0);
        assertEq(pm.balanceOf(alice, uint160(fobo)), tokens);
        vm.roll(vm.getBlockNumber() + 1);
        hook.poke(foboKey);
        (int24 floor,, uint256 circulating) = hook.floorOf(foboKey);
        assertGe(circulating, tokens, "claim holders are circulating");
        vm.prank(alice);
        pm.setOperator(address(router), true);
        vm.prank(alice, alice);
        router.swap(
            foboKey,
            IPoolManager.SwapParams(false, -int256(tokens), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, true),
            ""
        );
        assertEq(pm.balanceOf(alice, uint160(fobo)), 0);
        assertLe(_tick(foboKey), floor + 60);
        _assertEthClaims();
    }

    function _assertEthClaims() internal view {
        (,,,,,,,, uint128 snipe, uint128 released,,, uint256 pot, uint256 creator,) = hook.pools(foboKey.toId());
        Currency eth = Currency.wrap(address(0));
        assertEq(
            pm.balanceOf(address(hook), 0),
            pot + snipe - released + creator + hook.teamOwed(eth),
            "hook ETH claims cover exactly its obligations"
        );
        assertEq(pm.balanceOf(address(revenue), 0), revenue.owed(team, address(0)));
    }

    function _assertNoFailures() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "raise must not silently fail");
            assertTrue(logs[i].topics[0] != IFoboHook.CreditFailed.selector, "credit must not silently fail");
        }
    }
}
