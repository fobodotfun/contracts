# FOBO contracts

Source of the contracts behind [fobo.fun](https://fobo.fun), a token launchpad on Robinhood Chain where every token's floor only goes up.

| Contract | Address (Robinhood Chain, 4663) | What it does |
|---|---|---|
| FoboHook | `0x0Af57F62982D03066ef917AcAd87F771c06528Ec` | The Uniswap v4 hook: owns every FOBO pool and its liquidity, charges the swap tax, keeps the floor ([Sourcify, exact match](https://repo.sourcify.dev/4663/0x0Af57F62982D03066ef917AcAd87F771c06528Ec)) |
| FoboFactory | `0xd7e538e98A208fD19e46bc549FF4710C33664e18` | Creates each token and its pool in one transaction |
| FoboToken | one per launch (e.g. $FOBO `0x000de658153f47f23e92973c8eb1e89762703676`) | Plain ERC-20, fixed 1,000,000,000 supply, burnable |
| FoboVesting | `0x51d217Ecf7c0e4EbF54258444B9617D012Fd7D0a` | Linear token locks (e.g. a creator's locked launch buy); a claim always pays the beneficiary |
| FoboRevenue | `0x8819036A0f6940285b6ea6D6B80cdC702ce8CB54` | Splits the protocol fee between partners, referrers and the team |
| FoboBurner | `0x5541141CC427441F7eD5BD93Bd16AC87a890990d` | Buys back and burns $FOBO with its share of the launch tax |
| FoboLimitOrders | `0x3126f62d604a0AA2de8788e3eC21dDd8F2a2f82a` | Limit orders, filled by a keeper through the hook's pools |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Uniswap's own deployment |

## How a FOBO pool works

- The hook places the token's entire supply as liquidity at launch and owns the positions inside the v4 PoolManager. No LP token or position NFT is minted, nobody else can add liquidity or donate, and the hook has no owner, no withdraw function and no proxy, so the liquidity can't be removed.
- Every swap pays a tax on its quote side (no LP fee): 2.5%, of which 1.5% goes to the token's floor, 0.6% to its creator and 0.4% to the protocol. In a token's first 60 seconds a launch tax falls linearly from 90% to 2.5%; none of it goes to the creator.
- The floor is a single-tick wall under the price, sized to buy back every token held outside the pool, raised once per block. It only moves up.

Hook permissions: `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeDonate`, `beforeSwapReturnsDelta`, `afterSwapReturnsDelta`.

## ABIs

`abi/` holds each contract's ABI as JSON, built from this source. Key events for indexers:

- `FoboFactory.TokenLaunched`: a new token and its pool (token, poolId, creator, quote, name, ticker, metadataURI).
- `FoboHook.TaxPaid`: every swap's tax and quote volume. `FloorRaised` and `BoughtBack` track the floor.
- `FoboVesting.Locked` / `Claimed`: locked supply.
- Swaps and prices are Uniswap v4's own `PoolManager` `Initialize` / `Swap` events (pools with `hooks` = FoboHook).

## Build

```sh
git clone --recurse-submodules https://github.com/fobodotfun/contracts
cd contracts
forge build
```

Solidity 0.8.26, `via_ir`, optimizer 200 runs, EVM `cancun`. Uniswap v4-core is pinned at v4.0.0 (`lib/v4-core`), with the OpenZeppelin contracts it bundles.

## License

MIT
