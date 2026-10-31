// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {FoboBurner} from "../src/FoboBurner.sol";
import {FoboVesting} from "../src/FoboVesting.sol";
import {FoboFactory} from "../src/FoboFactory.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FoboHook} from "../src/FoboHook.sol";
import {IFoboRevenue} from "../src/interfaces/IFoboRevenue.sol";
import {Ticks} from "../src/libraries/Ticks.sol";
import {FoboRevenue} from "../src/FoboRevenue.sol";
import {FoboToken} from "../src/FoboToken.sol";
import {FloorMath} from "../src/libraries/FloorMath.sol";
import {Curve, N_TRANCHES} from "../src/libraries/Curve.sol";
import {IFoboHook} from "../src/interfaces/IFoboHook.sol";
import {FoboLimitOrders} from "../src/FoboLimitOrders.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {MockEthUsdFeed} from "../script/MockEthUsdFeed.sol";

contract SixDecimals {
    uint8 public constant decimals = 6;
}

/// Answers decimals() with no data (a proxy with nothing behind it, a contract with only a fallback).
contract EmptyDecimals {
    fallback() external {}
}

/// Answers decimals() with a word past uint8.
contract WideDecimals {
    function decimals() external pure returns (uint256) {
        return 256;
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// Gives `to` ERC-6909 claims of ETH backed by real ETH in the PoolManager (tests that need an absurdly large pot).
contract ClaimsGifter is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function gift(address to) external payable {
        pm.unlock(abi.encode(to, msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        pm.settle{value: amount}();
        pm.mint(to, 0, amount); // currency id 0 = native ETH
        return "";
    }
}

contract FoboBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    int24 constant FOBO_TICK = 193800; // ~$10k mcap with ETH at $2.6k (~3.85e-9 ETH per token)
    uint256 constant FEE = 0.0038 ether; // ~$10
    uint256 constant PIPS = 1_000_000;
    int24 constant BAND_HALF = 6960; // ~2x either side of a $10k start, as Deploy.s.sol sets it
    int256 constant ETH_USD_8 = 2600e8; // the ETH/USD feed's answer (8 decimals, like Chainlink's)
    uint256 constant FEED_MAX_AGE = 1 hours;
    // the hook's tuning constants (HookStorage; internal, no getters: the hook is at the size limit)
    uint256 constant SNIPE_VEST = 10 minutes;
    uint256 constant EMPTY_CIRCULATING = 1_000e18;
    uint256 constant MAX_PASS = 2;
    uint256 constant RESERVE = 1e6;
    int24 constant BURN_MAX_TICKS = 100;
    address burnKeeper = makeAddr("burnKeeper");

    IPoolManager pm;
    FoboFactory factory;
    FoboHook hook;
    FoboRevenue revenue;
    MockEthUsdFeed feed;
    FoboLimitOrders limitOrders;
    FoboBurner burner;
    FoboVesting vesting;
    PoolSwapTest router;
    address team = makeAddr("team");
    address fobo;
    PoolKey foboKey;
    address startSigner;
    uint256 startSignerKey;

    /// A pool's creator: claimCreator's recipient when anyone sends it (address(0) for $FOBO's pool: `to` unused)
    function _creatorOf(PoolKey memory k) internal view returns (address c) {
        (, c,,,,,,,,,,,,,) = hook.pools(k.toId());
    }

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        pm = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolSwapTest(pm);
        vesting = new FoboVesting();
        factory = new FoboFactory(pm, address(this), team, FEE, vesting);
        revenue = new FoboRevenue(pm, address(this), team);
        // deployed before the hook, which names it immutably (it finds the hook through the factory), as Deploy.s.sol does
        feed = new MockEthUsdFeed(8, ETH_USD_8);
        limitOrders =
            new FoboLimitOrders(pm, IFoboFactory(address(factory)), address(this), IAggregatorV3(address(0)), 0);
        limitOrders.setPayToken(address(0), IAggregatorV3(address(feed)), FEED_MAX_AGE, false, true);
        burner = new FoboBurner(pm, address(this));
        address hookAddr = address(uint160(FLAGS) | (uint160(0x4444) << 144));
        address hookRevenue = _revenueForHook();
        deployCodeTo(
            "FoboHook.sol:FoboHook",
            abi.encode(pm, address(factory), hookRevenue, address(limitOrders), address(burner), _isArbitrum()),
            hookAddr
        );
        hook = FoboHook(hookAddr);
        factory.setHook(hook);
        burner.setHook(hook);
        burner.setKeeper(burnKeeper, true);
        // setHook only takes a hook built for this FoboRevenue (a misbehaving one stands in for it in those tests)
        if (hookRevenue == address(revenue)) revenue.setHook(hookAddr);
        (startSigner, startSignerKey) = makeAddrAndKey("startSigner");
        factory.setStartSigner(startSigner);
        factory.setStartBand(FOBO_TICK - BAND_HALF, FOBO_TICK + BAND_HALF);
    }

    /// Summed liquidity of the launch curve's tranches (all on the lower tick MIN_TICK) at a start tick, as _place
    /// computes it.
    function _curveLiquidity(int24 tickStart) internal pure returns (uint256 sum) {
        uint256 supply = 1_000_000_000e18;
        uint256 left = supply - 1e6;
        uint160 sMin = TickMath.getSqrtPriceAtTick(-887220);
        for (uint256 i; i < N_TRANCHES; i++) {
            (uint256 bps, int24 topOff) = Curve.tranche(i);
            uint256 amt = i + 1 == N_TRANCHES ? left : supply * bps / 10_000;
            left -= amt;
            sum += FloorMath.liquidityForToken(sMin, TickMath.getSqrtPriceAtTick(tickStart - topOff), amt);
        }
    }

    function _launchAs(address who, IFoboFactory.LaunchParams memory lp) internal returns (address token) {
        vm.prank(who);
        (token,) = factory.launch{value: FEE}(lp);
    }

    function _expectLaunchRevert(address who, IFoboFactory.LaunchParams memory lp, bytes4 err) internal {
        vm.prank(who);
        vm.expectRevert(err);
        factory.launch{value: FEE}(lp);
    }

    function _dumpAll(PoolKey memory key, address[] memory us) internal {
        address token = Currency.unwrap(key.currency1);
        for (uint256 i; i < us.length; i++) {
            uint256 bal = FoboToken(token).balanceOf(us[i]);
            if (bal == 0) continue;
            _approve(us[i], token);
            _swap(us[i], key, false, -int256(bal), 0); // reverts with PartialFill if the floor couldn't absorb it
        }
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    /// The FoboRevenue the hook is deployed with (tests of a misbehaving one override it)
    function _revenueForHook() internal virtual returns (address) {
        return address(revenue);
    }

    /// The hook counts blocks with ArbSys (Robinhood Chain's deploy) instead of block.number (tests of it override this
    /// and etch a MockArbSys at 0x64)
    function _isArbitrum() internal virtual returns (bool) {
        return false;
    }

    function _launchFobo() internal {
        (fobo,) = factory.launch(_params("FOBO", "FOBO", bytes32(0), 0, FOBO_TICK));
        foboKey = hook.keyFor(address(0), fobo);
    }

    /// $FOBO's own launch params (unsigned)
    function _params(string memory name, string memory ticker, bytes32 salt, uint256 dev, int24 tick)
        internal
        pure
        returns (IFoboFactory.LaunchParams memory)
    {
        return
            IFoboFactory.LaunchParams(name, ticker, "ipfs://x", salt, address(0), dev, type(uint256).max, tick, 0, "", 0);
    }

    /// A FOBO-quoted launch's params, its start signed by the start signer for `creator`, valid for an hour. Tick 0 =
    /// 1 token per $FOBO: the same $10k mcap as $FOBO's start, in the band while $FOBO's price stays within ~2x of it.
    function _signed(address creator, string memory name, string memory ticker, bytes32 salt, uint256 dev, int24 tick)
        internal
        view
        returns (IFoboFactory.LaunchParams memory)
    {
        return _signedBy(startSignerKey, creator, fobo, name, ticker, salt, dev, tick, vm.getBlockTimestamp() + 1 hours);
    }

    /// An ETH-paired launch's params, signed like _signed. Tick FOBO_TICK = $FOBO's own start: the $10k mcap in ETH.
    function _signedEth(
        address creator,
        string memory name,
        string memory ticker,
        bytes32 salt,
        uint256 dev,
        int24 tick
    ) internal view returns (IFoboFactory.LaunchParams memory) {
        return _signedBy(
            startSignerKey, creator, address(0), name, ticker, salt, dev, tick, vm.getBlockTimestamp() + 1 hours
        );
    }

    /// A launch's params (FoboFactory.launch), signed by `key`
    function _signedBy(
        uint256 key,
        address creator,
        address quote,
        string memory name,
        string memory ticker,
        bytes32 salt,
        uint256 dev,
        int24 tick,
        uint256 deadline
    ) internal view returns (IFoboFactory.LaunchParams memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _startDigest(creator, salt, quote, name, ticker, tick, deadline));
        return IFoboFactory.LaunchParams(
            name, ticker, "ipfs://x", salt, quote, dev, type(uint256).max, tick, deadline, abi.encodePacked(r, s, v), 0
        );
    }

    /// The EIP-712 digest of LaunchStart, built here from the spec (no call into the factory, so a prank or an
    /// expectRevert before a launch still applies to the launch itself)
    function _startDigest(
        address creator,
        bytes32 salt,
        address quote,
        string memory name,
        string memory ticker,
        int24 tick,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FoboFactory"),
                keccak256("1"),
                block.chainid,
                address(factory)
            )
        );
        bytes32 typeHash = keccak256(
            "LaunchStart(address creator,bytes32 salt,address quote,string name,string ticker,int24 tickStart,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, creator, salt, quote, keccak256(bytes(name)), keccak256(bytes(ticker)), tick, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// salt so the token sorts after $FOBO
    function _salt(address launcher, string memory name, string memory ticker) internal view returns (bytes32) {
        return _saltAfter(launcher, fobo, name, ticker);
    }

    /// salt so the token sorts after `quote`; derived from the name and ticker, so a creator's launches never share a
    /// salt (a signed start is good for one (creator, salt): StartUsed)
    function _saltAfter(address launcher, address quote, string memory name, string memory ticker)
        internal
        view
        returns (bytes32 s)
    {
        for (uint256 i;; i++) {
            s = keccak256(abi.encode(name, ticker, i));
            if (factory.predictToken(launcher, s, name, ticker) > quote) return s;
        }
    }

    // ---- swaps (always through the router, as a user: `who` is also tx.origin, the trader FoboRevenue credits) ----
    function _swap(address who, PoolKey memory key, bool buy, int256 amount, uint256 value)
        internal
        returns (BalanceDelta d)
    {
        vm.prank(who, who);
        d = router.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: buy,
                amountSpecified: amount,
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _user(string memory name) internal returns (address u) {
        u = makeAddr(name);
        vm.deal(u, 1_000_000 ether);
        vm.startPrank(u);
        if (fobo != address(0)) FoboToken(fobo).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// `who` buys $FOBO with `ethIn` through its pool and lets the factory pull it: a $FOBO pair's initial buy is paid in
    /// $FOBO
    function _fundFobo(address who, uint256 ethIn) internal {
        _swap(who, foboKey, true, -int256(ethIn), ethIn);
        vm.prank(who);
        FoboToken(fobo).approve(address(factory), type(uint256).max);
    }

    function _approve(address who, address token) internal {
        vm.prank(who);
        FoboToken(token).approve(address(router), type(uint256).max);
    }

    function _tick(PoolKey memory key) internal view returns (int24 t) {
        (, t,,) = pm.getSlot0(key.toId());
    }

    function _pool(PoolKey memory key)
        internal
        view
        returns (int24 tickF, uint256 pot, uint256 creatorOwed, uint256 reserve, uint128 liqBand)
    {
        (,,,, tickF,,,,,,, liqBand, pot, creatorOwed, reserve) = hook.pools(key.toId());
    }

    /// Sets a pool's dust reserve (pools[id].reserve, found by matching the public getter: layout-independent). The
    /// hook's claims are left as they are: the reserve no longer accounts for them all.
    function _setReserve(PoolKey memory key, uint256 value) internal {
        bytes32 base = keccak256(abi.encode(PoolId.unwrap(key.toId()), uint256(0)));
        (,,, uint256 r,) = _pool(key);
        for (uint256 i; i < 20; i++) {
            bytes32 slot = bytes32(uint256(base) + i);
            if (uint256(vm.load(address(hook), slot)) == r) {
                vm.store(address(hook), slot, bytes32(value));
                (,,, r,) = _pool(key);
                assertEq(r, value, "the reserve's slot");
                return;
            }
        }
        revert("reserve slot not found");
    }

    function _snipe(PoolKey memory key) internal view returns (uint128 snipePot, uint128 snipeReleased) {
        (,,,,,,,, snipePot, snipeReleased,,,,,) = hook.pools(key.toId());
    }

    function _merged(PoolKey memory key) internal view returns (uint256 m) {
        uint8 m8;
        (,,,,,,,,,, m8,,,,) = hook.pools(key.toId());
        m = m8;
    }

    function _tranche0(PoolKey memory key) internal view returns (int24 top, int24 tickF, uint128 l) {
        (top, l) = hook.trancheOf(key, 0);
        (tickF,,,,) = _pool(key);
    }

    function _rate(uint256 s) internal pure returns (uint256) {
        return s >= 60 ? 25_000 : 900_000 - 875_000 * s / 60;
    }

    function _claims(Currency c) internal view returns (uint256) {
        return pm.balanceOf(address(hook), c.toId());
    }

    /// The tax a swap took, as claims: the hook's plus FoboRevenue's (the protocol fee it shares out) plus FoboBurner's
    /// (the snipe tax's burn share and swept floor money on pairs other than $FOBO)
    function _taxClaims(Currency c) internal view returns (uint256) {
        return pm.balanceOf(address(hook), c.toId()) + pm.balanceOf(address(revenue), c.toId()) + _burnerOwed(c);
    }

    /// What FoboBurner holds of `c` as claims: every burn share the hook handed it, until a buyback spends it
    function _burnerOwed(Currency c) internal view returns (uint256) {
        return pm.balanceOf(address(burner), c.toId());
    }

    /// The keeper's largest ETH buyback the bound lets through right now (halving from all of FoboBurner's ETH claims, no
    /// minimums: a keeper key at its worst): the $FOBO burned, 0 if none fits
    function _buybackMax() internal returns (uint256 burned) {
        for (uint256 amt = _burnerOwed(Currency.wrap(address(0))); amt > 1e12; amt /= 2) {
            vm.prank(burnKeeper, burnKeeper);
            try burner.buybackAndBurn(address(0), amt, 0, 0) returns (uint256, uint256 b) {
                return b;
            } catch {}
        }
    }

    /// The keeper spends half of FoboBurner's ETH claims on $FOBO, unbounded minimums (the bound alone protects it):
    /// false if there was nothing to spend or it reverted (BurnBound when $FOBO moved this block)
    function _tryBuyback() internal returns (bool) {
        uint256 amt = _burnerOwed(Currency.wrap(address(0))) / 2;
        if (amt == 0) return false;
        vm.prank(burnKeeper, burnKeeper);
        try burner.buybackAndBurn(address(0), amt, 0, 0) {
            return true;
        } catch {
            return false;
        }
    }
}

contract FoboTest is FoboBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- bootstrap

    function test_teamCannotBeZero() public {
        vm.expectRevert(IFoboFactory.ZeroAddress.selector);
        new FoboFactory(pm, address(this), address(0), FEE, vesting);

        vm.expectRevert(IFoboFactory.ZeroAddress.selector);
        factory.setTeam(address(0));
    }

    function test_firstLaunchIsOwnerOnlyAndSetsFobo() public {
        vm.prank(makeAddr("rando"));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        factory.launch(_params("X", "X", 0, 0, FOBO_TICK));

        _launchFobo();
        assertEq(factory.fobo(), fobo);
        assertEq(FoboToken(fobo).balanceOf(address(factory)), 0);
        (,,, uint256 reserve,) = _pool(foboKey);
        assertGe(reserve, 1e6);
        (,, uint256 circ) = hook.floorOf(foboKey);
        assertLe(circ, 10, "nothing circulating before the first buy (a few wei of conservative rounding)");
        assertEq(_tick(foboKey), FOBO_TICK);
    }

    /// A later launch pairs with $FOBO and its fee lands in FoboBurner as native ETH (nothing is swapped or burned in
    /// the launch: the keeper's buybackAndBurn spends it later)
    function test_laterLaunchPairsWithFoboAndSendsFeeToBurner() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        uint256 supplyBefore = FoboToken(fobo).totalSupply();
        assertEq(factory.burner(), address(burner), "the factory's burner is the hook's");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        vm.prank(alice);
        vm.expectRevert(IFoboFactory.FeeNotPaid.selector);
        factory.launch(_signed(alice, "Neko", "NEKO", s, 0, 0));

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        (address neko,) = factory.launch{value: 1 ether}(_signed(alice, "Neko", "NEKO", s, 0, 0));
        assertEq(ethBefore - alice.balance, FEE, "only the fee is kept");
        assertEq(address(burner).balance, FEE, "the fee is in FoboBurner, as ETH");
        assertEq(FoboToken(fobo).totalSupply(), supplyBefore, "nothing burned in the launch");
        assertGt(uint160(neko), uint160(fobo));
        PoolKey memory k = hook.keyFor(fobo, neko);
        assertEq(_tick(k), 0);
    }

    function test_saltMustSortAfterFobo() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 bad;
        for (uint256 i;; i++) {
            if (factory.predictToken(alice, bytes32(i), "Neko", "NEKO") < fobo) {
                bad = bytes32(i);
                break;
            }
        }
        vm.prank(alice);
        vm.expectRevert(IFoboFactory.BadSalt.selector);
        factory.launch{value: FEE}(_signed(alice, "Neko", "NEKO", bad, 0, 0));
    }

    function test_cannotAddLiquidityDonateOrInitialize() public {
        _launchFobo();
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        vm.expectRevert();
        lp.modifyLiquidity{value: 1 ether}(
            foboKey,
            IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1e18, salt: 0}),
            ""
        );
        PoolDonateTest don = new PoolDonateTest(pm);
        vm.expectRevert();
        don.donate{value: 1}(foboKey, 1, 0, "");
        PoolKey memory k = hook.keyFor(address(0), address(0xdead));
        vm.expectRevert();
        pm.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    // ---------------------------------------------------------------- tax

    function test_snipeTaxBuyExactIn() public {
        _launchFobo();
        address bob = _user("bob");
        for (uint256 s = 0; s <= 61; s += 30) {
            vm.warp(1_700_000_000 + s);
            uint256 r = _rate(s);
            uint256 claims0 = _taxClaims(foboKey.currency0);
            (, uint256 pot0, uint256 cr0,,) = _pool(foboKey);
            (uint128 sp0,) = _snipe(foboKey);
            uint256 team0 = hook.teamOwed(foboKey.currency0);
            uint256 rev0 = revenue.owed(team, address(0));
            uint256 eth0 = bob.balance;
            _swap(bob, foboKey, true, -1 ether, 1 ether);
            uint256 tax = (1 ether * r + PIPS - 1) / PIPS;
            assertEq(eth0 - bob.balance, 1 ether, "pays exactly the input");
            assertEq(_taxClaims(foboKey.currency0) - claims0, tax, "tax taken as claims");
            (, uint256 pot1, uint256 cr1,,) = _pool(foboKey);
            (uint128 sp1,) = _snipe(foboKey);
            if (s < 60) {
                // $FOBO's own pool: the snipe tax's 40% is its creator fee, not a burn of itself, shared out by
                // FoboRevenue in the swap (no partners, bob has no referrer: the team)
                assertEq(cr1, cr0, "snipe tax: nothing waits in the creator balance");
                assertEq(hook.teamOwed(foboKey.currency0), team0, "nothing to the team in the hook");
                assertEq(revenue.owed(team, address(0)) - rev0, tax * 40 / 100, "40% credited in the swap");
                assertEq(sp1 - sp0, tax - tax * 40 / 100, "60% to the snipe pot");
                assertEq(_burnerOwed(foboKey.currency0), 0, "nothing to the burn");
            } else {
                // $FOBO's creator fee and the protocol fee go to FoboRevenue (no partners, bob has no referrer: the team)
                assertEq(cr1, cr0, "$FOBO's creator fee is shared out by FoboRevenue");
                assertEq(hook.teamOwed(foboKey.currency0), team0, "the protocol fee is shared out by FoboRevenue");
                assertEq(revenue.owed(team, address(0)) - rev0, tax * 6 / 25 + tax * 4 / 25);
                assertEq(sp1, sp0, "after the window nothing vests");
            }
            assertGe(pot1 + 1, pot0, "pot only grows or is spent on the floor");
        }
    }

    function test_taxAllFourRowsAreRofGross() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 100);
        address bob = _user("bob");
        _approve(bob, fobo);
        _swap(bob, foboKey, true, -2 ether, 2 ether); // inventory

        // buy exact-out: pays quoteIn + r/(1-r)
        uint256 c0 = _taxClaims(foboKey.currency0);
        uint256 e0 = bob.balance;
        BalanceDelta d = _swap(bob, foboKey, true, int256(1_000_000e18), 10 ether);
        uint256 paid = e0 - bob.balance;
        uint256 tax = _taxClaims(foboKey.currency0) - c0;
        assertEq(uint256(int256(-d.amount0())), paid);
        assertApproxEqAbs(tax * PIPS, paid * 25_000, PIPS, "2.5% of gross");

        // sell exact-in: receives quoteOut - 2.5%
        c0 = _taxClaims(foboKey.currency0);
        e0 = bob.balance;
        _swap(bob, foboKey, false, -int256(500_000e18), 0);
        uint256 got = bob.balance - e0;
        tax = _taxClaims(foboKey.currency0) - c0;
        assertApproxEqAbs(tax * PIPS, (got + tax) * 25_000, PIPS);

        // sell exact-out: receives exactly what was asked, tax = 2.5% of gross
        c0 = _taxClaims(foboKey.currency0);
        e0 = bob.balance;
        _swap(bob, foboKey, false, int256(0.001 ether), 0);
        assertEq(bob.balance - e0, 0.001 ether);
        tax = _taxClaims(foboKey.currency0) - c0;
        assertApproxEqAbs(tax * PIPS, (0.001 ether + tax) * 25_000, PIPS);
    }

    function test_exactOutBuyAtSnipePays90PercentOfGross() public {
        _launchFobo();
        address bob = _user("bob");
        uint256 c0 = _taxClaims(foboKey.currency0);
        uint256 e0 = bob.balance;
        _swap(bob, foboKey, true, int256(1_000_000e18), 10 ether);
        uint256 paid = e0 - bob.balance;
        uint256 tax = _taxClaims(foboKey.currency0) - c0;
        assertApproxEqAbs(tax * 10, paid * 9, 10, "90% of gross, not 47%");
    }

    function test_partialFillReverts() public {
        _launchFobo();
        address bob = _user("bob");
        // a 10 ETH exact-in buy with its price limit 600 ticks (~6%) up the curve stops at the limit: a partial fill
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(FOBO_TICK - 600)
        });
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(IFoboHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap{value: 10 ether}(
            foboKey, sp, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
    }

    // ---------------------------------------------------------------- floor

    function test_floorRisesAndNeverDrops() public {
        _launchFobo();
        address bob = _user("bob");
        _approve(bob, fobo);
        _swap(bob, foboKey, true, -5 ether, 5 ether); // snipe: half to the pot
        (int24 f0,,,,) = _pool(foboKey);
        assertEq(f0, FOBO_TICK, "no raise in the launch block");
        int24 last = f0;
        for (uint256 i; i < 30; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 20 minutes);
            _swap(bob, foboKey, true, -0.5 ether, 0.5 ether);
            (int24 f,,,,) = _pool(foboKey);
            assertLe(f, last, "tickF only decreases (floor price only rises)");
            last = f;
        }
        assertLt(last, f0, "the floor moved up");
        _dumpAll(foboKey, _one(bob));
    }

    /// A normal raise (the floor has no spare money, so there is nothing to buy back) never moves the price.
    function test_raiseHasNoPriceImpact() public {
        _launchFobo();
        address bob = _user("bob");
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (uint160 s0, int24 t0,,) = pm.getSlot0(foboKey.toId());
        uint128 l0 = pm.getLiquidity(foboKey.toId());
        (int24 f0,,,,) = _pool(foboKey);
        hook.poke(foboKey);
        (int24 f1,,,,) = _pool(foboKey);
        assertLt(f1, f0, "poke raised");
        (uint160 s1, int24 t1,,) = pm.getSlot0(foboKey.toId());
        assertEq(s1, s0);
        assertEq(t1, t0);
        assertEq(pm.getLiquidity(foboKey.toId()), l0, "active liquidity unchanged");
    }

    /// The snipe window's floor share (60% of its tax) joins the pot linearly over SNIPE_VEST from launch, released by raises;
    /// fully in by minute 10, nothing more after. (Organic buying keeps the price well above what the vested pot can
    /// lift the floor to, so every block's raise has room to release.)
    function test_snipeTaxVests() public {
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        _swap(bob, foboKey, true, -5 ether, 5 ether); // ~90% snipe tax: 60% -> snipePot
        (uint128 sp, uint128 rel) = _snipe(foboKey);
        assertGt(sp, 2.6 ether, "the floor share went to the snipe pot");
        assertEq(rel, 0);
        (, uint256 pot,,,) = _pool(foboKey);
        assertLt(pot, 0.1 ether, "not into the pot at once");
        uint256 v = SNIPE_VEST;
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(1_700_000_000 + 61);
        _swap(carol, foboKey, true, -100 ether, 100 ether); // organic buying; its 1.5% goes straight into the pot
        int24 last = FOBO_TICK;
        for (uint256 m = 2; m <= 10; m++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(1_700_000_000 + m * 1 minutes);
            hook.poke(foboKey);
            (, rel) = _snipe(foboKey);
            assertEq(rel, uint256(sp) * m * 1 minutes / v, "released linearly");
            (int24 f,,,,) = _pool(foboKey);
            assertLt(f, last, "every release raises the floor");
            last = f;
        }
        assertEq(rel, sp, "fully released at minute 10");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(carol, foboKey, true, -1 ether, 1 ether);
        (, rel) = _snipe(foboKey);
        assertEq(rel, sp, "nothing more after");
    }

    /// A sniper rugs two minutes in: the base 1.5% from organic buyers is already in the floor and a fifth of the snipe tax
    /// has vested, so the floor is above the start and everyone left can still sell into it; the rest keeps vesting.
    function test_rugInFirstMinutesFloorHolds() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        address dave = _user("dave");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _approve(dave, fobo);
        _swap(bob, foboKey, true, -5 ether, 5 ether); // sniper, second 0
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(1_700_000_000 + 61);
        _swap(carol, foboKey, true, -2 ether, 2 ether);
        _swap(dave, foboKey, true, -2 ether, 2 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(1_700_000_000 + 2 minutes);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0); // rug
        (int24 fRug,,,,) = _pool(foboKey);
        assertLt(fRug, FOBO_TICK, "the floor is already above the start at the rug");
        assertLe(_tick(foboKey), fRug + 60, "the price is held by the floor band");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(1_700_000_000 + 10 minutes);
        hook.poke(foboKey);
        (int24 f10,,,,) = _pool(foboKey);
        assertLt(f10, fRug, "the rest of the snipe tax lifts the floor after the rug");
        (uint128 sp, uint128 rel) = _snipe(foboKey);
        assertEq(rel, sp);
        uint256 c0 = carol.balance;
        address[] memory us = new address[](2);
        us[0] = carol;
        us[1] = dave;
        _dumpAll(foboKey, us);
        emit log_named_uint("carol paid (wei)", 2 ether);
        emit log_named_uint("carol got back after the rug (wei)", carol.balance - c0);
        assertGt(carol.balance - c0, 1 ether, "holders keep most of their money");
        _assertNoRaiseFailed();
    }

    /// Minute-10 grab: a holder who sells right as the snipe pot finishes vesting gets at most a fair share of it, not
    /// most of it, while others hold.
    function test_minute10GrabTakesNoMoreThanItsShare() public {
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        address dave = _user("dave");
        address eve = _user("eve");
        _approve(eve, fobo);
        _swap(bob, foboKey, true, -10 ether, 10 ether); // sniper, second 0
        (uint128 sp,) = _snipe(foboKey);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(1_700_000_000 + 61);
        _swap(carol, foboKey, true, -2 ether, 2 ether);
        _swap(dave, foboKey, true, -2 ether, 2 ether);
        uint256 e0 = eve.balance;
        _swap(eve, foboKey, true, -2 ether, 2 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(1_700_000_000 + 10 minutes);
        hook.poke(foboKey); // the whole snipe pot is in the floor
        (, uint128 rel) = _snipe(foboKey);
        assertEq(rel, sp);
        _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
        int256 pnl = int256(eve.balance) - int256(e0);
        emit log_named_uint("vested snipe pot (wei)", sp);
        emit log_named_int("eve pnl (wei)", pnl);
        assertLt(pnl, int256(uint256(sp) / 2), "can't take most of the vested pot");
    }

    /// Pinned-floor harvest: after a rug the vested snipe tax is more than the floor can use under the price. The spare
    /// money buys back and burns tokens, lifting the price to what the tokens are backed by, so there is nothing left to
    /// harvest: pumping, holding (one block to an hour), poking (once or twice) and selling always loses.
    function test_pinnedFloorCannotBeHarvested() public {
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _swap(bob, foboKey, true, -2 ether, 2 ether); // sniper at 0 s: 90% tax, 60% of it -> snipePot
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -1 ether, 1 ether); // organic holder
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0); // rug at minute 5, half vested
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours); // snipe pot fully vested
        hook.poke(foboKey);
        (int24 f0,,,,) = _pool(foboKey);
        assertEq(f0 - _tick(foboKey), 120, "the floor sits two spacings under the lifted price");
        uint256 carolExit = _exitValue(carol);
        assertGt(carolExit, 1.4 ether, "the holder gets the floor share of the sniper's tax");
        uint256[8] memory sizes =
            [uint256(0.1 ether), 0.25 ether, 0.5 ether, 1 ether, 2 ether, 4 ether, 8 ether, 30 ether];
        uint256[3] memory waits = [uint256(1), 5, 300]; // blocks of 12 s: one block, a minute, an hour
        for (uint256 i; i < sizes.length; i++) {
            for (uint256 w; w < waits.length; w++) {
                for (uint256 pokes = 1; pokes <= 2; pokes++) {
                    uint256 snap = vm.snapshotState();
                    address eve = _user("eve");
                    _approve(eve, fobo);
                    uint256 e0 = eve.balance;
                    _swap(eve, foboKey, true, -int256(sizes[i]), sizes[i]); // pump
                    vm.roll(vm.getBlockNumber() + waits[w]);
                    vm.warp(vm.getBlockTimestamp() + 12 * waits[w]);
                    hook.poke(foboKey);
                    if (pokes == 2) {
                        vm.roll(vm.getBlockNumber() + 1);
                        vm.warp(vm.getBlockTimestamp() + 12);
                        hook.poke(foboKey);
                    }
                    _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
                    assertLt(eve.balance, e0, "the pumper loses");
                    (int24 f1,,,,) = _pool(foboKey);
                    assertLe(f1, f0, "the floor never drops");
                    assertGe(_exitValue(carol) + 2, carolExit, "the holder exits at least as well as before");
                    vm.revertToState(snap);
                }
            }
        }
    }

    /// An absurd pot (1e12 ETH of floor money behind one small holder): the buyback lifts the price to the next tranche's
    /// start, the band takes no more than the holder's tokens can carry there (and never more liquidity than v4's
    /// per-tick cap leaves: no TickLiquidityOverflow, no RaiseFailed), and the rest leaves the floor (FloorSwept; $FOBO's
    /// own pool: to the team), fully accounted for; the holder can still sell into the floor.
    function test_absurdPotLeavesWhatNoHolderCanCarry() public {
        _launchFobo();
        address carol = _user("carol");
        _approve(carol, fobo);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -0.01 ether, 0.01 ether);
        // the pot (slot 5 of the pool's struct) and the hook's ETH claims grow by the same amount
        uint256 extra = 1e12 ether;
        vm.deal(address(this), extra);
        new ClaimsGifter(pm).gift{value: extra}(address(hook));
        bytes32 potSlot = bytes32(uint256(keccak256(abi.encode(foboKey.toId(), uint256(0)))) + 5);
        vm.store(address(hook), potSlot, bytes32(uint256(vm.load(address(hook), potSlot)) + extra));
        uint256 team0 = hook.teamOwed(Currency.wrap(address(0)));
        vm.roll(vm.getBlockNumber() + 1);
        vm.recordLogs();
        hook.poke(foboKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swept;
        bool bought;
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "no RaiseFailed");
            if (logs[i].topics[0] == IFoboHook.BoughtBack.selector) bought = true;
            if (logs[i].topics[0] != IFoboHook.FloorSwept.selector) continue;
            (uint256 a, bool burn) = abi.decode(logs[i].data, (uint256, bool));
            assertFalse(burn, "$FOBO's own pool: to the team");
            swept += a;
        }
        assertTrue(bought, "the buyback lifted the holder");
        assertGt(swept, extra - extra / 1e6, "what no holder can carry left the floor");
        assertEq(hook.teamOwed(Currency.wrap(address(0))) - team0, swept);
        (int24 tickF, uint256 pot, uint256 creatorOwed,, uint128 lb) = _pool(foboKey);
        (uint128 placed,) = pm.getTickLiquidity(foboKey.toId(), Ticks.MIN_TICK);
        assertLe(lb, Pool.tickSpacingToMaxLiquidityPerTick(60) - placed, "within v4's per-tick cap");
        uint256 bandQ =
            FloorMath.quote(TickMath.getSqrtPriceAtTick(tickF), TickMath.getSqrtPriceAtTick(tickF + 60), lb, true);
        assertLt(pot + bandQ, extra / 1e6, "the floor keeps only what the holder can carry");
        assertEq(_claims(Currency.wrap(address(0))), pot + hook.teamOwed(Currency.wrap(address(0))) + creatorOwed);
        _swap(carol, foboKey, false, -int256(FoboToken(fobo).balanceOf(carol)), 0);
        assertLe(_tick(foboKey), tickF + 60, "the exit stops in the band");
    }

    /// The band never takes more liquidity than v4's per-tick cap leaves at its ticks (Ctx.lbMax: the cap less everything
    /// placed at MIN_TICK). A real pool only gets there at prices far past any curve's, so the hook's read of MIN_TICK's
    /// liquidity is made to report all but `room` of the cap: a raise funded far beyond it puts exactly lbMax in the band
    /// (no TickLiquidityOverflow, no RaiseFailed), its search counts only that much, the rest waits in the pot (the
    /// holders can carry it: the cap on floor money doesn't bind), and every holder still exits into the floor.
    function test_bandLiquidityIsCappedAtTheTickLimit() public {
        _launchFobo();
        address carol = _user("carol");
        _approve(carol, fobo);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -5 ether, 5 ether);
        uint256 extra = 1 ether;
        vm.deal(address(this), extra);
        new ClaimsGifter(pm).gift{value: extra}(address(hook));
        bytes32 potSlot = bytes32(uint256(keccak256(abi.encode(foboKey.toId(), uint256(0)))) + 5);
        vm.store(address(hook), potSlot, bytes32(uint256(vm.load(address(hook), potSlot)) + extra));
        uint128 room = 2e24; // a third of what this raise would put in the band unclamped (~6.5e24)
        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(60);
        bytes32 slot = StateLibrary._getTickInfoSlot(foboKey.toId(), Ticks.MIN_TICK);
        bytes32 real = vm.load(address(pm), slot);
        // liquidityGross is the low 128 bits, liquidityNet the high ones (kept)
        bytes32 fake = (real >> 128 << 128) | bytes32(uint256(cap - room));
        vm.mockCall(address(pm), abi.encodeWithSignature("extsload(bytes32)", slot), abi.encode(fake));
        (int24 f0, uint256 pot0,,,) = _pool(foboKey);
        vm.roll(vm.getBlockNumber() + 1);
        vm.recordLogs();
        hook.poke(foboKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool raised;
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "no RaiseFailed");
            assertTrue(logs[i].topics[0] != IFoboHook.FloorSwept.selector, "nothing beyond what the holders carry");
            if (logs[i].topics[0] == IFoboHook.FloorRaised.selector) raised = true;
        }
        vm.clearMockedCalls();
        assertTrue(raised, "raised");
        (int24 tickF, uint256 pot, uint256 creatorOwed,, uint128 lb) = _pool(foboKey);
        assertLt(tickF, f0, "the floor moved up");
        assertEq(lb, room, "the band is at the cap");
        uint256 bandQ =
            FloorMath.quote(TickMath.getSqrtPriceAtTick(tickF), TickMath.getSqrtPriceAtTick(tickF + 60), lb, true);
        assertLt(bandQ, pot0, "the band holds less than the pot alone could fund");
        assertGt(pot, pot0 * 3 / 4, "what the band can't take waits in the pot");
        assertEq(
            _claims(Currency.wrap(address(0))),
            pot + hook.teamOwed(Currency.wrap(address(0))) + creatorOwed + _burnerOwed(Currency.wrap(address(0)))
        );
        _swap(carol, foboKey, false, -int256(FoboToken(fobo).balanceOf(carol)), 0);
        assertLe(_tick(foboKey), tickF + 60, "the exit stops in the band");
    }

    /// The floor's spare money buys back and burns tokens: supply drops by exactly what is burned, the price rises, the
    /// floor follows two spacings under it, and almost nothing is left that the holders can't reach.
    function test_spareFloorMoneyBuysBackAndBurns() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _swap(bob, foboKey, true, -2 ether, 2 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -1 ether, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 supply0 = FoboToken(fobo).totalSupply();
        int24 t0 = _tick(foboKey);
        (int24 f0,,,,) = _pool(foboKey);
        (,, uint256 circ0) = hook.floorOf(foboKey);
        Vm.Log[] memory logs0 = vm.getRecordedLogs(); // drop the launch's logs
        logs0;
        hook.poke(foboKey);
        uint256 burned;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IFoboHook.BoughtBack.selector) {
                (burned,) = abi.decode(logs[i].data, (uint256, uint160));
            }
        }
        assertGt(burned, 0, "bought back");
        assertEq(supply0 - FoboToken(fobo).totalSupply(), burned, "burned exactly what it bought");
        (,, uint256 circ1) = hook.floorOf(foboKey);
        assertApproxEqAbs(circ1, circ0, 10, "holders' tokens untouched");
        assertLt(_tick(foboKey), t0, "price lifted");
        (int24 f1,,,,) = _pool(foboKey);
        assertLt(f1, f0, "floor lifted");
        assertEq(f1 - _tick(foboKey), 120);
        // everyone left sells: what stays in the pool is a sliver of the snipe pot
        uint256 c0 = carol.balance;
        _dumpAll(foboKey, _one(carol));
        (uint128 sp,) = _snipe(foboKey);
        (,, uint256 creatorOwed,,) = _pool(foboKey);
        uint256 left = address(pm).balance - creatorOwed - hook.teamOwed(foboKey.currency0)
            - pm.balanceOf(address(revenue), foboKey.currency0.toId());
        assertLt(left, uint256(sp) / 20, "under 5% of the snipe pot is out of the holders' reach");
        assertGt(carol.balance - c0, 1.4 ether, "carol paid 1 ETH and gets the floor share of the sniper's tax");
        _assertNoRaiseFailed();
    }

    /// A rug that sells into the floor band leaves the price inside it. The buyback still runs there (it burns what the
    /// band bought), so the rest of the snipe pot reaches the holder instead of the first big buyer.
    function test_rugIntoTheBandStillPaysHolders() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _swap(bob, foboKey, true, -20 ether, 20 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -1 ether, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        hook.poke(foboKey); // this block's raise is spent: the rug's own swap can't lift the price back out
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        (int24 fRug,,,,) = _pool(foboKey);
        assertGe(_tick(foboKey), fRug, "the rug left the price inside the band");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        hook.poke(foboKey);
        (int24 f,,,,) = _pool(foboKey);
        assertEq(f - _tick(foboKey), 120, "lifted out of the band, floor under it");
        // the sniper held half the vesting time and was paid his share on the way out; carol gets the rest
        assertGt(_exitValue(carol), 5.5 ether, "carol (paid 1 ETH) gets the floor share of the sniper's tax");
        address eve = _user("eve");
        _approve(eve, fobo);
        uint256 e0 = eve.balance;
        _swap(eve, foboKey, true, -10 ether, 10 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        hook.poke(foboKey);
        _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
        assertLt(eve.balance, e0, "a buyer behind the holder can't take it");
        _assertNoRaiseFailed();
    }

    /// Almost nobody holds after a rug (100 ETH sniped, 0.1 ETH organic): there is no backing-ratio gate holding the money
    /// back for the next buyer. The next raise buys back and burns with the one holder left, so she gets the sniper's
    /// vested tax, in one lift, and a buyer after it pays the lifted price (the attack suites try every way in).
    function test_almostNobodyHoldsTheHolderGetsTheBacking() public {
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        _approve(bob, fobo);
        _swap(bob, foboKey, true, -100 ether, 100 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -0.1 ether, 0.1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        int24 t0 = _tick(foboKey);
        uint256 supply0 = FoboToken(fobo).totalSupply();
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        hook.poke(foboKey);
        assertLt(_tick(foboKey), t0, "price lifted");
        assertLt(FoboToken(fobo).totalSupply(), supply0, "bought back and burned");
        (, uint256 pot,,,) = _pool(foboKey);
        uint256 carolExit = _exitValue(carol);
        emit log_named_decimal_uint("carol's exit (paid 0.1 ETH)", carolExit, 18);
        emit log_named_decimal_uint("left in the pot", pot, 18);
        assertGt(carolExit, 25 ether, "the holder gets the floor share of the sniper's vested tax (54 ETH)");
        assertLt(pot, 0.001 ether, "the lift spends it");
        // one lift spends it: the next block has nothing left to buy back
        vm.roll(vm.getBlockNumber() + 1);
        uint256 supply1 = FoboToken(fobo).totalSupply();
        hook.poke(foboKey);
        assertEq(FoboToken(fobo).totalSupply(), supply1, "nothing left for a second buyback");
    }

    /// Vesting follows the timestamp, raises follow the block number: time passing inside one block releases nothing
    /// until the next block's raise, and then exactly what vested.
    function test_vestingWaitsForTheNextBlock() public {
        _launchFobo();
        address bob = _user("bob");
        _swap(bob, foboKey, true, -20 ether, 20 ether);
        (uint128 sp,) = _snipe(foboKey);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(1_700_000_000 + 2 minutes);
        hook.poke(foboKey);
        (int24 f0,,,,) = _pool(foboKey);
        (, uint128 rel0) = _snipe(foboKey);
        assertEq(rel0, uint256(sp) * 2 / 10);
        vm.warp(1_700_000_000 + 7 minutes); // same block.number
        hook.poke(foboKey);
        _swap(bob, foboKey, true, -0.1 ether, 0.1 ether);
        (int24 f1,,,,) = _pool(foboKey);
        (, uint128 rel1) = _snipe(foboKey);
        assertEq(f1, f0, "one raise per block");
        assertEq(rel1, rel0, "nothing released without a raise");
        vm.roll(vm.getBlockNumber() + 1);
        hook.poke(foboKey);
        (int24 f2,,,,) = _pool(foboKey);
        (, uint128 rel2) = _snipe(foboKey);
        assertLt(f2, f1);
        assertEq(rel2, uint256(sp) * 7 / 10, "next block releases what vested by now");
    }

    function test_flashPumpRaiseDumpIsUnprofitable() public {
        _launchFobo();
        address bob = _user("bob");
        _approve(bob, fobo);
        _swap(bob, foboKey, true, -3 ether, 3 ether);
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        vm.roll(vm.getBlockNumber() + 1);
        address eve = _user("eve");
        _approve(eve, fobo);
        uint256 e0 = eve.balance;
        _swap(eve, foboKey, true, -100 ether, 100 ether); // pump; the raise in this swap uses the start-of-block tick
        _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0); // dump in the same block
        assertLt(eve.balance, e0, "attacker loses");
    }

    function test_revertingCreatorCannotBlockTrading() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        RevertingReceiver bad = new RevertingReceiver();
        vm.deal(address(bad), 10 ether);
        bytes32 s = _salt(address(bad), "Bad", "BAD");
        vm.prank(address(bad));
        (address tok,) = factory.launch{value: FEE}(_signed(address(bad), "Bad", "BAD", s, 0, 0));
        PoolKey memory k = hook.keyFor(fobo, tok);
        address bob = _user("bob");
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(bob, k, true, -int256(1_000_000e18), 0); // $FOBO in
        // RevertingReceiver can't receive ETH, but the creator share here is $FOBO; swaps never push anything anyway
        _swap(bob, k, true, -int256(1_000_000e18), 0);
    }

    /// The owner can lower the dev-buy cap for new launches and raise it back, never above DEV_BUY_MAX (5%)
    function test_setDevBuyMax() public {
        uint256 max = factory.DEV_BUY_MAX();
        assertEq(factory.devBuyMax(), max);
        address stranger = _user("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        factory.setDevBuyMax(1);
        vm.expectRevert(IFoboFactory.DevBuyTooBig.selector);
        factory.setDevBuyMax(max + 1);
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        _fundFobo(alice, 5 ether);
        factory.setDevBuyMax(20_000_000e18); // 2%
        bytes32 s = _salt(alice, "Neko", "NEKO");
        IFoboFactory.LaunchParams memory over = _signed(alice, "Neko", "NEKO", s, 20_000_001e18, 0);
        IFoboFactory.LaunchParams memory atCap = _signed(alice, "Neko", "NEKO", s, 20_000_000e18, 0);
        vm.prank(alice);
        vm.expectRevert(IFoboFactory.DevBuyTooBig.selector);
        factory.launch{value: 1 ether}(over);
        vm.prank(alice);
        factory.launch{value: 1 ether}(atCap);
        factory.setDevBuyMax(max);
        assertEq(factory.devBuyMax(), max);
    }

    function test_devBuy() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        vm.prank(alice);
        vm.expectRevert(IFoboFactory.DevBuyTooBig.selector);
        factory.launch{value: 1 ether}(_signed(alice, "Neko", "NEKO", s, 50_000_001e18, 0));

        _fundFobo(alice, 5 ether);
        uint256 e0 = alice.balance;
        uint256 f0 = FoboToken(fobo).balanceOf(alice);
        vm.prank(alice);
        (address neko,) = factory.launch{value: 10 ether}(_signed(alice, "Neko", "NEKO", s, 50_000_000e18, 0));
        assertEq(FoboToken(neko).balanceOf(alice), 50_000_000e18);
        assertEq(e0 - alice.balance, FEE, "only the fee in ETH: the rest refunded");
        assertLt(FoboToken(fobo).balanceOf(alice), f0, "the initial buy is paid in $FOBO");
        PoolKey memory k = hook.keyFor(fobo, neko);
        (, uint256 pot, uint256 cr,,) = _pool(k);
        assertGt(cr, 0, "dev buy pays the normal split, not the snipe tax: the creator fee is owed");
        assertApproxEqRel(pot, cr * 5 / 2, 0.01e18); // 1.5% floor vs 0.6% creator
        uint256 f1 = FoboToken(fobo).balanceOf(alice);
        hook.claimCreator(k, alice);
        assertEq(FoboToken(fobo).balanceOf(alice) - f1, cr, "claimed, in $FOBO");
        // the creator dumps it all straight away: the floor still holds
        _approve(alice, neko);
        _swap(alice, k, false, -int256(50_000_000e18), 0);
    }

    /// The launcher's devBuyMaxCost bounds what the initial buy may cost on every pair, in the pair's quote: ETH on an ETH
    /// pair (msg.value alone only bounded it by what was sent), $FOBO or the token on any other.
    function test_devBuyMaxCostBoundsEveryPair() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        FoboToken usd = new FoboToken("USD", "USD");
        factory.setQuoteBand(address(usd), -BAND_HALF, BAND_HALF);
        factory.setQuoteAllowed(address(usd), true);
        usd.transfer(alice, 50_000_000e18);
        vm.prank(alice);
        usd.approve(address(factory), type(uint256).max);
        _fundFobo(alice, 5 ether);
        IFoboFactory.LaunchParams[3] memory lps = [
            _signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 10_000_000e18, FOBO_TICK),
            _signed(alice, "Neko", "NEKO", _salt(alice, "Neko", "NEKO"), 10_000_000e18, 0),
            _signedBy(
                startSignerKey,
                alice,
                address(usd),
                "Usdy",
                "USDY",
                _saltAfter(alice, address(usd), "Usdy", "USDY"),
                10_000_000e18,
                0,
                vm.getBlockTimestamp() + 1 hours
            )
        ];
        for (uint256 i; i < 3; i++) {
            // what it costs right now (ETH spent less the fee, or the quote pulled)
            uint256 snap = vm.snapshotState();
            uint256 e0 = alice.balance;
            uint256 f0 = FoboToken(fobo).balanceOf(alice);
            uint256 u0 = usd.balanceOf(alice);
            vm.prank(alice);
            factory.launch{value: 1 ether}(lps[i]);
            // the creator fee (she is the creator) is owed to her, never paid back in the swap
            uint256 cost = i == 0
                ? e0 - alice.balance - FEE
                : i == 1 ? f0 - FoboToken(fobo).balanceOf(alice) : u0 - usd.balanceOf(alice);
            vm.revertToState(snap);
            assertGt(cost, 0);
            lps[i].devBuyMaxCost = cost - 1;
            _expectLaunchRevert(alice, lps[i], IFoboFactory.DevBuyTooExpensive.selector);
            lps[i].devBuyMaxCost = cost;
            vm.prank(alice);
            factory.launch{value: 1 ether}(lps[i]);
        }
    }

    /// The factory pays the base rate only on the pool it is launching (attack E4): in $FOBO's snipe window a child
    /// launch trades nothing in the $FOBO pool (its fee goes to FoboBurner as ETH, its buy is paid in $FOBO), and the
    /// child's own buy pays the base rate.
    function test_factoryPaysTheBaseRateOnlyOnItsOwnLaunch() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 1); // $FOBO at s = 1
        address alice = _user("alice");
        _fundFobo(alice, 5 ether);
        IFoboFactory.LaunchParams memory lp =
            _signed(alice, "Neko", "NEKO", _salt(alice, "Neko", "NEKO"), 10_000_000e18, 0);
        vm.recordLogs();
        vm.prank(alice);
        (address neko,) = factory.launch{value: 10 ether}(lp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 foboId = PoolId.unwrap(foboKey.toId());
        bytes32 nekoId = PoolId.unwrap(hook.keyFor(fobo, neko).toId());
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != IFoboHook.TaxPaid.selector) continue;
            (, uint256 volume, uint256 toFloor, uint256 toCreator, uint256 toTeam, uint256 toBurn) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256));
            assertTrue(logs[i].topics[1] != foboId, "no swap in the $FOBO pool");
            assertEq(logs[i].topics[1], nekoId);
            assertEq(toBurn, 0, "no snipe burn share");
            assertApproxEqRel(toFloor + toCreator + toTeam, volume * 25_000 / PIPS, 0.001e18, "at the base rate");
            assertGt(toCreator, 0, "the child's buy pays the base split");
            seen++;
        }
        assertEq(seen, 1, "the child buy only");
        assertEq(address(burner).balance, FEE, "the fee went to FoboBurner");
    }

    /// Informational fixes: ownership transfers and the hook announce themselves; start bands can't go below
    /// the lowest start createPool accepts.
    function test_factoryInfoFixes() public {
        _launchFobo();
        address next = makeAddr("next");
        vm.expectEmit(true, true, false, false, address(factory));
        emit Ownable2Step.OwnershipTransferStarted(address(this), next);
        factory.transferOwnership(next);

        // setHook only takes a hook built for this factory, once
        FoboFactory f2 = new FoboFactory(pm, address(this), team, FEE, vesting);
        vm.expectRevert(IFoboFactory.ZeroAddress.selector);
        f2.setHook(IFoboHook(address(0)));
        vm.expectRevert(IFoboFactory.BadHook.selector);
        f2.setHook(hook); // hook.factory() is the other factory: every launch on f2 would revert NotFactory, forever
        vm.mockCall(address(hook), abi.encodeCall(IFoboHook.factory, ()), abi.encode(address(f2)));
        vm.expectEmit(true, false, false, true, address(f2));
        emit IFoboFactory.ConfigChanged("hook", uint256(uint160(address(hook))));
        f2.setHook(hook);
        vm.clearMockedCalls();
        vm.expectRevert(IFoboFactory.HookSet.selector);
        f2.setHook(hook);

        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setStartBand(Ticks.MIN_START_TICK - 60, Ticks.MIN_START_TICK + 60);
        factory.setStartBand(Ticks.MIN_START_TICK, Ticks.MIN_START_TICK + 60);
        address usd = address(new FoboToken("USD", "USD"));
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setQuoteBand(usd, Ticks.MIN_START_TICK - 60, Ticks.MIN_START_TICK + 60);
        factory.setQuoteBand(usd, Ticks.MIN_START_TICK, Ticks.MIN_START_TICK + 60);
    }

    // ---------------------------------------------------------------- invariant fuzz

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_everyoneCanAlwaysExitAboveTheFloor(uint256 seed) public {
        vm.recordLogs();
        _launchFobo();
        address[] memory us = new address[](3);
        us[0] = _user("u0");
        us[1] = _user("u1");
        us[2] = _user("u2");
        for (uint256 i; i < 3; i++) {
            _approve(us[i], fobo);
        }
        for (uint256 i; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address u = us[seed % 3];
            vm.warp(vm.getBlockTimestamp() + (seed >> 8) % 3 hours);
            if ((seed >> 40) % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            uint256 bal = FoboToken(fobo).balanceOf(u);
            if ((seed >> 16) % 3 != 0 || bal == 0) {
                uint256 amt = 0.01 ether + (seed >> 24) % 20 ether;
                _swap(u, foboKey, true, -int256(amt), amt);
            } else {
                _swap(u, foboKey, false, -int256(bal * ((seed >> 32) % 100 + 1) / 100), 0);
            }
            if ((seed >> 48) % 4 == 0) {
                vm.roll(vm.getBlockNumber() + 1);
                hook.poke(foboKey);
            }
        }
        (int24 tickF,,,,) = _pool(foboKey);
        _dumpAll(foboKey, us);
        assertLe(_tick(foboKey), tickF + 60, "price ended inside the band, never past it");
        _assertNoRaiseFailed();
    }

    /// The whole circulating supply in one pair of hands, sold into the floor in a single swap: the floor takes all of
    /// it (no revert, no partial fill) and the price ends inside the band. The exit guarantee's margin is the hook's
    /// rounding (supply up, capacity down): this exercises it rather than states it. Runs at the suite's 1000.
    function testFuzz_wholeCirculatingSupplySellsInOneSwap(uint256 seed) public {
        address whale = _randomMarket(seed);
        _swap(whale, foboKey, false, -int256(FoboToken(fobo).balanceOf(whale)), 0);
        assertEq(FoboToken(fobo).balanceOf(whale), 0, "every token sold");
        _assertInsideTheBand();
        _assertNoRaiseFailed();
    }

    /// The same supply sold in many small pieces (1–15% of what is left each, the last piece the rest), across blocks,
    /// so raises land between them: every piece fills and the price ends inside the band.
    function testFuzz_wholeCirculatingSupplySellsInManySmallSwaps(uint256 seed) public {
        address whale = _randomMarket(seed);
        uint256 left = FoboToken(fobo).balanceOf(whale);
        for (uint256 i; left != 0; i++) {
            seed = uint256(keccak256(abi.encode(seed, "piece", i)));
            uint256 piece = i < 39 ? left * (seed % 15 + 1) / 100 : left;
            if (piece == 0) piece = left;
            if ((seed >> 8) % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            if ((seed >> 16) % 5 == 0) vm.warp(vm.getBlockTimestamp() + 1 hours);
            _swap(whale, foboKey, false, -int256(piece), 0);
            left -= piece;
        }
        assertEq(FoboToken(fobo).balanceOf(whale), 0, "every token sold");
        _assertInsideTheBand();
        _assertNoRaiseFailed();
    }

    /// A $FOBO market with a random history, then every token outside the pool in one holder's hands: a launch at a
    /// random start tick (the lowest createPool accepts to ~2x cheaper than $FOBO's), 25 random buys from 0.01 ETH to
    /// ~5.4M ETH (log-uniform: the price runs through tranche starts), partial sells, block changes and pokes (raises)
    /// by three holders, who then hand everything to the first.
    /// @return whale the holder of the whole circulating supply
    function _randomMarket(uint256 seed) internal returns (address whale) {
        vm.recordLogs();
        int24 steps = (FOBO_TICK + 2 * BAND_HALF - Ticks.MIN_START_TICK) / Ticks.SPACING;
        int24 start = Ticks.MIN_START_TICK + int24(int256((seed >> 200) % uint256(int256(steps)))) * Ticks.SPACING;
        (fobo,) = factory.launch(_params("FOBO", "FOBO", bytes32(0), 0, start));
        foboKey = hook.keyFor(address(0), fobo);
        address[] memory us = new address[](3);
        for (uint256 i; i < 3; i++) {
            us[i] = _user(string(abi.encodePacked("u", vm.toString(i))));
            _approve(us[i], fobo);
            vm.deal(us[i], 1e30);
        }
        for (uint256 i; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address u = us[seed % 3];
            vm.warp(vm.getBlockTimestamp() + (seed >> 8) % 6 hours);
            if ((seed >> 40) % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            uint256 bal = FoboToken(fobo).balanceOf(u);
            if ((seed >> 16) % 3 != 0 || bal == 0) {
                uint256 amt = 0.01 ether * 2 ** ((seed >> 24) % 30); // 0.01 ETH .. ~5.4M ETH
                _swap(u, foboKey, true, -int256(amt), amt);
            } else {
                _swap(u, foboKey, false, -int256(bal * ((seed >> 32) % 100 + 1) / 100), 0);
            }
            if ((seed >> 48) % 4 == 0) {
                vm.roll(vm.getBlockNumber() + 1);
                hook.poke(foboKey);
            }
        }
        whale = us[0];
        for (uint256 i = 1; i < 3; i++) {
            uint256 bal = FoboToken(fobo).balanceOf(us[i]);
            vm.prank(us[i]);
            FoboToken(fobo).transfer(whale, bal);
        }
        uint256 inPool = FoboToken(fobo).balanceOf(address(pm)) + FoboToken(fobo).balanceOf(address(hook));
        assertEq(FoboToken(fobo).balanceOf(whale), FoboToken(fobo).totalSupply() - inPool, "the whole circulating supply");
    }

    /// After the whole circulating supply is sold, the $FOBO pool's price sits inside its floor band, [tickF, tickF +
    /// SPACING], or just above its top: never past its bottom (the exit guarantee). It ends above the top when the curve
    /// above the band had more capacity than the supply: with no raise yet the supply all came out of that curve and
    /// sells back to where it began, one tick above tickF (v4 rounds the final sqrt price down: measured 1 tick,
    /// sqrtP = 0.999999999 x sqrtPrice(tickF)); after raises, by the floor's own margin (supply rounded up, capacity
    /// down: measured up to 5 ticks, 0.02% in price). Up to one spacing (0.6%) is that margin; more would be a change
    /// in the floor's sizing worth looking at.
    function _assertInsideTheBand() internal view {
        (int24 tickF,,,,) = _pool(foboKey);
        int24 t = _tick(foboKey);
        assertGe(t, tickF - Ticks.SPACING, "price ended in the band or within a spacing above it");
        assertLe(t, tickF + Ticks.SPACING, "price ended inside the band, never past it");
    }

    /// Same, with buys from 0.01 to ~5.4M ETH (log-uniform): the price runs through several tranche starts ($1B, $10B,
    /// $100B, ...) and in most runs the floor merges tranches on the way.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_floorHoldsAcrossTranches(uint256 seed) public {
        vm.recordLogs();
        _launchFobo();
        address[] memory us = new address[](3);
        us[0] = _user("u0");
        us[1] = _user("u1");
        us[2] = _user("u2");
        for (uint256 i; i < 3; i++) {
            _approve(us[i], fobo);
            vm.deal(us[i], 1e30);
        }
        for (uint256 i; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address u = us[seed % 3];
            vm.warp(vm.getBlockTimestamp() + (seed >> 8) % 6 hours);
            if ((seed >> 40) % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            uint256 bal = FoboToken(fobo).balanceOf(u);
            if ((seed >> 16) % 3 != 0 || bal == 0) {
                uint256 amt = 0.01 ether * 2 ** ((seed >> 24) % 30); // 0.01 ETH .. ~5.4M ETH
                _swap(u, foboKey, true, -int256(amt), amt);
            } else {
                _swap(u, foboKey, false, -int256(bal * ((seed >> 32) % 100 + 1) / 100), 0);
            }
            if ((seed >> 48) % 4 == 0) {
                vm.roll(vm.getBlockNumber() + 1);
                hook.poke(foboKey);
            }
        }
        (int24 tickF,,,,) = _pool(foboKey);
        _dumpAll(foboKey, us);
        assertLe(_tick(foboKey), tickF + 60, "price ended inside the band, never past it");
        _assertNoRaiseFailed();
    }

    /// Same, on a FOBO-quoted pool (quote is an ERC-20, token sorts after it).
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_foboQuotedPoolFloorHolds(uint256 seed) public {
        vm.recordLogs();
        _launchFobo();
        address whale = _user("whale");
        _swap(whale, foboKey, true, -0.15 ether, 0.15 ether); // FOBO inventory for everyone
        vm.warp(vm.getBlockTimestamp() + 61);
        bytes32 salt = _salt(whale, "Neko", "NEKO");
        vm.prank(whale);
        (address neko,) = factory.launch{value: FEE}(_signed(whale, "Neko", "NEKO", salt, 0, 0));
        PoolKey memory k = hook.keyFor(fobo, neko);
        address[] memory us = new address[](3);
        for (uint256 i; i < 3; i++) {
            us[i] = _user(string(abi.encodePacked("n", vm.toString(i))));
            uint256 share = FoboToken(fobo).balanceOf(whale) / 4;
            vm.prank(whale);
            FoboToken(fobo).transfer(us[i], share);
            _approve(us[i], neko);
        }
        for (uint256 i; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address u = us[seed % 3];
            vm.warp(vm.getBlockTimestamp() + (seed >> 8) % 3 hours);
            if ((seed >> 40) % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            uint256 bal = FoboToken(neko).balanceOf(u);
            uint256 fb = FoboToken(fobo).balanceOf(u);
            if (((seed >> 16) % 3 != 0 || bal == 0) && fb > 1e18) {
                _swap(u, k, true, -int256(1 + (seed >> 24) % (fb / 2)), 0);
            } else if (bal != 0) {
                _swap(u, k, false, -int256(bal * ((seed >> 32) % 100 + 1) / 100), 0);
            }
            if ((seed >> 48) % 4 == 0) {
                vm.roll(vm.getBlockNumber() + 1);
                hook.poke(k);
            }
        }
        (int24 tickF,,,,) = _pool(k);
        _dumpAll(k, us);
        assertLe(_tick(k), tickF + 60);
        _assertNoRaiseFailed();
    }

    function test_curveIsPlacedAsTheTrancheTable() public {
        _launchFobo();
        uint256 supply = FoboToken(fobo).totalSupply();
        uint160 sMin = TickMath.getSqrtPriceAtTick(Ticks.MIN_TICK);
        uint256 total;
        for (uint256 i; i < N_TRANCHES; i++) {
            (uint256 bps, int24 topOff) = Curve.tranche(i);
            (int24 top, uint128 l) = hook.trancheOf(foboKey, i);
            assertEq(top, FOBO_TICK - topOff, "tranche starts topOff ticks above the start price");
            uint256 amt = FloorMath.token(sMin, TickMath.getSqrtPriceAtTick(top), l, false);
            total += amt;
            if (i + 1 < N_TRANCHES) assertApproxEqAbs(amt, supply * bps / 10_000, 1e9, "tranche holds its share");
        }
        assertApproxEqAbs(total, supply - RESERVE, 1e10, "every token but the dust reserve is in the curve");
    }

    /// Ticks.MIN_START_TICK is the lowest start whose curve uses at most half of v4's per-tick liquidity cap (the other half is
    /// the floor band's headroom), and createPool enforces it.
    function test_minStartTickIsTheLiquidityBound() public {
        uint256 half = Pool.tickSpacingToMaxLiquidityPerTick(60) / 2;
        assertLe(_curveLiquidity(Ticks.MIN_START_TICK), half);
        assertGt(_curveLiquidity(Ticks.MIN_START_TICK - 60), half);
        vm.expectRevert(IFoboHook.BadTick.selector);
        factory.launch(_params("FOBO", "FOBO", bytes32(0), 0, Ticks.MIN_START_TICK - 60));
        (fobo,) = factory.launch(_params("FOBO", "FOBO", bytes32(0), 0, Ticks.MIN_START_TICK));
        foboKey = hook.keyFor(address(0), fobo);
        // it trades, raises and exits like any pool
        vm.warp(vm.getBlockTimestamp() + 61);
        address bob = _user("bob");
        vm.deal(bob, 2e9 ether); // a token at ~240 ETH: moving the price a few spacings takes ~1e9 ETH
        _swap(bob, foboKey, true, -1e9 ether, 1e9 ether);
        vm.roll(vm.getBlockNumber() + 1);
        hook.poke(foboKey);
        (int24 tickF,,,,) = _pool(foboKey);
        assertLt(tickF, Ticks.MIN_START_TICK, "raised");
        _approve(bob, fobo);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        assertLe(_tick(foboKey), tickF + 60);
    }

    function test_tranchesMergeAsTheFloorPassesThem() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        vm.deal(bob, 1e30);
        // second 0: ~3.6M ETH into the snipe pot (vested by the first poke), and the price far past the first tranche
        // starts
        _swap(bob, foboKey, true, -4_000_000 ether, 4_000_000 ether);
        (int24 start1,) = hook.trancheOf(foboKey, 1);
        (,, uint128 l0Before) = _tranche0(foboKey);
        int24 f;
        uint256 merged;
        uint256 maxGas;
        for (uint256 i; i < 200; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            uint256 g = gasleft();
            hook.poke(foboKey);
            g -= gasleft();
            if (g > maxGas) maxGas = g;
            uint256 m = _merged(foboKey);
            assertLe(m - merged, MAX_PASS, "one raise passes at most MAX_PASS tranche starts");
            merged = m;
            int24 prev = f;
            (f,,,,) = _pool(foboKey);
            if (f == prev) break;
        }
        assertLt(f, start1, "floor passed the first open tranche (10^5x the start)");
        assertGt(merged, 1, "and merged several");
        for (uint256 i = 1; i < N_TRANCHES; i++) {
            (int24 top, uint128 l) = hook.trancheOf(foboKey, i);
            if (i <= merged) {
                assertEq(l, 0, "a merged tranche is empty");
                assertEq(top, f);
            } else {
                assertLe(top, f, "a live tranche starts at or above the floor");
            }
        }
        (int24 top0,, uint128 l0) = _tranche0(foboKey);
        assertEq(top0, f, "tranche 0 is cut to the floor");
        assertGt(l0, l0Before, "merged liquidity moved into tranche 0");
        emit log_named_uint("tranches merged", merged);
        emit log_named_uint("worst poke gas (raise + unlock)", maxGas);
        assertLt(maxGas, hook.RAISE_GAS(), "raise fits its gas budget");
        _dumpAll(foboKey, _one(bob));
        _assertNoRaiseFailed();
    }

    /// The pass cap only lifts the lowest candidate tick: with the price past several tranche starts and a pot that can
    /// carry the floor past all of them, each block's raise passes at most MAX_PASS starts and the next continues.
    function test_passCapHoldsPastTrancheStarts() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        vm.deal(bob, 1e36);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 supply = FoboToken(fobo).totalSupply();
        _swap(bob, foboKey, true, int256(supply * 50 / 100), 1e36); // exact-out: half the supply, price far past $1B
        (int24 start4,) = hook.trancheOf(foboKey, 4);
        assertLt(_tick(foboKey), start4, "price passed four tranche starts");
        vm.roll(vm.getBlockNumber() + 1);
        hook.poke(foboKey);
        assertEq(_merged(foboKey), MAX_PASS, "the first raise stops at the pass cap");
        uint256 m = _merged(foboKey);
        for (uint256 i; i < 10; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            hook.poke(foboKey);
            assertLe(_merged(foboKey) - m, MAX_PASS);
            m = _merged(foboKey);
        }
        assertGt(m, MAX_PASS, "later raises continue past the cap");
        _dumpAll(foboKey, _one(bob));
        _assertNoRaiseFailed();
    }

    // ---------------------------------------------------------------- the dust reserve (review 2026-10-23, M-1)

    function _reserve(PoolKey memory key) internal view returns (uint256 r) {
        (,,, r,) = _pool(key);
    }

    /// FloorRaised, BoughtBack and RaiseFailed since the last call (getRecordedLogs drains them)
    function _raiseEvents() internal view returns (uint256 raised, uint256 boughtBack, uint256 failed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            bytes32 t0 = logs[i].topics[0];
            if (t0 == IFoboHook.FloorRaised.selector) raised++;
            else if (t0 == IFoboHook.BoughtBack.selector) boughtBack++;
            else if (t0 == IFoboHook.RaiseFailed.selector) failed++;
        }
    }

    /// One trading window: a new (L1) block, then a buy and a sell of about the same size, so the price stays put and
    /// the tax keeps feeding the pot; the window's first swap runs the raise.
    function _window(address u, uint256 ethIn) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        int256 got = _swap(u, foboKey, true, -int256(ethIn), ethIn).amount1();
        _swap(u, foboKey, false, -got, 0);
    }

    /// Was (M-1): with the dust reserve spent (~1 wei a raise, ~1M raises on a busy pool), `p.reserve -= rounding`
    /// underflowed in every raise after, the try/catch swallowed it (RaiseFailed) and the floor froze for good while the
    /// pot kept growing. Now the rebuilt tranche 0 is sized to what the removals freed plus the reserve: with the reserve
    /// at 0, raises still land, the floor still rises, and the reserve is never overdrawn.
    function test_emptyReserveDoesNotFreezeTheFloor() public {
        _launchFobo();
        address bob = _user("bob");
        _approve(bob, fobo);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        _window(bob, 0.5 ether);
        _setReserve(foboKey, 0);
        (int24 f0,,,,) = _pool(foboKey);
        vm.recordLogs();
        uint256 raised;
        for (uint256 i; i < 20; i++) {
            _window(bob, 0.5 ether);
            (uint256 r,, uint256 failed) = _raiseEvents();
            assertEq(failed, 0, "no raise fails on an empty reserve");
            raised += r;
        }
        (int24 f1,,,,) = _pool(foboKey);
        assertGt(raised, 10, "raises keep landing");
        assertLt(f1, f0, "the floor keeps rising");
        _dumpAll(foboKey, _one(bob));
    }

    /// M-1, the long run: thousands of raises on a reserve emptied before the first, through every kind of rebuild. A
    /// trader buys every window and sells back 90% of it, so the price climbs and the floor follows: ordinary raises,
    /// then merges as the price runs past tranche starts; halfway he dumps nearly everything into the band, and the
    /// raises after buy back. No raise ever fails (each one re-checks absorb >= circulating: FloorBroken), and at the end
    /// he still exits into the floor. Gas isn't metered (it would pass the test's own limit; RAISE_GAS is
    /// test_worstRaise's and the gas tests' subject).
    function test_emptyReserveLongRun() public {
        vm.pauseGasMetering();
        _launchFobo();
        address bob = _user("bob");
        _approve(bob, fobo);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        _setReserve(foboKey, 0);
        vm.recordLogs();
        uint256 raised;
        uint256 boughtBack;
        for (uint256 i; i < 3_000; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            if (i == 2_000) {
                _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob) * 99 / 100), 0);
            } else {
                // sized to the pool (the PoolManager holds only its ETH), so every window's tax can move the floor
                uint256 ethIn = address(pm).balance / 20 + 0.5 ether;
                vm.deal(bob, ethIn);
                int256 got = _swap(bob, foboKey, true, -int256(ethIn), ethIn).amount1();
                _swap(bob, foboKey, false, -got * 9 / 10, 0);
            }
            (uint256 r, uint256 b, uint256 failed) = _raiseEvents();
            assertEq(failed, 0, "no raise fails");
            raised += r;
            boughtBack += b;
        }
        emit log_named_uint("raises", raised);
        emit log_named_uint("buybacks", boughtBack);
        emit log_named_uint("tranches merged", _merged(foboKey));
        emit log_named_uint("reserve at the end (wei)", _reserve(foboKey));
        assertGt(raised, 2_000, "thousands of raises");
        assertGt(boughtBack, 0, "buybacks among them");
        assertGt(_merged(foboKey), 1, "merges among them");
        _dumpAll(foboKey, _one(bob));
    }

    /// Worst-case raise: one huge buy at second 0 (90% snipe tax -> snipe pot, vested by the first poke) takes the price past every tranche start, then
    /// pokes until the floor stops moving: raises pass as many tranche starts as they may (MAX_PASS) on a pot that carries
    /// the floor past all of them. Measure it as real transactions (cold storage): forge test --mt test_worstRaise --isolate -vv
    function test_worstRaise() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        vm.deal(bob, 1e36);
        (int24 lastStart,) = hook.trancheOf(foboKey, N_TRANCHES - 1);
        uint256 supply = FoboToken(fobo).totalSupply();
        // exact-out: 70% of supply takes the price past every start (the rest sits in the top tranche). Much more would
        // need more quote than exists: the floor band's liquidity then passes v4's per-tick cap (TickLiquidityOverflow)
        _swap(bob, foboKey, true, int256(supply * 70 / 100), 1e36);
        assertLt(_tick(foboKey), lastStart, "price passed every tranche start");
        uint256 maxGas;
        uint256 atCap; // raises that passed MAX_PASS starts
        uint256 merged;
        int24 prev = type(int24).max;
        for (uint256 i; i < 50; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            uint256 g = gasleft();
            hook.poke(foboKey);
            g -= gasleft();
            if (g > maxGas) maxGas = g;
            uint256 m = _merged(foboKey);
            assertLe(m - merged, MAX_PASS);
            if (m - merged == MAX_PASS) atCap++;
            merged = m;
            (int24 f,,,,) = _pool(foboKey);
            if (f == prev) break;
            prev = f;
        }
        assertGt(atCap, 0, "the worst case was exercised: a raise passed MAX_PASS starts");
        emit log_named_uint("tranches merged", merged);
        emit log_named_uint("raises at the pass cap", atCap);
        emit log_named_uint("worst raise gas (poke)", maxGas);
        emit log_named_uint("RAISE_GAS budget", hook.RAISE_GAS());
        assertLt(maxGas, 600_000, "worst raise keeps real headroom under RAISE_GAS");
        _dumpAll(foboKey, _one(bob));
        _assertNoRaiseFailed();
    }

    /// Worst-case buyback: every tranche merged (nothing caps the lift but MIN_TICK, so the search spans the whole tick
    /// range), then the whale sells 99% into the band and a poke later buys back for the 1% left. Measure it as a real
    /// transaction: forge test --mt test_gas_worstBuyback --isolate -vv
    function test_gas_worstBuyback() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        vm.deal(bob, 1e36);
        uint256 supply = FoboToken(fobo).totalSupply();
        _swap(bob, foboKey, true, int256(supply * 70 / 100), 1e36);
        for (uint256 i; i < 50 && _merged(foboKey) < N_TRANCHES - 1; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            hook.poke(foboKey);
        }
        assertEq(_merged(foboKey), N_TRANCHES - 1, "every tranche merged");
        _approve(bob, fobo);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob) * 99 / 100), 0);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        int24 t0 = _tick(foboKey);
        uint256 supply0 = FoboToken(fobo).totalSupply();
        uint256 g = gasleft();
        hook.poke(foboKey);
        g -= gasleft();
        assertLt(FoboToken(fobo).totalSupply(), supply0, "the measured poke bought back");
        emit log_named_int("price lifted (ticks)", int256(t0) - int256(_tick(foboKey)));
        emit log_named_uint("worst buyback gas (poke)", g);
        assertLt(g, 600_000, "keeps real headroom under RAISE_GAS");
        _dumpAll(foboKey, _one(bob));
        _assertNoRaiseFailed();
    }

    /// The raise runs in beforeSwap, so every kind of swap must reserve its gas: with too little the swap reverts NeedGas
    /// (never skips the raise), and the least gas any swap succeeds with (what eth_estimateGas finds) includes the raise.
    /// Buy and sell, exact-in and exact-out.
    function test_raiseDueNeedsGasNotSilentSkip() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        _approve(bob, fobo);
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (int24 f0,,,,) = _pool(foboKey);
        int256[4] memory amounts =
            [-int256(0.01 ether), int256(1_000_000e18), -int256(1_000_000e18), int256(0.001 ether)];
        for (uint256 k; k < 4; k++) {
            bool buy = k < 2;
            bytes memory call = abi.encodeCall(
                PoolSwapTest.swap,
                (
                    foboKey,
                    IPoolManager.SwapParams({
                        zeroForOne: buy,
                        amountSpecified: amounts[k],
                        sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                )
            );
            uint256 snap = vm.snapshotState();
            vm.prank(bob);
            (bool ok, bytes memory err) = address(router).call{gas: 400_000, value: buy ? 1 ether : 0}(call);
            assertFalse(ok, "too little gas for a due raise reverts instead of skipping it");
            assertTrue(_contains(err, IFoboHook.NeedGas.selector), "NeedGas");
            vm.revertToState(snap);
            // eth_estimateGas: the least gas the swap succeeds with
            uint256 lo = 100_000;
            uint256 hi = 3_000_000;
            while (hi - lo > 1_000) {
                uint256 mid = (lo + hi) / 2;
                vm.prank(bob);
                (ok,) = address(router).call{gas: mid, value: buy ? 1 ether : 0}(call);
                vm.revertToState(snap);
                if (ok) hi = mid;
                else lo = mid;
            }
            vm.prank(bob);
            (ok,) = address(router).call{gas: hi, value: buy ? 1 ether : 0}(call);
            assertTrue(ok);
            (int24 f1,,,,) = _pool(foboKey);
            assertLt(f1, f0, "the least gas that works raises the floor");
            _assertNoRaiseFailed();
            vm.revertToState(snap);
        }
    }

    /// Review 2026-10-23 (L-1): a swap estimated in a window whose raise already ran carries no raise in its estimate;
    /// landing as the first swap of the next block it must also fund that block's raise, so it reverts NeedGas even with 50% on top. Wallets therefore never send a bare estimate: the site
    /// adds a raise's and a credit's reserve per FOBO pool the transaction swaps in (packages/core HOOK_SWAP_GAS_RESERVE,
    /// chainClient gasWithRaises), and with it the same swap lands and raises.
    function test_estimateFromAnEarlierWindowNeedsTheRaiseReserve() public {
        _launchFobo();
        address bob = _user("bob");
        _approve(bob, fobo);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        _swap(bob, foboKey, true, -0.5 ether, 0.5 ether); // this window's raise has run
        bytes memory call = abi.encodeCall(
            PoolSwapTest.swap,
            (
                foboKey,
                IPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            )
        );
        // eth_estimateGas now, in the same window: the least gas the swap succeeds with
        uint256 snap = vm.snapshotState();
        uint256 lo = 50_000;
        uint256 hi = 3_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            vm.prank(bob, bob);
            (bool okm,) = address(router).call{gas: mid, value: 0.1 ether}(call);
            vm.revertToState(snap);
            if (okm) hi = mid;
            else lo = mid;
        }
        // the site's reserve for one pool: what beforeSwap requires for the raise plus what the credit requires (for a
        // swap estimated in a snipe window), through four calls that each keep 1/64
        uint256 reserve = hook.RAISE_GAS() * 64 / 63 + 40_000 + hook.CREDIT_GAS() * 64 / 63 + 20_000;
        for (uint256 i; i < 4; i++) {
            reserve = reserve * 64 / 63 + 1;
        }
        // ... it lands as the first swap of the next window, where a raise is due
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        (int24 f0,,,,) = _pool(foboKey);
        snap = vm.snapshotState();
        vm.prank(bob, bob);
        (bool ok, bytes memory err) = address(router).call{gas: hi * 3 / 2, value: 0.1 ether}(call);
        assertFalse(ok, "the bare estimate plus 50% is not enough");
        assertTrue(_contains(err, IFoboHook.NeedGas.selector), "NeedGas");
        vm.revertToState(snap);
        vm.recordLogs();
        vm.prank(bob, bob);
        (ok,) = address(router).call{gas: hi + reserve, value: 0.1 ether}(call);
        assertTrue(ok, "the estimate plus the raise reserve lands");
        (int24 f1,,,,) = _pool(foboKey);
        assertLt(f1, f0, "and raises");
        _assertNoRaiseFailed();
    }

    function _contains(bytes memory data, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    function test_gas_swapWithRaise() public {
        _launchFobo();
        address bob = _user("bob");
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        (int24 f0,,,,) = _pool(foboKey);
        uint256 g = gasleft();
        _swap(bob, foboKey, true, -0.01 ether, 0.01 ether); // the block's first swap: sets the ref tick, raises
        uint256 withRaise = g - gasleft();
        (int24 f1,,,,) = _pool(foboKey);
        assertLt(f1, f0, "the measured swap raised the floor");
        g = gasleft();
        _swap(bob, foboKey, true, -0.01 ether, 0.01 ether); // same block: no raise
        uint256 plain = g - gasleft();
        (int24 f2,,,,) = _pool(foboKey);
        assertEq(f2, f1, "the plain swap did not raise");
        emit log_named_uint("swap gas, plain", plain);
        emit log_named_uint("swap gas, with raise", withRaise);
        assertLt(withRaise, 610_000);
    }

    /// No-raise swap gas, as real transactions (cold storage): forge test --mt test_gas_swapNoRaise --isolate -vv. The
    /// floor is far under the price and nothing can move: the block's first swap searches and finds nothing, its later
    /// swaps don't look again (the next block's first swap does).
    function test_gas_swapNoRaise() public {
        _launchFobo();
        address bob = _user("bob");
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(bob, foboKey, true, -5 ether, 5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _swap(bob, foboKey, true, -0.01 ether, 0.01 ether); // raises
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        (int24 f0,,,,) = _pool(foboKey);
        assertGt(f0, Ticks.alignDown(_tick(foboKey)) + 240, "far under the price: the search runs");
        (uint256 first, uint256 next) = _noRaiseSwaps(bob, foboKey);
        emit log_named_uint("no-raise swap gas, the block's first (searched)", first);
        emit log_named_uint("no-raise swap gas, the block's next", next);
    }

    /// The same for a pool at its floor (a dust holder left after a whale's exit): the block's first swap takes the
    /// "can't move" exit, which still checks for floor money the holders can't carry (_drainIfOver).
    function test_gas_swapNoRaiseAtTheFloor() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address whale = _user("whale");
        address dust = _user("dust");
        address eve = _user("eve");
        _swap(whale, foboKey, true, -400 ether, 400 ether);
        _swap(dust, foboKey, true, 2_000e18, 1 ether); // exact-out: 2,000 tokens
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        _approve(whale, fobo);
        _swap(whale, foboKey, false, -int256(FoboToken(fobo).balanceOf(whale)), 0);
        for (uint256 i; i < 20; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            hook.poke(foboKey);
        }
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        (int24 f0,,,,) = _pool(foboKey);
        assertLe(f0, Ticks.alignDown(_tick(foboKey)) + 240, "at the floor: the can't-move exit");
        (uint256 first, uint256 next) = _noRaiseSwaps(eve, foboKey);
        emit log_named_uint("no-raise swap gas at the floor, the block's first", first);
        emit log_named_uint("no-raise swap gas at the floor, the block's next", next);
    }

    /// Two tiny buys in a new block where nothing moves (no FloorRaised, FloorSwept or RaiseFailed): their gas
    function _noRaiseSwaps(address who, PoolKey memory key) internal returns (uint256 first, uint256 next) {
        (int24 f0,,,,) = _pool(key);
        vm.recordLogs();
        uint256 g = gasleft();
        _swap(who, key, true, -0.0001 ether, 0.0001 ether);
        first = g - gasleft();
        g = gasleft();
        _swap(who, key, true, -0.0001 ether, 0.0001 ether);
        next = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            bytes32 t = logs[i].topics[0];
            assertTrue(
                t != IFoboHook.FloorRaised.selector && t != IFoboHook.FloorSwept.selector
                    && t != IFoboHook.RaiseFailed.selector,
                "nothing moved"
            );
        }
        (int24 f1,,,,) = _pool(key);
        assertEq(f1, f0);
    }

    /// Buyback raise gas, as a real transaction (cold storage): forge test --mt test_gas_buyback --isolate -vv. A rug
    /// into the band, then a poke two hours later: the raise lifts the price ~7x (binary search over the full
    /// span), burns the curve's tokens under the new price and rebuilds.
    function test_gas_buyback() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        _approve(bob, fobo);
        _swap(bob, foboKey, true, -3 ether, 3 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        // carol holds before the rug: the pool never empties, so the vesting snipe tax stays hers (an empty pool would
        // drain it)
        _swap(carol, foboKey, true, -0.1 ether, 0.1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        int24 t0 = _tick(foboKey);
        uint256 supply0 = FoboToken(fobo).totalSupply();
        uint256 g = gasleft();
        hook.poke(foboKey);
        g -= gasleft();
        assertLt(FoboToken(fobo).totalSupply(), supply0, "the measured poke bought back");
        emit log_named_int("price lifted (ticks)", int256(t0) - int256(_tick(foboKey)));
        emit log_named_uint("buyback raise gas (poke)", g);
        assertLt(g, 600_000, "keeps real headroom under RAISE_GAS");
        _assertNoRaiseFailed();
    }

    // ---------------------------------------------------------------- signed start (every launch after $FOBO)

    function test_signedStartDigestMatchesTheSpec() public view {
        bytes32 salt = keccak256("salt");
        assertEq(
            factory.launchStartDigest(address(0xA11CE), salt, address(0xF0B0), "Neko", "NEKO", -120, 123),
            _startDigest(address(0xA11CE), salt, address(0xF0B0), "Neko", "NEKO", -120, 123)
        );
        assertEq(
            factory.launchStartDigest(address(0xA11CE), salt, address(0), "", "", -120, 123),
            _startDigest(address(0xA11CE), salt, address(0), "", "", -120, 123)
        );
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = factory.eip712Domain();
        assertEq(name, "FoboFactory");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(factory));
    }

    function test_signedStartLaunchesAtTheSignedTick() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        address neko = _launchAs(alice, _signed(alice, "Neko", "NEKO", s, 0, 120));
        assertEq(_tick(hook.keyFor(fobo, neko)), 120, "starts at the signed tick");
        assertTrue(factory.startUsed(alice, s));
    }

    function test_signedStartWrongSigner() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        (, uint256 otherKey) = makeAddrAndKey("notTheSigner");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        _expectLaunchRevert(
            alice,
            _signedBy(otherKey, alice, fobo, "Neko", "NEKO", s, 0, 0, deadline),
            IFoboFactory.BadStartSignature.selector
        );
        // a valid signature with a different tick than it signed
        IFoboFactory.LaunchParams memory lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        lp.tickStart = 600;
        _expectLaunchRevert(alice, lp, IFoboFactory.BadStartSignature.selector);
        lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        lp.signature = hex"1234";
        _expectLaunchRevert(alice, lp, IFoboFactory.BadStartSignature.selector);
    }

    function test_signedStartExpired() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        uint256 t = vm.getBlockTimestamp();
        _expectLaunchRevert(
            alice,
            _signedBy(startSignerKey, alice, fobo, "Neko", "NEKO", s, 0, 0, t - 1),
            IFoboFactory.StartExpired.selector
        );
        _launchAs(alice, _signedBy(startSignerKey, alice, fobo, "Neko", "NEKO", s, 0, 0, t)); // good through its deadline
    }

    function test_signedStartCannotBeReplayed() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        IFoboFactory.LaunchParams memory lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        _launchAs(alice, lp);
        _expectLaunchRevert(alice, lp, IFoboFactory.StartUsed.selector);
        // the same signed salt under another name would deploy elsewhere: still one launch per signature
        lp.name = "Neko Two";
        _expectLaunchRevert(alice, lp, IFoboFactory.StartUsed.selector);
    }

    function test_signedStartIsForItsCreatorOnly() public {
        _launchFobo();
        address alice = _user("alice");
        address bob = _user("bob");
        bytes32 s = _salt(bob, "Neko", "NEKO");
        _expectLaunchRevert(bob, _signed(alice, "Neko", "NEKO", s, 0, 0), IFoboFactory.BadStartSignature.selector);
        _launchAs(bob, _signed(bob, "Neko", "NEKO", s, 0, 0));
    }

    /// The signed start binds the name and the ticker the site checked (its moderation): a launch can't swap either
    /// after signing
    function test_signedStartBindsNameAndTicker() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        IFoboFactory.LaunchParams memory lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        lp.name = "Rug";
        _expectLaunchRevert(alice, lp, IFoboFactory.BadStartSignature.selector);
        lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        lp.ticker = "RUG";
        _expectLaunchRevert(alice, lp, IFoboFactory.BadStartSignature.selector);
        assertFalse(factory.startUsed(alice, s));
        _launchAs(alice, _signed(alice, "Neko", "NEKO", s, 0, 0));
    }

    /// The signed tick plus $FOBO's start-of-block tick (tokens per ETH) must sit in the start band, edges included.
    function test_signedStartOutOfBand() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        _expectLaunchRevert(
            alice, _signed(alice, "Neko", "NEKO", s, 0, BAND_HALF + 60), IFoboFactory.StartOutOfBand.selector
        );
        _expectLaunchRevert(
            alice, _signed(alice, "Neko", "NEKO", s, 0, -BAND_HALF - 60), IFoboFactory.StartOutOfBand.selector
        );
        (int24 lo, int24 hi) = factory.startTickRange(fobo);
        assertEq(lo, -BAND_HALF);
        assertEq(hi, BAND_HALF);
        _launchAs(alice, _signed(alice, "Neko", "NEKO", s, 0, BAND_HALF));
        bytes32 s2 = _salt(alice, "Low", "LOW");
        _launchAs(alice, _signed(alice, "Low", "LOW", s2, 0, -BAND_HALF));
    }

    /// Pumping $FOBO inside the launch's own block doesn't move the band: it reads $FOBO's start-of-block tick. A pump
    /// held into the next block does move it (a signer then signs against the new price; honest starts signed before the
    /// pump fail until re-signed, which costs the pumper the round trip).
    function test_signedStartBandUsesTheStartOfBlockFoboTick() public {
        _launchFobo();
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        address eve = _user("eve");
        _approve(eve, fobo);
        _swap(eve, foboKey, true, -20 ether, 20 ether); // ~5x+ pump, first swap of the block
        int24 pumped = _tick(foboKey);
        assertLt(pumped, FOBO_TICK - BAND_HALF, "the pump moved $FOBO past the band");
        (int24 lo, int24 hi) = factory.startTickRange(fobo);
        assertEq(lo, -BAND_HALF, "same block: the band still reads the pre-pump tick");
        assertEq(hi, BAND_HALF);
        // a start priced off the pumped tick (a bad or tricked signer) is out of band
        int24 offPump = (FOBO_TICK - pumped) / 60 * 60;
        bytes32 s = _salt(alice, "Neko", "NEKO");
        _expectLaunchRevert(alice, _signed(alice, "Neko", "NEKO", s, 0, offPump), IFoboFactory.StartOutOfBand.selector);
        _launchAs(alice, _signed(alice, "Neko", "NEKO", s, 0, 0));
        // next block: the reference is the pumped price
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        (lo, hi) = factory.startTickRange(fobo);
        assertEq(lo, FOBO_TICK - BAND_HALF - _tick(foboKey), "new block: the band follows $FOBO's price");
        bytes32 s2 = _salt(alice, "Late", "LATE");
        _expectLaunchRevert(alice, _signed(alice, "Late", "LATE", s2, 0, 0), IFoboFactory.StartOutOfBand.selector);
        _launchAs(alice, _signed(alice, "Late", "LATE", s2, 0, offPump));
    }

    function test_startSignerRotation() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        IFoboFactory.LaunchParams memory old = _signed(alice, "Neko", "NEKO", s, 0, 0);
        (address next, uint256 nextKey) = makeAddrAndKey("nextSigner");

        vm.prank(alice);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        factory.setStartSigner(next);
        vm.expectRevert(IFoboFactory.ZeroAddress.selector);
        factory.setStartSigner(address(0));

        vm.expectEmit(address(factory));
        emit IFoboFactory.ConfigChanged("startSigner", uint256(uint160(next)));
        factory.setStartSigner(next);
        assertEq(factory.startSigner(), next);
        _expectLaunchRevert(alice, old, IFoboFactory.BadStartSignature.selector);
        _launchAs(alice, _signedBy(nextKey, alice, fobo, "Neko", "NEKO", s, 0, 0, vm.getBlockTimestamp() + 1 hours));
    }

    function test_startBandBounds() public {
        int24 maxBand = factory.MAX_START_BAND();
        vm.prank(makeAddr("rando"));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        factory.setStartBand(0, 60);
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setStartBand(60, 60);
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setStartBand(0, maxBand + 1);
        factory.setStartBand(-maxBand, 0);
        assertEq(factory.startBandLow(), -maxBand);
        assertEq(factory.startBandHigh(), 0);
    }

    /// Launch gas with the signed start (no initial buy), as a real transaction: forge test --mt
    /// test_gas_signedLaunch --isolate -vv.
    function test_gas_signedLaunch() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        IFoboFactory.LaunchParams memory lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        vm.prank(alice);
        uint256 g = gasleft();
        factory.launch{value: FEE}(lp);
        g -= gasleft();
        emit log_named_uint("launch gas (signed start, no initial buy)", g);
        assertLt(g, 2_100_000);
    }

    // ---------------------------------------------------------------- ETH pairs

    Currency constant ETH = Currency.wrap(address(0));

    /// An ETH-paired launch: an ETH/token pool at the signed tick (tokens per ETH), the fee goes to FoboBurner,
    /// and TokenLaunched names ETH as the quote.
    function test_ethPairLaunch() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        uint256 foboSupply = FoboToken(fobo).totalSupply();
        bytes32 s = bytes32(uint256(7)); // any salt: every token sorts after ETH
        uint256 e0 = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        (address kumo, PoolId id) = factory.launch{value: 1 ether}(_signedEth(alice, "Kumo", "KUMO", s, 0, FOBO_TICK));
        assertEq(e0 - alice.balance, FEE, "only the fee is kept");
        assertEq(FoboToken(fobo).totalSupply(), foboSupply, "nothing burned in the launch");
        assertEq(address(burner).balance, FEE, "the fee is in FoboBurner");
        PoolKey memory k = hook.keyFor(address(0), kumo);
        assertEq(PoolId.unwrap(k.toId()), PoolId.unwrap(id), "the ETH/token pool");
        assertEq(_tick(k), FOBO_TICK, "starts at the signed tick, in tokens per ETH");
        (, address creator,,,,,,,,,,,,,) = hook.pools(k.toId());
        assertEq(creator, alice);
        assertTrue(factory.startUsed(alice, s));
        assertEq(FoboToken(kumo).balanceOf(alice), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != IFoboFactory.TokenLaunched.selector) {
                continue;
            }
            (address quote, int24 tick,,,,) =
                abi.decode(logs[i].data, (address, int24, uint256, string, string, string));
            assertEq(quote, address(0), "TokenLaunched.quote = ETH");
            assertEq(tick, FOBO_TICK);
            seen = true;
        }
        assertTrue(seen, "TokenLaunched emitted");
    }

    /// The creator's initial buy on an ETH pair is paid in ETH straight into the new pool: the $FOBO pool doesn't move
    /// at all (the fee goes to FoboBurner as ETH), and the creator's 0.6% of it is owed, not paid back in the swap.
    function test_ethPairDevBuyPaysEthDirectly() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        bytes32 s = bytes32(uint256(7));
        _expectLaunchRevert(
            alice, _signedEth(alice, "Kumo", "KUMO", s, 50_000_001e18, FOBO_TICK), IFoboFactory.DevBuyTooBig.selector
        );

        (uint160 sqrt0,,,) = pm.getSlot0(foboKey.toId());
        uint256 supply0 = FoboToken(fobo).totalSupply();
        uint256 e0 = alice.balance;
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: 10 ether}(_signedEth(alice, "Kumo", "KUMO", s, 50_000_000e18, FOBO_TICK));
        uint256 paid = e0 - alice.balance - FEE;
        assertEq(FoboToken(kumo).balanceOf(alice), 50_000_000e18);
        assertLt(paid, 1 ether, "refunded");
        (uint160 sqrt,,,) = pm.getSlot0(foboKey.toId());
        assertEq(sqrt, sqrt0, "the $FOBO pool didn't move");
        assertEq(FoboToken(fobo).totalSupply(), supply0, "nothing burned in the launch");
        assertEq(address(burner).balance, FEE, "the fee is in FoboBurner");
        PoolKey memory k = hook.keyFor(address(0), kumo);
        (, uint256 pot, uint256 cr,,) = _pool(k);
        assertGt(cr, 0, "dev buy pays the normal split, not the snipe tax: the creator fee is owed");
        assertApproxEqRel(pot, cr * 5 / 2, 0.01e18); // 1.5% floor vs 0.6% creator
        assertApproxEqRel(cr * PIPS / 6000, paid, 0.001e18, "creator's 0.6% is of the ETH it paid");
        // the creator dumps it all straight away: the floor still holds, and it gets back less than it paid
        uint256 e1 = alice.balance;
        _approve(alice, kumo);
        _swap(alice, k, false, -int256(50_000_000e18), 0);
        assertLt(alice.balance - e1, paid);
    }

    /// The pair is in the signed start: a start signed for one pair can't launch the other.
    function test_signedStartIsForItsPair() public {
        _launchFobo();
        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO"); // sorts after $FOBO, so either pair could deploy it
        IFoboFactory.LaunchParams memory lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        lp.quote = address(0);
        lp.tickStart = FOBO_TICK; // in the ETH band, so only the signature can stop it
        _expectLaunchRevert(alice, lp, IFoboFactory.BadStartSignature.selector);
        lp = _signedEth(alice, "Neko", "NEKO", s, 0, FOBO_TICK);
        lp.quote = fobo;
        lp.tickStart = 0;
        _expectLaunchRevert(alice, lp, IFoboFactory.BadStartSignature.selector);
        address neko = _launchAs(alice, _signedEth(alice, "Neko", "NEKO", s, 0, FOBO_TICK));
        assertEq(_tick(hook.keyFor(address(0), neko)), FOBO_TICK, "as signed, it launches on ETH");
    }

    /// The pairs are an owner allowlist: ETH from deploy, $FOBO from its launch, nothing else until the owner allows it;
    /// $FOBO itself must pair with ETH.
    function test_quoteAllowlistDefaults() public {
        (bool ethOk,,, uint8 ethDecimals) = factory.quotes(address(0));
        assertEq(ethDecimals, 18, "ETH's decimals");
        assertTrue(ethOk, "ETH allowed from deploy");
        IFoboFactory.LaunchParams memory lp = _params("FOBO", "FOBO", bytes32(0), 0, FOBO_TICK);
        lp.quote = address(0xBEEF);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.launch(lp);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.startTickRange(address(0)); // nothing to sign before $FOBO

        vm.expectEmit(true, false, false, true, address(factory));
        emit IFoboFactory.QuoteAllowed(factory.predictToken(address(this), bytes32(0), "FOBO", "FOBO"), true);
        _launchFobo();
        (bool foboOk,,, uint8 foboDecimals) = factory.quotes(fobo);
        assertEq(foboDecimals, 18, "$FOBO's decimals");
        assertTrue(foboOk, "$FOBO allowed from its launch");

        address alice = _user("alice");
        bytes32 s = _salt(alice, "Neko", "NEKO");
        _expectLaunchRevert(
            alice,
            _signedBy(
                startSignerKey, alice, address(0xBEEF), "Neko", "NEKO", s, 0, 0, vm.getBlockTimestamp() + 1 hours
            ),
            IFoboFactory.BadQuote.selector
        );
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.startTickRange(address(0xBEEF));
    }

    /// Only the owner allows quotes; another quote needs a band first and a decimals() (any uint8, stored); bands are
    /// bounded and ETH and $FOBO use the ETH band, not one of their own.
    function test_setQuoteAllowedRules() public {
        _launchFobo();
        FoboToken usd = new FoboToken("USD", "USD");
        vm.prank(makeAddr("rando"));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        factory.setQuoteAllowed(address(usd), true);
        vm.prank(makeAddr("rando"));
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        factory.setQuoteBand(address(usd), -60, 60);

        vm.expectRevert(IFoboFactory.NoBand.selector);
        factory.setQuoteAllowed(address(usd), true);
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setQuoteBand(address(usd), 60, 60);
        vm.expectRevert(IFoboFactory.BadTick.selector);
        factory.setQuoteBand(address(usd), -BAND_HALF, BAND_HALF + 60);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.setQuoteBand(address(0), -60, 60);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.setQuoteBand(fobo, -60, 60);

        address six = address(new SixDecimals());
        factory.setQuoteBand(six, -60, 60);
        factory.setQuoteAllowed(six, true);
        (,,, uint8 sixDecimals) = factory.quotes(six);
        assertEq(sixDecimals, 6, "any decimals, stored");
        address noDecimals = address(new RevertingReceiver());
        factory.setQuoteBand(noDecimals, -60, 60);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.setQuoteAllowed(noDecimals, true);
        // a decimals() that answers with nothing, or with more than a uint8, is the same refusal (not a bare revert)
        address emptyDecimals = address(new EmptyDecimals());
        factory.setQuoteBand(emptyDecimals, -60, 60);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.setQuoteAllowed(emptyDecimals, true);
        address wideDecimals = address(new WideDecimals());
        factory.setQuoteBand(wideDecimals, -60, 60);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.setQuoteAllowed(wideDecimals, true);
        address noCode = makeAddr("no code");
        factory.setQuoteBand(noCode, -60, 60);
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.setQuoteAllowed(noCode, true);

        vm.expectEmit(true, false, false, true, address(factory));
        emit IFoboFactory.QuoteBandSet(address(usd), -BAND_HALF, BAND_HALF);
        factory.setQuoteBand(address(usd), -BAND_HALF, BAND_HALF);
        vm.expectEmit(true, false, false, true, address(factory));
        emit IFoboFactory.QuoteAllowed(address(usd), true);
        factory.setQuoteAllowed(address(usd), true);
        (bool ok, int24 lo, int24 hi, uint8 d) = factory.quotes(address(usd));
        assertTrue(ok);
        assertEq(lo, -BAND_HALF);
        assertEq(hi, BAND_HALF);
        assertEq(d, 18);
        (lo, hi) = factory.startTickRange(address(usd));
        assertEq(lo, -BAND_HALF, "its own band, in tokens per quote");
        assertEq(hi, BAND_HALF);
    }

    /// Disallowing a pair stops new launches on it and nothing else: its pools keep trading, raising and paying out.
    function test_disallowingAPairOnlyStopsNewLaunches() public {
        _launchFobo();
        address alice = _user("alice");
        address bob = _user("bob");
        address kumo = _launchAs(alice, _signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        bytes32 s = _salt(alice, "Neko", "NEKO");
        address neko = _launchAs(alice, _signed(alice, "Neko", "NEKO", s, 0, 0));
        PoolKey memory kk = hook.keyFor(address(0), kumo);
        PoolKey memory nk = hook.keyFor(fobo, neko);

        factory.setQuoteAllowed(address(0), false);
        factory.setQuoteAllowed(fobo, false);
        _expectLaunchRevert(
            alice, _signedEth(alice, "Late", "LATE", bytes32(uint256(2)), 0, FOBO_TICK), IFoboFactory.BadQuote.selector
        );
        _expectLaunchRevert(
            alice, _signed(alice, "Late", "LATE", _salt(alice, "Late", "LATE"), 0, 0), IFoboFactory.BadQuote.selector
        );
        vm.expectRevert(IFoboFactory.BadQuote.selector);
        factory.startTickRange(address(0));

        // every existing pool, $FOBO's included, still trades, raises and pays out
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(bob, foboKey, true, -2 ether, 2 ether);
        _approve(bob, kumo);
        _approve(bob, neko);
        _swap(bob, kk, true, -1 ether, 1 ether);
        _swap(bob, nk, true, -int256(FoboToken(fobo).balanceOf(bob) / 2), 0);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (int24 f0,,,,) = _pool(kk);
        hook.poke(kk);
        (int24 f1,,,,) = _pool(kk);
        assertLt(f1, f0, "the ETH pair's floor still rises");
        hook.claimCreator(kk, _creatorOf(kk));
        _dumpAll(kk, _one(bob));
        _dumpAll(nk, _one(bob));
        _dumpAll(foboKey, _one(bob));

        // and allowing it again re-opens launches
        factory.setQuoteAllowed(address(0), true);
        _launchAs(alice, _signedEth(alice, "Late", "LATE", bytes32(uint256(2)), 0, FOBO_TICK));
    }

    /// A pair on a newly allowed ERC-20: the start is checked against its own band (tokens per quote), the token must
    /// sort after it, the creator's buy is paid in the quote by the launcher, and the pool trades and holds its floor.
    function test_allowedErc20Pair() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        FoboToken usd = new FoboToken("USD", "USD"); // 1B to this test
        factory.setQuoteBand(address(usd), -BAND_HALF, BAND_HALF);
        factory.setQuoteAllowed(address(usd), true);
        address alice = _user("alice");
        address bob = _user("bob");
        usd.transfer(alice, 50_000_000e18); // ~1-2 tokens per USD in this band: a 1% buy is ~5M USD
        usd.transfer(bob, 1_000_000e18);

        bytes32 s = _saltAfter(alice, address(usd), "Neko", "NEKO");
        _expectLaunchRevert(
            alice,
            _signedBy(
                startSignerKey,
                alice,
                address(usd),
                "Neko",
                "NEKO",
                s,
                0,
                BAND_HALF + 60,
                vm.getBlockTimestamp() + 1 hours
            ),
            IFoboFactory.StartOutOfBand.selector
        );
        // the same start signed for $FOBO doesn't launch on this pair
        IFoboFactory.LaunchParams memory lp = _signed(alice, "Neko", "NEKO", s, 0, 0);
        lp.quote = address(usd);
        _expectLaunchRevert(alice, lp, IFoboFactory.BadStartSignature.selector);
        // a salt that sorts before the quote can't deploy
        for (uint256 i;; i++) {
            if (factory.predictToken(alice, bytes32(i), "Low", "LOW") < address(usd)) {
                _expectLaunchRevert(
                    alice,
                    _signedBy(
                        startSignerKey,
                        alice,
                        address(usd),
                        "Low",
                        "LOW",
                        bytes32(i),
                        0,
                        0,
                        vm.getBlockTimestamp() + 1 hours
                    ),
                    IFoboFactory.BadSalt.selector
                );
                break;
            }
        }

        // the dev buy is paid in the quote: no approval, no buy
        lp = _signedBy(
            startSignerKey,
            alice,
            address(usd),
            "Neko",
            "NEKO",
            s,
            10_000_000e18,
            BAND_HALF,
            vm.getBlockTimestamp() + 1 hours
        );
        vm.prank(alice);
        vm.expectRevert();
        factory.launch{value: FEE}(lp);
        vm.prank(alice);
        usd.approve(address(factory), type(uint256).max);
        uint256 u0 = usd.balanceOf(alice);
        uint256 e0 = alice.balance;
        uint256 foboSupply = FoboToken(fobo).totalSupply();
        vm.prank(alice);
        (address neko,) = factory.launch{value: 1 ether}(lp);
        assertEq(e0 - alice.balance, FEE, "only the ETH fee in ETH");
        assertEq(FoboToken(fobo).totalSupply(), foboSupply, "nothing burned in the launch");
        assertEq(address(burner).balance, FEE, "the fee still goes to the $FOBO burn (FoboBurner)");
        assertEq(FoboToken(neko).balanceOf(alice), 10_000_000e18);
        uint256 paid = u0 - usd.balanceOf(alice);
        PoolKey memory k = hook.keyFor(address(usd), neko);
        (, uint256 pot, uint256 cr,,) = _pool(k);
        assertApproxEqRel(cr * PIPS / 6000, paid, 0.001e18, "the creator's buy paid the 2.5% in the quote");
        assertApproxEqRel(pot, cr * 5 / 2, 0.01e18);
        assertEq(usd.balanceOf(address(factory)), 0, "nothing stuck in the factory");

        // trading in the quote, then everyone exits above the floor
        _approve(bob, address(usd));
        _approve(bob, neko);
        _swap(bob, k, true, -100_000e18, 0);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.poke(k);
        (int24 f,,,,) = _pool(k);
        assertLt(f, BAND_HALF, "the floor rose");
        address[] memory us = new address[](2);
        us[0] = alice;
        us[1] = bob;
        _dumpAll(k, us);
        assertLe(_tick(k), f + 60);
    }

    /// An ETH pair's start is checked against the band directly (tokens per ETH): its edges pass, past them reverts,
    /// and a $FOBO pump moves the $FOBO pair's range but not the ETH pair's.
    function test_ethPairBand() public {
        _launchFobo();
        address alice = _user("alice");
        (int24 lo, int24 hi) = factory.startTickRange(address(0));
        assertEq(lo, FOBO_TICK - BAND_HALF);
        assertEq(hi, FOBO_TICK + BAND_HALF);
        _expectLaunchRevert(
            alice,
            _signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, hi + 60),
            IFoboFactory.StartOutOfBand.selector
        );
        _expectLaunchRevert(
            alice,
            _signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, lo - 60),
            IFoboFactory.StartOutOfBand.selector
        );

        (int24 foboLo,) = factory.startTickRange(fobo);
        _swap(_user("bob"), foboKey, true, -50 ether, 50 ether);
        vm.roll(vm.getBlockNumber() + 1);
        (int24 foboLo2,) = factory.startTickRange(fobo);
        assertTrue(foboLo2 != foboLo, "the $FOBO pump moved the $FOBO pair's range");
        (int24 lo2, int24 hi2) = factory.startTickRange(address(0));
        assertEq(lo2, lo, "but not the ETH pair's");
        assertEq(hi2, hi);

        address a = _launchAs(alice, _signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, hi));
        address b = _launchAs(alice, _signedEth(alice, "Low", "LOW", bytes32(uint256(2)), 0, lo));
        assertEq(_tick(hook.keyFor(address(0), a)), hi);
        assertEq(_tick(hook.keyFor(address(0), b)), lo);
    }

    /// An ETH-paired token's whole life next to a busy $FOBO pool (both pools' ETH sits in the hook's one ETH claims
    /// balance, booked per pool): the snipe tax vests into the floor, raises lift it, a rug leaves spare floor money that
    /// buys back and burns, the creator and the team (through FoboRevenue) claim in ETH, and every holder of both still
    /// exits.
    function test_ethPairFloorVestsRaisesAndBuysBack() public {
        vm.recordLogs();
        _launchFobo();
        address alice = _user("alice");
        address bob = _user("bob");
        address carol = _user("carol");
        address dave = _user("dave");
        _swap(dave, foboKey, true, -3 ether, 3 ether);
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: FEE}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        PoolKey memory k = hook.keyFor(address(0), kumo);
        _approve(bob, kumo);
        _approve(carol, kumo);

        _swap(bob, k, true, -2 ether, 2 ether); // second 0: ~90% snipe tax, 60% vesting into the floor
        (uint128 sp,) = _snipe(k);
        assertGt(sp, 1 ether, "the floor share went to the snipe pot");
        assertApproxEqAbs(_burnerOwed(ETH), uint256(sp) * 2 / 3, 2, "40% owed to the $FOBO burn");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, k, true, -1 ether, 1 ether);
        _swap(dave, foboKey, true, -1 ether, 1 ether);
        uint256 rel;
        int24 last = FOBO_TICK;
        for (uint256 m = 2; m <= 4; m++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 1 minutes);
            hook.poke(k);
            (, uint128 r) = _snipe(k);
            assertGt(r, rel, "the snipe tax vests");
            rel = r;
            (int24 f,,,,) = _pool(k);
            assertLe(f, last, "tickF only decreases");
            last = f;
        }
        assertLt(last, FOBO_TICK, "the floor rose");

        // the sniper rugs (after the window: the creator earns 0.6%); two hours later the floor has spare money and buys back
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        uint256 a0 = alice.balance;
        (,, uint256 owedBefore,,) = _pool(k);
        _swap(bob, k, false, -int256(FoboToken(kumo).balanceOf(bob)), 0);
        assertEq(alice.balance, a0, "nobody is paid in a swap");
        (,, uint256 owedAfter,,) = _pool(k);
        uint256 creatorFee = owedAfter - owedBefore;
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 supply0 = FoboToken(kumo).totalSupply();
        int24 t0 = _tick(k);
        vm.getRecordedLogs(); // drop the earlier logs
        hook.poke(k);
        uint256 burned;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IFoboHook.BoughtBack.selector && logs[i].topics[1] == PoolId.unwrap(k.toId())) {
                (burned,) = abi.decode(logs[i].data, (uint256, uint160));
            }
        }
        assertGt(burned, 0, "bought back");
        assertEq(supply0 - FoboToken(kumo).totalSupply(), burned, "burned exactly what it bought");
        assertLt(_tick(k), t0, "price lifted");

        // the creator's fee is owed (never paid in the swap) and claimed in ETH
        (int24 f1,, uint256 creatorOwed,,) = _pool(k);
        assertGt(creatorFee, 0, "the rug's creator fee is owed");
        hook.claimCreator(k, alice);
        assertEq(alice.balance - a0, creatorOwed, "claimed in ETH");

        // every holder of both pools still exits
        uint256 c0 = carol.balance;
        _dumpAll(k, _one(carol));
        assertLe(_tick(k), f1 + 60, "price ended inside the band, never past it");
        assertGt(carol.balance - c0, 1 ether, "carol paid 1 ETH and gets the sniper's tax");
        _dumpAll(foboKey, _one(dave));
        // both pools' protocol fees and $FOBO's creator fee (its snipe share included) are FoboRevenue's, credited in
        // the swaps (no partners: the team)
        assertEq(hook.teamOwed(ETH), 0, "nothing left with the team in the hook");
        (,, uint256 foboOwed,,) = _pool(foboKey);
        assertEq(foboOwed, 0, "nothing waits in $FOBO's creator balance");
        uint256 owed = revenue.owed(team, address(0));
        assertGt(owed, 0);
        uint256 tb = team.balance;
        revenue.claim(team, address(0), team);
        assertEq(team.balance - tb, owed, "team claims ETH from both pools");
        _assertNoRaiseFailed();
    }

    // ---------------------------------------------------------------- the snipe tax's burn share (README §5)

    /// The snipe window's 40% by pair: an ETH pair hands it to FoboBurner as claims, a $FOBO pair burns that $FOBO at
    /// once, and neither pays the creator. TaxPaid's four shares add up to the tax.
    function test_snipeBurnShareByPair() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        address bob = _user("bob");
        _swap(bob, foboKey, true, -5 ether, 5 ether); // $FOBO to snipe the $FOBO pair with
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: FEE}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        int24 ts = (FOBO_TICK - _tick(foboKey)) / 60 * 60; // $10k in $FOBO at its price now
        IFoboFactory.LaunchParams memory lp = _signed(alice, "Neko", "NEKO", _salt(alice, "Neko", "NEKO"), 0, ts);
        vm.prank(alice);
        (address neko,) = factory.launch{value: FEE}(lp);
        PoolKey memory ke = hook.keyFor(address(0), kumo);
        PoolKey memory kf = hook.keyFor(fobo, neko);
        uint256 team0 = hook.teamOwed(ETH);

        // ETH pair at s = 0
        vm.recordLogs();
        _swap(bob, ke, true, -1 ether, 1 ether);
        (uint256 vol, uint256 toFloor, uint256 toCreator, uint256 toTeam, uint256 toBurn) = _taxPaid(ke);
        uint256 tax = (1 ether * _rate(0) + PIPS - 1) / PIPS;
        assertEq(vol, 1 ether);
        assertEq(toFloor + toCreator + toTeam + toBurn, tax, "the shares add up to the tax");
        assertEq(toBurn, tax * 40 / 100, "40% to the burn");
        assertEq(toCreator + toTeam, 0, "nothing to the creator or the team");
        assertEq(_burnerOwed(ETH), toBurn, "FoboBurner holds it as claims");
        assertEq(hook.teamOwed(ETH), team0);
        (uint128 sp,) = _snipe(ke);
        assertEq(sp, toFloor, "60% vests into the floor");

        // $FOBO pair at s = 0: the burn share is $FOBO already, burned in the swap
        uint256 supply0 = FoboToken(fobo).totalSupply();
        _swap(bob, kf, true, -1_000_000e18, 0);
        (, toFloor, toCreator, toTeam, toBurn) = _taxPaid(kf);
        assertGt(toBurn, 0);
        assertEq(toCreator + toTeam, 0, "nothing to the creator or the team");
        assertEq(supply0 - FoboToken(fobo).totalSupply(), toBurn, "the burn share of $FOBO is burned at once");
        assertEq(_burnerOwed(Currency.wrap(fobo)), 0, "nothing handed to FoboBurner");
        (,, uint256 creatorOwed,,) = _pool(kf);
        assertEq(creatorOwed, 0);
    }

    /// The TaxPaid of the last swap on `key` among the recorded logs.
    function _taxPaid(PoolKey memory key)
        internal
        view
        returns (uint256 vol, uint256 toFloor, uint256 toCreator, uint256 toTeam, uint256 toBurn)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != IFoboHook.TaxPaid.selector || logs[i].topics[1] != PoolId.unwrap(key.toId())) {
                continue;
            }
            (, vol, toFloor, toCreator, toTeam, toBurn) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256));
            seen = true;
        }
        assertTrue(seen, "TaxPaid");
    }

    /// What one pool's quote claims back: its pot, unreleased snipe pot and creator balance.
    function _owes(PoolKey memory key) internal view returns (uint256) {
        (, uint256 pot, uint256 cr,,) = _pool(key);
        (uint128 sp, uint128 rel) = _snipe(key);
        return pot + cr + sp - rel;
    }

    /// Every sniper sells inside the vest (attack E12): the empty pool's first drain sends the whole snipe pot left,
    /// vested or not, to the $FOBO burn (left vesting, it would only go to whoever buys next), and nothing lifts the
    /// empty pool.
    function test_emptyPoolVestGoesToTheBurn() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        address sn = _user("sniper");
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: FEE}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        PoolKey memory k = hook.keyFor(address(0), kumo);
        uint256 t0 = vm.getBlockTimestamp();
        _swap(sn, k, true, -10 ether, 10 ether);
        uint256 burn0 = _burnerOwed(ETH);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(t0 + 61);
        _approve(sn, kumo);
        _swap(sn, k, false, -int256(FoboToken(kumo).balanceOf(sn)), 0);
        int24 tOut = _tick(k);
        uint256 supply0 = FoboToken(kumo).totalSupply();
        vm.recordLogs();
        uint256 maxGas;
        while (vm.getBlockTimestamp() < t0 + 11 minutes) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 12);
            uint256 g = gasleft();
            hook.poke(k);
            g -= gasleft();
            if (g > maxGas) maxGas = g;
            (uint128 spNow, uint128 relNow) = _snipe(k);
            assertEq(relNow, spNow, "the first drain releases the whole snipe pot, vested or not");
        }
        emit log_named_uint("worst drain gas (poke)", maxGas);
        assertLt(maxGas, 600_000);
        (uint128 sp, uint128 rel) = _snipe(k);
        assertEq(rel, sp, "the whole snipe pot is accounted for");
        uint256 swept;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.BoughtBack.selector, "no buyback in an empty pool");
            if (logs[i].topics[0] != IFoboHook.FloorSwept.selector) continue;
            (uint256 a, bool burn) = abi.decode(logs[i].data, (uint256, bool));
            assertTrue(burn);
            swept += a;
        }
        assertGt(swept, uint256(sp) * 8 / 10, "what vested after the exit went to the burn");
        assertEq(_burnerOwed(ETH) - burn0, swept);
        assertEq(_tick(k), tOut, "the price didn't move");
        assertEq(FoboToken(kumo).totalSupply(), supply0, "nothing bought back");
        (,, uint256 circ) = hook.floorOf(k);
        assertLt(circ, EMPTY_CIRCULATING);
    }

    /// The vested amount saturates: with snipeReleased at snipePot mid-vest (what a drain leaves), _vested reads 0 instead
    /// of underflowing. _plan runs outside the raise's try/catch, so an underflow there would revert every swap of the
    /// pool, sells included. Snipe tax paid after it still vests in full by SNIPE_VEST.
    function test_vestNeverRevertsOncePotHasLeft() public {
        _launchFobo();
        address alice = _user("alice");
        vm.prank(alice);
        (address kumo,) =
            factory.launch{value: FEE}(_signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 0, FOBO_TICK));
        PoolKey memory k = hook.keyFor(address(0), kumo);
        address sn = _user("sniper");
        address carol = _user("carol");
        _swap(sn, k, true, -10 ether, 10 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, k, true, -1 ether, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        // the pool's slot 3 packs snipePot (low 128 bits) and snipeReleased (high 128 bits): release all of it, mid-vest
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(PoolId.unwrap(k.toId()), uint256(0)))) + 3);
        (uint128 sp,) = _snipe(k);
        vm.store(address(hook), slot, bytes32((uint256(sp) << 128) | sp));
        (uint128 sp2, uint128 rel) = _snipe(k);
        assertEq(sp2, sp, "slot layout");
        assertEq(rel, sp, "slot layout");
        _approve(carol, kumo);
        uint256 bal = FoboToken(kumo).balanceOf(carol);
        _swap(carol, k, false, -int256(bal / 2), 0); // sells still go
        hook.poke(k);
        (, rel) = _snipe(k);
        assertEq(rel, sp, "nothing more released");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 11 minutes);
        _swap(carol, k, false, -int256(FoboToken(kumo).balanceOf(carol)), 0);
    }

    /// The floor invariant fuzz on an ETH-paired child pool, with $FOBO pool trading interleaved (both draw on the hook's
    /// one ETH claims balance): every holder of both sells everything and both prices stay inside their bands.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_ethPairedPoolFloorHolds(uint256 seed) public {
        vm.recordLogs();
        _launchFobo();
        address alice = _user("alice");
        vm.prank(alice);
        (address kumo,) = factory.launch{value: 1 ether}(
            _signedEth(alice, "Kumo", "KUMO", bytes32(uint256(1)), 10_000_000e18, FOBO_TICK)
        );
        PoolKey memory k = hook.keyFor(address(0), kumo);
        address[] memory us = new address[](4);
        us[0] = alice; // holds the 1% initial buy
        for (uint256 i; i < 4; i++) {
            if (i != 0) us[i] = _user(string(abi.encodePacked("e", vm.toString(i))));
            _approve(us[i], kumo);
        }
        for (uint256 i; i < 30; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address u = us[seed % 4];
            PoolKey memory key = (seed >> 56) % 4 == 0 ? foboKey : k;
            address token = Currency.unwrap(key.currency1);
            vm.warp(vm.getBlockTimestamp() + (seed >> 8) % 3 hours);
            if ((seed >> 40) % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            uint256 bal = FoboToken(token).balanceOf(u);
            if ((seed >> 16) % 3 != 0 || bal == 0) {
                uint256 amt = 0.01 ether + (seed >> 24) % 20 ether;
                _swap(u, key, true, -int256(amt), amt);
            } else {
                _swap(u, key, false, -int256(bal * ((seed >> 32) % 100 + 1) / 100), 0);
            }
            if ((seed >> 48) % 4 == 0) {
                vm.roll(vm.getBlockNumber() + 1);
                hook.poke(key);
            }
        }
        (int24 tickF,,,,) = _pool(k);
        _dumpAll(k, us);
        assertLe(_tick(k), tickF + 60, "child price ended inside its band");
        (tickF,,,,) = _pool(foboKey);
        _dumpAll(foboKey, us);
        assertLe(_tick(foboKey), tickF + 60, "$FOBO price ended inside its band");
        _assertNoRaiseFailed();
    }

    /// Launch gas per pair, with and without a 5% initial buy, as real transactions: forge test --mt
    /// test_gas_launchByPair --isolate -vv.
    function test_gas_launchByPair() public {
        _launchFobo();
        vm.warp(vm.getBlockTimestamp() + 61);
        address alice = _user("alice");
        _fundFobo(alice, 5 ether);
        bytes32 s = _salt(alice, "Neko", "NEKO");
        uint256[4] memory g;
        IFoboFactory.LaunchParams[4] memory lps = [
            _signedEth(alice, "Neko", "NEKO", s, 0, FOBO_TICK),
            _signedEth(alice, "Neko", "NEKO", s, 50_000_000e18, FOBO_TICK),
            _signed(alice, "Neko", "NEKO", s, 0, 0),
            _signed(alice, "Neko", "NEKO", s, 50_000_000e18, 0)
        ];
        for (uint256 i; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            uint256 g0 = gasleft();
            factory.launch{value: 1 ether}(lps[i]);
            g[i] = g0 - gasleft();
            vm.revertToState(snap);
        }
        emit log_named_uint("launch gas, ETH pair, no initial buy", g[0]);
        emit log_named_uint("launch gas, ETH pair, 5% initial buy", g[1]);
        emit log_named_uint("launch gas, $FOBO pair, no initial buy", g[2]);
        emit log_named_uint("launch gas, $FOBO pair, 5% initial buy", g[3]);
        assertLt(g[0], 2_100_000);
        assertLt(g[3], 2_450_000); // OpenZeppelin's ERC20 costs ~16k more to deploy than the old hand-rolled token
    }

    // ---------------------------------------------------------------- many swaps in one block

    /// Many swaps at many timestamps in one block (as the hook counts blocks: block.number here, the chain's own L2
    /// block on Robinhood Chain, test/Blocks.t.sol): one raise per pool per block, the block's reference tick fixed at
    /// its start, vesting released only by a raise (so once per block), and a pump-then-dump inside the block loses.
    /// The next block raises again.
    function test_manySwapsInOneBlock() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        address eve = _user("eve");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _approve(eve, fobo);
        _swap(bob, foboKey, true, -5 ether, 5 ether); // snipe at 0 s: the pot vests over 10 minutes
        (uint128 sp,) = _snipe(foboKey);

        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 minutes);
        int24 blockStart = _tick(foboKey);
        Vm.Log[] memory drop = vm.getRecordedLogs();
        drop;
        uint256 e0 = eve.balance;
        _swap(eve, foboKey, true, -10 ether, 10 ether); // pump on the block's first swap
        (,,,,, int24 ref, uint64 refBlock, uint64 lastRaise,,,,,,,) = hook.pools(foboKey.toId());
        assertEq(ref, blockStart, "reference = the tick at the block's start, not the pumped one");
        assertEq(lastRaise, vm.getBlockNumber(), "the block's first swap raised");
        (int24 f0,,,,) = _pool(foboKey);
        (, uint128 rel0) = _snipe(foboKey);
        assertEq(rel0, uint256(sp) * 2 / 10, "2 minutes vested");

        vm.warp(vm.getBlockTimestamp() + 6); // later in the same block: no new raise for the pumper to sell into
        _swap(eve, foboKey, false, -int256(FoboToken(fobo).balanceOf(eve)), 0);
        assertLt(eve.balance, e0, "pump and dump inside one block loses");
        // 48 more swaps over the next 12 s of timestamps (four per second), buys and sells, same block
        for (uint256 i; i < 48; i++) {
            if (i % 4 == 0) vm.warp(vm.getBlockTimestamp() + 1);
            address who = i % 3 == 0 ? bob : carol;
            if (i % 2 == 0) _swap(who, foboKey, true, -0.05 ether, 0.05 ether);
            else if (FoboToken(fobo).balanceOf(who) > 1e18) _swap(who, foboKey, false, -1e18, 0);
            else _swap(who, foboKey, true, -0.01 ether, 0.01 ether);
        }
        (int24 f1,,,,) = _pool(foboKey);
        (, uint128 rel1) = _snipe(foboKey);
        (,,,,, int24 ref1, uint64 refBlock1,,,,,,,,) = hook.pools(foboKey.toId());
        assertEq(f1, f0, "one raise per block");
        assertEq(rel1, rel0, "time inside the block releases nothing");
        assertEq(ref1, ref, "the reference holds for the whole block");
        assertEq(refBlock1, refBlock);
        uint256 raises;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IFoboHook.FloorRaised.selector) raises++;
            assertTrue(logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "a raise failed silently");
        }
        assertEq(raises, 1, "exactly one FloorRaised in the block");

        // the next block: a new reference, the next raise and what vested meanwhile
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        int24 nextStart = _tick(foboKey);
        _swap(carol, foboKey, true, -0.05 ether, 0.05 ether);
        (,,,,, int24 ref2,, uint64 lastRaise2,,,,,,,) = hook.pools(foboKey.toId());
        (int24 f2,,,,) = _pool(foboKey);
        (, uint128 rel2) = _snipe(foboKey);
        assertEq(ref2, nextStart);
        assertEq(lastRaise2, vm.getBlockNumber());
        assertLe(f2, f1, "the floor only rises");
        uint256 elapsed = vm.getBlockTimestamp() - 1_700_000_000;
        assertEq(rel2, uint256(sp) * elapsed / 600, "the next block releases everything vested by now");
        _dumpAll(foboKey, _one(bob));
        _dumpAll(foboKey, _one(carol));
    }

    /// A buyback is a raise: at most one per pool per block, however many swaps and pokes land in it at later
    /// timestamps.
    function test_oneBuybackPerBlock() public {
        vm.recordLogs();
        _launchFobo();
        address bob = _user("bob");
        address carol = _user("carol");
        _approve(bob, fobo);
        _approve(carol, fobo);
        _swap(bob, foboKey, true, -2 ether, 2 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        _swap(carol, foboKey, true, -1 ether, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _swap(bob, foboKey, false, -int256(FoboToken(fobo).balanceOf(bob)), 0); // rug while the snipe tax vests
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        Vm.Log[] memory drop = vm.getRecordedLogs();
        drop;
        uint256 supply0 = FoboToken(fobo).totalSupply();
        hook.poke(foboKey); // buys back
        uint256 supply1 = FoboToken(fobo).totalSupply();
        assertLt(supply1, supply0, "bought back and burned");
        int24 t1 = _tick(foboKey);
        for (uint256 i; i < 24; i++) {
            vm.warp(vm.getBlockTimestamp() + 1); // later timestamps, same block
            if (i % 2 == 0) hook.poke(foboKey);
            else _swap(carol, foboKey, true, -0.01 ether, 0.01 ether);
        }
        assertEq(FoboToken(fobo).totalSupply(), supply1, "no second buyback in the block");
        assertLe(_tick(foboKey), t1, "only buys moved the price");
        uint256 buybacks;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IFoboHook.BoughtBack.selector) buybacks++;
            assertTrue(logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "a raise failed silently");
        }
        assertEq(buybacks, 1);
        _dumpAll(foboKey, _one(carol));
    }

    function _assertNoRaiseFailed() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IFoboHook.RaiseFailed.selector, "a raise failed silently");
        }
    }

    /// What `who` would get selling all their $FOBO now (state reverted afterwards).
    function _exitValue(address who) internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        uint256 b0 = who.balance;
        _swap(who, foboKey, false, -int256(FoboToken(fobo).balanceOf(who)), 0);
        got = who.balance - b0;
        vm.revertToState(snap);
    }
}
