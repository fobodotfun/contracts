// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FoboBurner} from "../src/FoboBurner.sol";
import {FoboFactory} from "../src/FoboFactory.sol";
import {FoboHook} from "../src/FoboHook.sol";
import {FoboLimitOrders} from "../src/FoboLimitOrders.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IFoboFactory} from "../src/interfaces/IFoboFactory.sol";
import {IFoboLimitOrders} from "../src/interfaces/IFoboLimitOrders.sol";
import {IFoboRevenue} from "../src/interfaces/IFoboRevenue.sol";
import {FoboRevenue} from "../src/FoboRevenue.sol";
import {FoboVesting} from "../src/FoboVesting.sol";
import {MockEthUsdFeed} from "./MockEthUsdFeed.sol";
import {StartTick} from "./StartTick.sol";

/// Deploys FoboVesting (ownerless dev-buy vesting; the factory names it immutably, so it comes first), the factory, FoboRevenue (protocol revenue sharing and referrals), FoboLimitOrders (keeper-filled limit orders,
/// native ETH whitelisted as their first pay token on the ETH/USD feed),
/// FoboBurner (every buy-$FOBO-and-burn amount: launch fees, snipe burn shares, swept floor money) and the hook (hook
/// address mined so its low bits carry the permission flags; it names FoboLimitOrders and FoboBurner immutably, and
/// FoboLimitOrders finds the hook through the factory, so both are deployed first). The factory reads the burner from the
/// hook when the hook is set; FoboBurner takes the hook once (setHook checks it names this burner). ETH needs no
/// FoboBurner route (ETH -> the $FOBO pool is built in); other quotes get theirs from the Owner Safe when they are
/// allowed (setRoute, docs/DEPLOYMENT.md section 9.1).
///   POOL_MANAGER   v4 PoolManager on the target chain (unset on a local chain: a fresh one is deployed)
///   TEAM           team wallet, an EOA or a Safe (the hook's team balances, and FoboRevenue's team recipient: the rest of
///                  the protocol fee)
///   OWNER          final owner (the Owner Safe) of the factory, FoboRevenue, FoboLimitOrders and FoboBurner; ownership of each is offered
///                  to it after deploy, it must call acceptOwnership() on each. Required on every chain but a local one
///                  (31337): set, not the deployer, and a contract (the Safe)
///   ETH_USD        live ETH price in whole dollars, e.g. 2600 (at least 1000: not in thousands or cents): sets the $10
///                  launch fee in ETH, and the start band (~2x either side of a $10k start in ETH) that signed launch
///                  starts must fall in. With a real ETH_USD_FEED it must be within 5% of the feed's answer
///   START_SIGNER   address of the key that signs every launch's start tick after $FOBO's (ETH and $FOBO pairs alike:
///                  FOBO_START_SIGNER_KEY on the site's server; docs/DEPLOYMENT.md)
///   KEEPER         the first keeper of FoboBurner and FoboLimitOrders, the site's keeper address (FOBO_KEEPER_KEY),
///                  which runs buybackAndBurn and fills limit orders; required on every chain but the local one (unset
///                  there = none; the Owner Safe can set keepers on each: setKeeper)
///   REGISTRAR      optional: FoboRevenue's registrar, the site's referral relayer address (FOBO_REFERRAL_RELAYER_KEY),
///                  which binds signed-up traders to their referrers (registerBy); unset = none (the Owner Safe can set it)
///   ETH_USD_FEED   FoboLimitOrders' ETH/USD feed, native ETH's pay-token price (setPayToken; Chainlink AggregatorV3
///                  interface, at most 18 decimals). Other pay tokens (USDG) are the Owner Safe's later (docs/DEPLOYMENT.md
///                  section 9.4). Defaults to
///                  Chainlink's on Robinhood Chain mainnet; unset on a local chain: a MockEthUsdFeed at ETH_USD is
///                  deployed (the deployer sets its price)
///   ETH_USD_FEED_MAX_AGE  oldest feed answer (seconds) a fill accepts: the feed's heartbeat plus a margin. Required
///                  with ETH_USD_FEED; the local mock defaults to 365 days (the local clock jumps hours at a time)
///   SEQUENCER_UPTIME_FEED  optional: the chain's Chainlink L2 sequencer uptime feed; fills wait while the sequencer is
///                  down and for SEQUENCER_GRACE_PERIOD after it comes back. Unset = none (a chain without one)
///   SEQUENCER_GRACE_PERIOD  seconds (default 3600, Chainlink's suggestion); only read with SEQUENCER_UPTIME_FEED
///   DEPLOYMENT     optional name of the deployment file (default: the chain's Substreams network name)
/// On Robinhood Chain (4663, 46630) the hook counts its own L2 blocks with ArbSys (FoboHook.isArbitrum,
/// isArbitrumChain), elsewhere block.number; fixed by the chain id, no env to get wrong.
/// The deployer stays owner until OWNER accepts, so it can run LaunchFobo.s.sol first. FoboRevenue starts with the
/// default referral fee (25%), no partners and no partner fee: the Owner Safe sets them (setPartners, then
/// setFeePercent; docs/DEPLOYMENT.md).
/// A broadcast run writes deployments/<name>.json: the addresses (FoboVesting's, FoboRevenue's, FoboLimitOrders' and its ETH feed's,
/// FoboBurner's and its first keeper too) plus the deployer, team, owner and start signer, which the site
/// tags as $FOBO's protocol wallets and the indexer config (packages/substreams/scripts/configure.mjs) reads.
contract Deploy is Script {
    uint256 internal constant LOCAL_CHAIN_ID = 31337; // anvil
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;
    /// Chainlink's ETH / USD proxy on Robinhood Chain mainnet (8 decimals, 24 h heartbeat, 0.5% deviation), from
    /// Chainlink's feed directory (docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood)
    address internal constant ROBINHOOD_ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    /// The heartbeat plus an hour: a fill never prices off an answer older than that
    uint256 internal constant ROBINHOOD_ETH_USD_MAX_AGE = 25 hours;
    /// FoboLimitOrders' limit (it scales the answer to 1e18)
    uint8 internal constant FEED_MAX_DECIMALS = 18;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function run()
        external
        returns (
            FoboFactory factory,
            FoboHook hook,
            FoboRevenue revenue,
            FoboLimitOrders limitOrders,
            FoboBurner burner
        )
    {
        uint256 ethUsd = vm.envUint("ETH_USD");
        require(ethUsd >= 1000, "ETH_USD: the ETH price in whole dollars, e.g. 2600 (at least 1000)");
        address team = vm.envAddress("TEAM");
        address owner = vm.envOr("OWNER", address(0));
        address startSigner = vm.envAddress("START_SIGNER");
        address registrar = vm.envOr("REGISTRAR", address(0));
        address keeper = vm.envOr("KEEPER", address(0));
        // a real chain's (Robinhood Chain 4663, its testnet 46630) FoboBurner and FoboLimitOrders need their keeper from
        // the start: without one no order fills and no buyback runs until the Owner Safe adds it
        require(block.chainid == LOCAL_CHAIN_ID || keeper != address(0), "set KEEPER: the keeper's address (FOBO_KEEPER_KEY's)");
        uint256 launchFee = 10 ether / ethUsd; // $10

        vm.startBroadcast();
        address deployer = msg.sender;
        // a real chain's factory, FoboRevenue, FoboLimitOrders and FoboBurner must end with the Owner Safe: never left with
        // the deployer's hot key
        if (block.chainid != LOCAL_CHAIN_ID) {
            require(owner != address(0) && owner != deployer, "set OWNER: the Owner Safe, not the deployer");
            require(owner.code.length != 0, "OWNER has no code: it must be the Owner Safe");
        }
        IPoolManager pm = IPoolManager(vm.envOr("POOL_MANAGER", address(0)));
        if (address(pm) == address(0)) {
            require(block.chainid == LOCAL_CHAIN_ID, "set POOL_MANAGER");
            pm = IPoolManager(address(new PoolManager(msg.sender)));
        }
        FoboVesting vesting = new FoboVesting();
        factory = new FoboFactory(pm, msg.sender, team, launchFee, vesting);
        require(address(factory.vesting()) == address(vesting), "factory's vesting");
        revenue = new FoboRevenue(pm, msg.sender, team);
        limitOrders = deployLimitOrders(pm, factory, deployer, ethUsd);
        burner = new FoboBurner(pm, msg.sender);

        bool isArbitrum = isArbitrumChain();
        bytes memory init = abi.encodePacked(
            type(FoboHook).creationCode,
            abi.encode(pm, address(factory), address(revenue), address(limitOrders), address(burner), isArbitrum)
        );
        bytes32 salt = mineHookSalt(keccak256(init));
        hook = new FoboHook{salt: salt}(
            pm, address(factory), IFoboRevenue(address(revenue)), address(limitOrders), address(burner), isArbitrum
        );
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == FLAGS, "hook flags");
        factory.setHook(hook);
        revenue.setHook(address(hook));
        burner.setHook(hook);
        require(factory.burner() == address(burner), "factory's burner");
        if (keeper != address(0)) {
            burner.setKeeper(keeper, true);
            limitOrders.setKeeper(keeper, true);
        }
        if (registrar != address(0)) revenue.setRegistrar(registrar);
        factory.setStartSigner(startSigner);
        int24 mid = StartTick.forEthUsd(ethUsd);
        int24 half = factory.MAX_START_BAND() / 2;
        factory.setStartBand(mid - half, mid + half);
        if (owner != address(0) && owner != msg.sender) offerOwnership(owner, factory, revenue, limitOrders, burner);
        vm.stopBroadcast();

        console2.log("PoolManager", address(pm));
        console2.log("FoboFactory", address(factory));
        console2.log("FoboHook   ", address(hook));
        console2.log("FoboRevenue", address(revenue));
        console2.log("FoboLimitOrders", address(limitOrders));
        console2.log("FoboBurner ", address(burner));
        console2.log("FoboVesting", address(factory.vesting()));
        console2.log("keeper (FoboBurner, FoboLimitOrders)", keeper);
        console2.log("hook counts blocks with ArbSys (isArbitrum)", hook.isArbitrum());
        // reverts unless the feed answers, positive and fresh: a broken feed fails the deploy, not the first fill
        console2.log("ETH/USD feed (1e18)", limitOrders.ethUsd());
        console2.log("launch fee (wei)", launchFee);
        console2.log("start signer", startSigner);
        if (factory.pendingOwner() != address(0)) {
            // two-step: the deployer stays owner until the Owner Safe accepts (docs/DEPLOYMENT.md section 4)
            console2.log(
                "pending owner: call acceptOwnership() on the factory, FoboRevenue, FoboLimitOrders and FoboBurner from",
                owner
            );
        }

        // only a broadcast is a deployment: a dry run must not leave addresses that were never deployed
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            // networkName() only when DEPLOYMENT is unset: as envOr's default it would run (and revert on an unknown
            // chain) even when DEPLOYMENT is set
            string memory name = vm.envOr("DEPLOYMENT", string(""));
            if (bytes(name).length == 0) name = networkName();
            string memory path = string.concat("deployments/", name, ".json");
            writeDeployment(
                path,
                pm,
                factory,
                hook,
                revenue,
                limitOrders,
                burner,
                keeper,
                deployer,
                team,
                owner == address(0) ? deployer : owner,
                launchFee,
                startSigner
            );
            console2.log("wrote", path);
        }
    }

    /// Offers the ownership of every owned contract to `owner` (the Owner Safe), which accepts each (two-step)
    function offerOwnership(
        address owner,
        FoboFactory factory,
        FoboRevenue revenue,
        FoboLimitOrders limitOrders,
        FoboBurner burner
    ) internal {
        factory.transferOwnership(owner);
        revenue.transferOwnership(owner);
        limitOrders.transferOwnership(owner);
        burner.transferOwnership(owner);
        require(
            factory.pendingOwner() == owner && revenue.pendingOwner() == owner && limitOrders.pendingOwner() == owner
                && burner.pendingOwner() == owner,
            "ownership not offered"
        );
    }

    /// The deployment file: what the site and the indexer read. `owner` is the final owner (pending until it accepts).
    function writeDeployment(
        string memory path,
        IPoolManager pm,
        FoboFactory factory,
        FoboHook hook,
        FoboRevenue revenue,
        FoboLimitOrders limitOrders,
        FoboBurner burner,
        address keeper,
        address deployer,
        address team,
        address owner,
        uint256 launchFee,
        address startSigner
    ) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "poolManager", address(pm));
        vm.serializeAddress(k, "factory", address(factory));
        vm.serializeAddress(k, "hook", address(hook));
        vm.serializeAddress(k, "revenue", address(revenue));
        vm.serializeAddress(k, "registrar", revenue.registrar());
        vm.serializeAddress(k, "limitOrders", address(limitOrders));
        (IFoboLimitOrders.Pricing memory eth,) = limitOrders.payTokens(address(0));
        vm.serializeAddress(k, "ethUsdFeed", address(eth.feed));
        vm.serializeUint(k, "ethUsdFeedMaxAge", eth.maxPriceAge);
        vm.serializeAddress(k, "sequencerUptimeFeed", address(limitOrders.sequencerUptimeFeed()));
        vm.serializeUint(k, "sequencerGracePeriod", limitOrders.sequencerGracePeriod());
        vm.serializeAddress(k, "burner", address(burner));
        vm.serializeAddress(k, "vesting", address(factory.vesting()));
        vm.serializeAddress(k, "keeper", keeper);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "team", team);
        vm.serializeAddress(k, "owner", owner);
        vm.serializeAddress(k, "startSigner", startSigner);
        vm.writeJson(vm.serializeString(k, "launchFeeWei", vm.toString(launchFee)), path);
    }

    /// FoboLimitOrders owned by the deployer (until OWNER accepts), with native ETH whitelisted as a pay token on
    /// ETH_USD_FEED (with ETH_USD_FEED_MAX_AGE), or on a local chain without one, on a MockEthUsdFeed at `ethUsd` (8
    /// decimals, like Chainlink's USD feeds) owned by the deployer; with SEQUENCER_UPTIME_FEED if set.
    function deployLimitOrders(IPoolManager pm, FoboFactory factory, address deployer, uint256 ethUsd)
        internal
        returns (FoboLimitOrders lo)
    {
        address sequencerFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));
        uint256 grace = sequencerFeed == address(0) ? 0 : vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(1 hours));
        lo = new FoboLimitOrders(pm, IFoboFactory(address(factory)), deployer, IAggregatorV3(sequencerFeed), grace);
        (address feed, uint256 maxAge) = ethUsdFeed(ethUsd);
        lo.setPayToken(address(0), IAggregatorV3(feed), maxAge, false, true);
    }

    /// Native ETH's USD feed and its max age: ETH_USD_FEED (checked), Chainlink's on Robinhood Chain mainnet by default,
    /// or on a local chain without one a MockEthUsdFeed at `ethUsd`
    function ethUsdFeed(uint256 ethUsd) internal returns (address feed, uint256 maxAge) {
        // Robinhood Chain mainnet: Chainlink's ETH/USD unless ETH_USD_FEED overrides it (there's no sequencer uptime feed
        // there: Chainlink doesn't publish one for Robinhood Chain)
        bool isRobinhood = block.chainid == ROBINHOOD_CHAIN_ID;
        feed = vm.envOr("ETH_USD_FEED", isRobinhood ? ROBINHOOD_ETH_USD_FEED : address(0));
        if (feed == address(0)) {
            require(block.chainid == LOCAL_CHAIN_ID, "set ETH_USD_FEED");
            return (localEthUsdFeed(ethUsd), vm.envOr("ETH_USD_FEED_MAX_AGE", uint256(365 days)));
        }
        maxAge = isRobinhood
            ? vm.envOr("ETH_USD_FEED_MAX_AGE", ROBINHOOD_ETH_USD_MAX_AGE)
            : vm.envUint("ETH_USD_FEED_MAX_AGE");
        checkEthUsdFeed(IAggregatorV3(feed), maxAge, ethUsd, feed == ROBINHOOD_ETH_USD_FEED);
    }

    /// A local chain's MockEthUsdFeed at `ethUsd` (whole dollars), 8 decimals, owned by the deployer
    function localEthUsdFeed(uint256 ethUsd) internal returns (address) {
        // ethUsd is a whole-dollar ETH price (an env value), far below 2^255 / 1e8
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(new MockEthUsdFeed(8, int256(ethUsd * 1e8)));
    }

    /// A real feed must have at most 18 decimals (FoboLimitOrders' limit) and a positive answer no older than `maxAge`,
    /// within StartTick.ETH_USD_MAX_DEVIATION_PCT of `ethUsd` (whole dollars): a wrong address, a dead feed or a mistyped ETH_USD
    /// fails the deploy instead of freezing every limit-order fill or mispricing the launch fee and start band after it.
    /// Chainlink's Robinhood feed (`isDefault`) must also read "ETH / USD"; an override's description() is only logged
    /// (the interface doesn't require one).
    function checkEthUsdFeed(IAggregatorV3 feed, uint256 maxAge, uint256 ethUsd, bool isDefault) internal view {
        require(maxAge != 0, "ETH_USD_FEED_MAX_AGE must be positive");
        console2.log("ETH/USD feed", address(feed));
        if (isDefault) {
            require(keccak256(bytes(feed.description())) == keccak256("ETH / USD"), "ETH_USD_FEED is not ETH / USD");
        } else {
            try feed.description() returns (string memory d) {
                console2.log("  description", d);
            } catch {
                console2.log("  no description()");
            }
        }
        uint8 decimals = feed.decimals();
        require(decimals <= FEED_MAX_DECIMALS, "ETH_USD_FEED decimals");
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(
            answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge,
            "ETH_USD_FEED stale or empty"
        );
        // ETH_USD in the feed's units, within the deviation of its answer either way
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 live = uint256(answer); // > 0, checked above
        uint256 given = ethUsd * 10 ** uint256(decimals);
        require(
            StartTick.nearFeed(given, live),
            string.concat(
                "ETH_USD is more than ", vm.toString(StartTick.ETH_USD_MAX_DEVIATION_PCT), "% off ETH_USD_FEED's answer"
            )
        );
        console2.log("  answer", live);
        console2.log("  decimals", decimals);
        console2.log("  max age (s)", maxAge);
    }

    /// Robinhood Chain (mainnet 4663, testnet 46630) is an Arbitrum Orbit chain: its block.number is the parent chain's,
    /// so the hook counts blocks with ArbSys.arbBlockNumber() there (FoboHook.isArbitrum). Every other chain (anvil
    /// 31337 included) uses block.number. Add an Arbitrum chain here before deploying to it.
    function isArbitrumChain() internal view returns (bool) {
        return block.chainid == ROBINHOOD_CHAIN_ID || block.chainid == ROBINHOOD_TESTNET_CHAIN_ID;
    }

    /// Deployment files are named like the chain's Substreams network, so the indexer config finds them by that name.
    function networkName() internal view returns (string memory) {
        if (block.chainid == LOCAL_CHAIN_ID) return "local";
        if (block.chainid == ROBINHOOD_CHAIN_ID) return "robinhood";
        if (block.chainid == ROBINHOOD_TESTNET_CHAIN_ID) return "robinhood-sepolia";
        revert("unknown chain: set DEPLOYMENT");
    }

    function mineHookSalt(bytes32 initHash) internal pure returns (bytes32 salt) {
        for (uint256 i;; i++) {
            salt = bytes32(i);
            address a =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == FLAGS) return salt;
        }
    }
}
