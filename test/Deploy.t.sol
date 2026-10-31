// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockEthUsdFeed} from "../script/MockEthUsdFeed.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// Deploy.s.sol's checks, called directly
contract DeployHarness is Deploy {
    function check(IAggregatorV3 feed, uint256 maxAge, uint256 ethUsd, bool isDefault) external view {
        checkEthUsdFeed(feed, maxAge, ethUsd, isDefault);
    }

    function arbitrum() external view returns (bool) {
        return isArbitrumChain();
    }

    function network() external view returns (string memory) {
        return networkName();
    }
}

/// A feed with no description() (AggregatorV3's other reads only)
contract NoDescriptionFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2600e8, block.timestamp, block.timestamp, 1);
    }
}

/// Some other feed: a description that isn't ETH / USD
contract BtcUsdFeed is NoDescriptionFeed {
    function description() external pure returns (string memory) {
        return "BTC / USD";
    }
}

contract DeployScriptTest is Test {
    DeployHarness d;

    function setUp() public {
        d = new DeployHarness();
        vm.warp(1_700_000_000);
    }

    /// ETH_USD must be within 5% of the feed's answer either way, in the feed's own decimals (up to 18)
    function test_ethUsdWithinFivePercentOfTheFeed() public {
        uint8[3] memory decs = [uint8(8), 6, 18];
        for (uint256 i; i < decs.length; i++) {
            uint256 one = 10 ** uint256(decs[i]);
            MockEthUsdFeed feed = new MockEthUsdFeed(decs[i], int256(2600 * one));
            d.check(feed, 1 hours, 2600, false);
            d.check(feed, 1 hours, 2470, false); // -5%
            d.check(feed, 1 hours, 2730, false); // +5%
            vm.expectRevert(bytes("ETH_USD is more than 5% off ETH_USD_FEED's answer"));
            d.check(feed, 1 hours, 2469, false);
            vm.expectRevert(bytes("ETH_USD is more than 5% off ETH_USD_FEED's answer"));
            d.check(feed, 1 hours, 2731, false);
            vm.expectRevert(bytes("ETH_USD is more than 5% off ETH_USD_FEED's answer"));
            d.check(feed, 1 hours, 26, false); // in hundreds by mistake
        }
    }

    /// At most 18 decimals (FoboLimitOrders' limit); a positive, fresh answer
    function test_feedDecimalsAndAnswer() public {
        d.check(new MockEthUsdFeed(18, 2600e18), 1 hours, 2600, false);
        MockEthUsdFeed nineteen = new MockEthUsdFeed(19, 2600e19);
        vm.expectRevert(bytes("ETH_USD_FEED decimals"));
        d.check(nineteen, 1 hours, 2600, false);
        MockEthUsdFeed feed = new MockEthUsdFeed(8, 2600e8);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.expectRevert(bytes("ETH_USD_FEED stale or empty"));
        d.check(feed, 1 hours, 2600, false);
        feed.setAnswer(0);
        vm.expectRevert(bytes("ETH_USD_FEED stale or empty"));
        d.check(feed, 1 hours, 2600, false);
    }

    /// Preflight and the deployed order contract must agree on whether an oracle round is usable.
    function test_feedRejectsUninitialisedFutureAndZeroMaxAge() public {
        MockEthUsdFeed feed = new MockEthUsdFeed(8, 2600e8);
        feed.setRound(1, 2600e8, 0, 1);
        vm.expectRevert(bytes("ETH_USD_FEED stale or empty"));
        d.check(feed, type(uint256).max, 2600, false);
        feed.setRound(1, 2600e8, vm.getBlockTimestamp() + 1, 1);
        vm.expectRevert(bytes("ETH_USD_FEED stale or empty"));
        d.check(feed, 1 hours, 2600, false);
        feed.setAnswer(2600e8);
        vm.expectRevert(bytes("ETH_USD_FEED_MAX_AGE must be positive"));
        d.check(feed, 0, 2600, false);
    }

    function test_feedFreshnessBoundaryMatchesLimitOrders() public {
        MockEthUsdFeed feed = new MockEthUsdFeed(8, 2600e8);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        d.check(feed, 1 hours, 2600, false);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(bytes("ETH_USD_FEED stale or empty"));
        d.check(feed, 1 hours, 2600, false);
    }

    /// Only Chainlink's Robinhood feed (the default) must read "ETH / USD"; an override's description() is optional
    function test_descriptionOnlyRequiredOfTheDefault() public {
        d.check(new MockEthUsdFeed(8, 2600e8), 1 hours, 2600, true);
        IAggregatorV3 other = IAggregatorV3(address(new BtcUsdFeed()));
        vm.expectRevert(bytes("ETH_USD_FEED is not ETH / USD"));
        d.check(other, 1 hours, 2600, true);
        d.check(other, 1 hours, 2600, false);
        IAggregatorV3 none = IAggregatorV3(address(new NoDescriptionFeed()));
        vm.expectRevert();
        d.check(none, 1 hours, 2600, true);
        d.check(none, 1 hours, 2600, false);
    }

    /// One chain id each, for the block counting and the deployment file's name
    function test_chains() public {
        vm.chainId(31337);
        assertFalse(d.arbitrum());
        assertEq(d.network(), "local");
        vm.chainId(4663);
        assertTrue(d.arbitrum());
        assertEq(d.network(), "robinhood");
        vm.chainId(46630);
        assertTrue(d.arbitrum());
        assertEq(d.network(), "robinhood-sepolia");
        vm.chainId(1);
        assertFalse(d.arbitrum());
        vm.expectRevert(bytes("unknown chain: set DEPLOYMENT"));
        d.network();
    }
}
