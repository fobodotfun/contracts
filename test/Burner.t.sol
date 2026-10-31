// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FoboBurner} from "../src/FoboBurner.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {Owned} from "../src/base/Owned.sol";
import {IFoboBurner} from "../src/interfaces/IFoboBurner.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {MockQuote, QuoteBase} from "./QuoteDecimals.t.sol";

/// FoboBurner (README §5.2): every buy-$FOBO-and-burn amount lands here (the launch fee as native ETH, the snipe tax's
/// burn share and swept floor money as the hook's ERC-6909 claims), and only a keeper spends it, only on $FOBO that is
/// burned in the same call: ETH straight in the $FOBO pool, a USD quote along its owner-set route (the ETH/USD pool) first.
/// The $FOBO leg never takes the price more than BURN_MAX_TICKS above the block's start, the keeper's minimums and the
/// USD peg check bound the rest. Attack check: a sandwich around a buyback loses, a keeper key can't spend past the bound or
/// off the peg, and nothing but the owner's emergencyWithdraw takes anything out.
contract BurnerTest is QuoteBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency constant ETH = Currency.wrap(address(0));
    uint24 constant USD_POOL_FEE = 500;
    int24 constant USD_POOL_SPACING = 10;
    uint256 constant ETH_USD = 2600;

    MockQuote usd;
    PoolKey usdKey; // the ETH/USD reference pool (no hook), standing in for ETH/USDG
    PoolKey nekoKey; // a FOBO pair on the USD quote

    /// PoolModifyLiquidityTest refunds the ETH a position didn't use
    receive() external payable {}

    // ---------------------------------------------------------------- setup helpers

    /// $FOBO launched and past its snipe window, with some depth
    function _foboWithDepth() internal {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(_user("organic"), foboKey, true, -20 ether, 20 ether);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// An ETH pair sniped at second 0 with `eth`: 40% of the ~90% tax to FoboBurner as ETH claims
    function _snipedEthPair(uint256 eth) internal returns (PoolKey memory k) {
        address alice = _user("alice");
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: FEE}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        k = hook.keyFor(address(0), kumo);
        _swap(_user("sniper"), k, true, -int256(eth), eth);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// A 6-decimal $1 quote, a full-range ETH/USD pool at ETH_USD (100 ETH deep), and a FOBO pair on it sniped at
    /// second 0 with 1,000 USD (360 USD of claims to FoboBurner)
    function _usdSetup() internal {
        int24 mid;
        (usd, mid) = _allowQuote(6, 0);
        usdKey = PoolKey(ETH, Currency.wrap(address(usd)), USD_POOL_FEE, USD_POOL_SPACING, IHooks(address(0)));
        pm.initialize(usdKey, uint160(_sqrt((ETH_USD * 1e6 << 192) / 1e18)));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        usd.approve(address(lp), type(uint256).max);
        usd.approve(address(router), type(uint256).max);
        int24 maxTick = TickMath.MAX_TICK / USD_POOL_SPACING * USD_POOL_SPACING;
        lp.modifyLiquidity{value: 101 ether}(
            usdKey,
            IPoolManager.ModifyLiquidityParams(
                -maxTick, maxTick, int256(_sqrt(100 ether * (100 ether * ETH_USD / 1e12))), 0
            ),
            ""
        );
        address alice = _user("alice6");
        address bob = _user("bob6");
        _fund(usd, alice, 10_000);
        _fund(usd, bob, 100_000);
        (address neko, PoolKey memory k) = _launchOn(usd, alice, "Neko", "NEKO", 0, mid);
        nekoKey = k;
        _approve(bob, neko);
        _swap(bob, k, true, -int256(uint256(1_000e6)), 0);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _usdPath() internal view returns (PoolKey[] memory path) {
        path = new PoolKey[](1);
        path[0] = usdKey;
    }

    function _buy(address quote, uint256 amountIn, uint256 minEthOut, uint256 minFoboOut) internal returns (uint256) {
        vm.prank(burnKeeper, burnKeeper);
        (, uint256 burned) = burner.buybackAndBurn(quote, amountIn, minEthOut, minFoboOut);
        return burned;
    }

    function _expectBuyRevert(address quote, uint256 amountIn, uint256 minEthOut, uint256 minFoboOut, bytes4 err)
        internal
    {
        vm.prank(burnKeeper, burnKeeper);
        vm.expectRevert(err);
        burner.buybackAndBurn(quote, amountIn, minEthOut, minFoboOut);
    }

    function _testSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) (z, y) = (y, (x / y + y) >> 1);
    }

    // ---------------------------------------------------------------- wiring and owner

    /// The hook names the burner immutably, the factory reads it from the hook, the burner takes the hook once and only
    /// a hook built for it. Two-step ownership, renounce disabled.
    function test_wiring() public {
        assertEq(hook.burner(), address(burner));
        assertEq(factory.burner(), address(burner));
        assertEq(address(burner.hook()), address(hook));
        vm.expectRevert(IFoboBurner.HookAlreadySet.selector);
        burner.setHook(hook);
        FoboBurner other = new FoboBurner(pm, address(this));
        vm.expectRevert(IFoboBurner.BadHook.selector);
        other.setHook(hook); // the hook names `burner`, not `other`
        vm.expectRevert(IFoboBurner.ZeroAddress.selector);
        other.setHook(IFoboHook(address(0)));
        vm.expectRevert(IFoboBurner.ZeroAddress.selector);
        new FoboBurner(IPoolManager(address(0)), address(this));
        // before its hook is set nothing can be routed or bought
        PoolKey[] memory none = new PoolKey[](0);
        vm.expectRevert(IFoboBurner.HookNotSet.selector);
        other.setRoute(address(1), none, false);
        // ownership: two-step to the Owner Safe, never renounced
        address safe = makeAddr("safe");
        burner.transferOwnership(safe);
        assertEq(burner.owner(), address(this), "pending until accepted");
        vm.prank(safe);
        burner.acceptOwnership();
        assertEq(burner.owner(), safe);
        vm.prank(safe);
        vm.expectRevert(Owned.RenounceDisabled.selector);
        burner.renounceOwnership();
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        burner.setKeeper(address(this), true);
    }

    /// Keepers: owner-set, several at once, rotated; nobody else can buy back.
    function test_keepers() public {
        _foboWithDepth();
        _snipedEthPair(1 ether);
        address k2 = makeAddr("keeper2");
        vm.expectEmit(true, false, false, true, address(burner));
        emit IFoboBurner.KeeperSet(k2, true);
        burner.setKeeper(k2, true);
        assertTrue(burner.keepers(burnKeeper) && burner.keepers(k2), "several keepers");
        vm.expectRevert(IFoboBurner.ZeroAddress.selector);
        burner.setKeeper(address(0), true);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(IFoboBurner.NotKeeper.selector);
        burner.buybackAndBurn(address(0), 0.001 ether, 0, 0);
        // the owner isn't a keeper either
        vm.expectRevert(IFoboBurner.NotKeeper.selector);
        burner.buybackAndBurn(address(0), 0.001 ether, 0, 0);
        vm.prank(k2);
        (uint256 ethIn, uint256 burned) = burner.buybackAndBurn(address(0), 0.001 ether, 0, 0);
        assertEq(ethIn, 0.001 ether, "ETH: the amount itself");
        assertGt(burned, 0, "the second keeper buys");
        burner.setKeeper(k2, false);
        vm.prank(k2);
        vm.expectRevert(IFoboBurner.NotKeeper.selector);
        burner.buybackAndBurn(address(0), 0.001 ether, 0, 0);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        vm.prank(burnKeeper);
        burner.setKeeper(burnKeeper, false);
    }

    // ---------------------------------------------------------------- what lands in the burner

    /// The launch fee arrives as native ETH (Received from the factory), $FOBO's own launch pays none; the snipe tax's
    /// 40% on an ETH pair as ETH claims; nothing of it stays in the hook.
    function test_launchFeeAndSnipeShareLandHere() public {
        _launchFobo();
        assertEq(address(burner).balance, 0, "$FOBO's own launch pays no fee");
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        vm.expectEmit(true, false, false, true, address(burner));
        emit IFoboBurner.Received(address(factory), FEE);
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: 1 ether}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        assertEq(address(burner).balance, FEE);
        PoolKey memory k = hook.keyFor(address(0), kumo);
        uint256 hookClaims0 = _claims(ETH);
        _swap(_user("sniper"), k, true, -1 ether, 1 ether);
        uint256 tax = (1 ether * _rate(0) + PIPS - 1) / PIPS;
        assertEq(_burnerOwed(ETH), tax * 40 / 100, "40% as claims, in the swap");
        assertEq(_claims(ETH) - hookClaims0, tax - tax * 40 / 100, "the hook keeps only the floor's 60%");
        // anyone may send ETH to burn
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(burner).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ---------------------------------------------------------------- buybackAndBurn: ETH

    /// ETH: claims first, then the launch fees' native ETH; every $FOBO bought is burned; the event logs it all; the
    /// price ends within BURN_MAX_TICKS of the block's start.
    function test_buybackEth() public {
        _foboWithDepth();
        _snipedEthPair(0.05 ether); // ~0.018 ETH of claims
        uint256 claims = _burnerOwed(ETH);
        uint256 native = address(burner).balance;
        assertEq(native, FEE);
        // one wei more than it holds, claims and native ETH together
        _expectBuyRevert(address(0), claims + native + 1, 0, 0, IFoboBurner.NotEnough.selector);
        uint256 amount = claims + native / 2; // all the claims and half the native ETH
        uint256 supply0 = FoboToken(fobo).totalSupply();
        int24 ref = hook.startOfBlockTick(foboKey.toId());
        vm.recordLogs();
        uint256 burned = _buy(address(0), amount, 0, 1);
        assertGt(burned, 0);
        assertEq(supply0 - FoboToken(fobo).totalSupply(), burned, "burned exactly what it bought");
        assertEq(FoboToken(fobo).balanceOf(address(burner)), 0, "holds no $FOBO");
        assertEq(_burnerOwed(ETH), 0, "claims spent first");
        assertEq(address(burner).balance, native - native / 2, "then native ETH");
        assertGe(_tick(foboKey), ref - BURN_MAX_TICKS, "within the bound");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(burner) || logs[i].topics[0] != IFoboBurner.BoughtAndBurned.selector) {
                continue;
            }
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(burnKeeper))));
            assertEq(logs[i].topics[2], bytes32(0), "quote ETH");
            (uint256 amountIn, uint256 ethIn, uint256 fb, uint160 sq) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint160));
            (uint160 sNow,,,) = pm.getSlot0(foboKey.toId());
            assertEq(amountIn, amount);
            assertEq(ethIn, amount);
            assertEq(fb, burned);
            assertEq(sq, sNow);
            seen = true;
        }
        assertTrue(seen, "BoughtAndBurned");
    }

    /// The keeper's bounds: minFoboOut, zero, and the price bound (past it in one call, or $FOBO
    /// already pumped this block). A later block buys again.
    function test_buybackBounds() public {
        _foboWithDepth();
        _snipedEthPair(10 ether); // ~3.6 ETH of claims
        uint256 snap = vm.snapshotState();
        uint256 out = _buy(address(0), 0.01 ether, 0, 0);
        vm.revertToState(snap);
        _expectBuyRevert(address(0), 0.01 ether, 0, out + 1, IFoboBurner.TooLittleOut.selector);
        _expectBuyRevert(address(0), 0, 0, 0, IFoboBurner.ZeroAmount.selector);
        // 3.6 ETH at once moves $FOBO far more than ~1%
        _expectBuyRevert(address(0), _burnerOwed(ETH), 0, 0, IFoboBurner.BurnBound.selector);
        // pumped this block: even a small buyback waits
        snap = vm.snapshotState();
        _swap(_user("eve"), foboKey, true, -5 ether, 5 ether);
        _expectBuyRevert(address(0), 0.01 ether, 0, 0, IFoboBurner.BurnBound.selector);
        vm.revertToState(snap);
        // within the bound now; the next block can buy again (the bound is per block start)
        assertEq(_buy(address(0), 0.01 ether, 0, out), out);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(_buy(address(0), 0.01 ether, 0, 0), 0);
    }

    /// Attack check: whatever size a keeper key picks, with no minimums, a buyback either reverts or ends within
    /// BURN_MAX_TICKS of the block's start; and it can only ever spend into $FOBO that is burned.
    function testFuzz_keeperCannotExceedTheBound(uint256 amount, bool pumpFirst) public {
        _foboWithDepth();
        _snipedEthPair(10 ether);
        if (pumpFirst) _swap(_user("eve"), foboKey, true, -0.05 ether, 0.05 ether);
        amount = bound(amount, 1, _burnerOwed(ETH));
        int24 ref = hook.startOfBlockTick(foboKey.toId());
        uint256 supply0 = FoboToken(fobo).totalSupply();
        uint256 eth0 = _burnerOwed(ETH) + address(burner).balance;
        vm.prank(burnKeeper, burnKeeper);
        try burner.buybackAndBurn(address(0), amount, 0, 0) returns (uint256, uint256 burned) {
            assertGe(_tick(foboKey), ref - BURN_MAX_TICKS, "never past the bound");
            assertEq(supply0 - FoboToken(fobo).totalSupply(), burned, "all of it burned");
            assertEq(eth0 - _burnerOwed(ETH) - address(burner).balance, amount, "spent exactly the amount");
        } catch {
            assertEq(_burnerOwed(ETH) + address(burner).balance, eth0, "a revert spends nothing");
        }
    }

    /// Attack check: a sandwich around a keeper's buyback (the largest the bound lets through, no minimums) loses: the bound
    /// keeps the lift under ~1% and the pool's 2.5% tax applies both ways. Pumping a block ahead makes the start-of-block
    /// price hers, so the buyback only lifts ~1% past her own pump.
    function test_sandwichAroundBuybackLoses() public {
        _foboWithDepth();
        _snipedEthPair(50 ether);
        uint256[5] memory xs = [uint256(0.01 ether), 0.1 ether, 1 ether, 5 ether, 20 ether];
        for (uint256 held; held < 2; held++) {
            for (uint256 i; i < xs.length; i++) {
                uint256 snap = vm.snapshotState();
                address eve = _user("eve");
                _approve(eve, fobo);
                uint256 e0 = eve.balance;
                _swap(eve, foboKey, true, -int256(xs[i]), xs[i]);
                if (held == 1) vm.roll(vm.getBlockNumber() + 1);
                uint256 burned = _buybackMax();
                _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
                emit log_named_decimal_uint("sandwich size", xs[i], 18);
                emit log_named_decimal_uint("    $FOBO burned", burned, 18);
                emit log_named_decimal_int("    eve PnL", int256(eve.balance) - int256(e0), 18);
                assertLt(eve.balance, e0, "the sandwich loses");
                vm.revertToState(snap);
            }
        }
    }

    // ---------------------------------------------------------------- buybackAndBurn: a USD quote

    /// A USD quote's claims go along its route (USD -> ETH in the ETH/USD pool) and then into $FOBO, burned; its ETH leg
    /// is checked against minEthOut and the ETH/USD feed (at most PEG_MAX_LOSS_BPS under $1 a unit).
    function test_buybackUsdRoute() public {
        _foboWithDepth();
        _usdSetup();
        Currency cq = Currency.wrap(address(usd));
        assertEq(_burnerOwed(cq), 360e6, "the snipe share, as claims of the 6-decimal quote");
        _expectBuyRevert(address(usd), 30e6, 0, 0, IFoboBurner.NoRoute.selector);
        vm.expectEmit(true, false, false, true, address(burner));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PoolId.unwrap(usdKey.toId());
        emit IFoboBurner.RouteSet(address(usd), ids, true);
        burner.setRoute(address(usd), _usdPath(), true);
        (PoolKey[] memory path, bool peg) = burner.routeOf(address(usd));
        assertEq(path.length, 1);
        assertEq(PoolId.unwrap(path[0].toId()), ids[0]);
        assertTrue(peg);

        // what 30 USD buys right now: ~30 / 2600 ETH less the pool's 0.05%
        // (the keeper's quote: the same call, simulated)
        uint256 snap = vm.snapshotState();
        vm.prank(burnKeeper, burnKeeper);
        (uint256 ethIn, uint256 burned) = burner.buybackAndBurn(address(usd), 30e6, 0, 0);
        vm.revertToState(snap);
        assertApproxEqRel(ethIn, 30 ether / ETH_USD, 0.002e18, "the USD leg at the pool's price");
        _expectBuyRevert(address(usd), 30e6, ethIn + 1, 0, IFoboBurner.TooLittleOut.selector);
        _expectBuyRevert(address(usd), 30e6, 0, burned + 1, IFoboBurner.TooLittleOut.selector);

        uint256 supply0 = FoboToken(fobo).totalSupply();
        uint256 ethPool0 = pm.balanceOf(address(burner), 0);
        assertEq(_buy(address(usd), 30e6, ethIn, burned), burned);
        assertEq(supply0 - FoboToken(fobo).totalSupply(), burned, "burned");
        assertEq(_burnerOwed(cq), 330e6, "spent 30 USD of claims");
        assertEq(pm.balanceOf(address(burner), 0), ethPool0, "no ETH left over: the leg's ETH all bought $FOBO");

        // the feed says ETH halved: the ETH the pool gives is worth half the USD that went in, refused
        feed.setAnswer(ETH_USD_8 / 2);
        _expectBuyRevert(address(usd), 30e6, 0, 0, IFoboBurner.OffPeg.selector);
        // without the peg flag only the keeper's minimum guards it
        burner.setRoute(address(usd), _usdPath(), false);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(_buy(address(usd), 30e6, 0, 0), 0);
        // a removed route
        burner.setRoute(address(usd), new PoolKey[](0), true);
        (path, peg) = burner.routeOf(address(usd));
        assertEq(path.length, 0);
        assertFalse(peg, "no peg without a route");
        _expectBuyRevert(address(usd), 30e6, 0, 0, IFoboBurner.NoRoute.selector);
    }

    /// Attack check: a sandwich on the external ETH/USD leg (someone dumps USD into the pool right before a buyback with no
    /// minimum) is refused by the peg check, so a keeper key can't sell the burner's USD cheap to a friend.
    function test_usdLegSandwichIsRefused() public {
        _foboWithDepth();
        _usdSetup();
        burner.setRoute(address(usd), _usdPath(), true);
        address eve = _user("eve");
        usd.transfer(eve, 1_000_000e6);
        vm.prank(eve);
        usd.approve(address(router), type(uint256).max);
        // eve sells 100k USD for ETH: USD is ~half price in the pool now
        vm.prank(eve, eve);
        router.swap(
            usdKey,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -100_000e6, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _testSettings(),
            ""
        );
        _expectBuyRevert(address(usd), 300e6, 0, 0, IFoboBurner.OffPeg.selector);
    }

    // ---------------------------------------------------------------- routes

    function test_setRouteValidation() public {
        _foboWithDepth();
        _usdSetup();
        PoolKey[] memory p = _usdPath();
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        vm.prank(burnKeeper);
        burner.setRoute(address(usd), p, true);
        // ETH needs none, $FOBO can't have one
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(address(0), p, false);
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(fobo, p, false);
        // a path that doesn't start at the quote
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(makeAddr("other"), p, false);
        // a FOBO pool on the way (an unbounded leg in a hook pool)
        p[0] = nekoKey;
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(address(usd), p, false);
        // an uninitialised pool
        p[0] = usdKey;
        p[0].fee = 3000;
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(address(usd), p, false);
        // a path that doesn't end in ETH: USD -> ETH -> USD
        p = new PoolKey[](2);
        (p[0], p[1]) = (usdKey, usdKey);
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(address(usd), p, false);
        // more than MAX_HOPS
        p = new PoolKey[](4);
        for (uint256 i; i < 4; i++) {
            p[i] = usdKey;
        }
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(address(usd), p, false);
        // a quote with more than 18 decimals can't be pegged (the peg check scales it up to 18), only routed
        MockQuote wide = new MockQuote(19, 0);
        p = new PoolKey[](1);
        p[0] = PoolKey(ETH, Currency.wrap(address(wide)), USD_POOL_FEE, USD_POOL_SPACING, IHooks(address(0)));
        pm.initialize(p[0], uint160(1 << 96));
        vm.expectRevert(IFoboBurner.BadRoute.selector);
        burner.setRoute(address(wide), p, true);
        burner.setRoute(address(wide), p, false);
        burner.setRoute(address(usd), _usdPath(), true);
    }

    // ---------------------------------------------------------------- emergencyWithdraw

    /// The owner takes out everything held of a token: its claims redeemed and its balance, in one call (ETH and an
    /// ERC-20), to `to`. Nobody else can.
    function test_emergencyWithdraw() public {
        _foboWithDepth();
        _usdSetup();
        address to = makeAddr("safeOut");
        vm.expectRevert(IFoboBurner.ZeroAddress.selector);
        burner.emergencyWithdraw(address(0), address(0));
        vm.prank(burnKeeper);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        burner.emergencyWithdraw(address(0), to);

        uint256 claims = _burnerOwed(ETH);
        uint256 native = address(burner).balance;
        assertGt(native, 0);
        vm.expectEmit(true, true, false, true, address(burner));
        emit IFoboBurner.EmergencyWithdrawn(address(0), to, claims, native);
        burner.emergencyWithdraw(address(0), to);
        assertEq(to.balance, claims + native);
        assertEq(address(burner).balance + _burnerOwed(ETH), 0);

        usd.transfer(address(burner), 5e6); // held outright too
        Currency cq = Currency.wrap(address(usd));
        uint256 uc = _burnerOwed(cq);
        burner.emergencyWithdraw(address(usd), to);
        assertEq(usd.balanceOf(to), uc + 5e6);
        assertEq(_burnerOwed(cq) + usd.balanceOf(address(burner)), 0);
        // nothing held: a no-op that still logs
        burner.emergencyWithdraw(address(usd), to);
    }

    // ---------------------------------------------------------------- nobody paid mid-trade

    /// A creator (an account with no code) is never paid in a swap: its fee is owed until claimCreator, which anyone may
    /// trigger for it (the keeper's payouts).
    function test_creatorNeverPaidMidTrade() public {
        _foboWithDepth();
        address alice = _user("alice");
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: FEE}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        PoolKey memory k = hook.keyFor(address(0), kumo);
        vm.warp(vm.getBlockTimestamp() + 61);
        address bob = _user("bob");
        uint256 a0 = alice.balance;
        vm.recordLogs();
        _swap(bob, k, true, -10 ether, 10 ether);
        _approve(bob, kumo);
        _swap(bob, k, false, -int256(FoboToken(kumo).balanceOf(bob) / 2), 0);
        assertEq(alice.balance, a0, "not paid in either swap");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.Claimed.selector, "no payout in a swap");
        }
        (,, uint256 owed,,) = _pool(k);
        assertGt(owed, 0);
        vm.prank(burnKeeper); // anyone: the keeper's payout
        hook.claimCreator(k, alice);
        assertEq(alice.balance - a0, owed);
    }

    // ---------------------------------------------------------------- gas

    /// buybackAndBurn as a real transaction: forge test --mt test_gas_buyback --isolate -vv
    function test_gas_buybackEth() public {
        _foboWithDepth();
        _snipedEthPair(0.1 ether);
        uint256 amt = _burnerOwed(ETH);
        vm.prank(burnKeeper, burnKeeper);
        uint256 g = gasleft();
        burner.buybackAndBurn(address(0), amt, 0, 0);
        g -= gasleft();
        emit log_named_uint("buybackAndBurn (ETH) gas", g);
    }

    function test_gas_buybackUsd() public {
        _foboWithDepth();
        _usdSetup();
        burner.setRoute(address(usd), _usdPath(), true);
        vm.prank(burnKeeper, burnKeeper);
        uint256 g = gasleft();
        burner.buybackAndBurn(address(usd), 30e6, 0, 0);
        g -= gasleft();
        emit log_named_uint("buybackAndBurn (USD route) gas", g);
    }
}
