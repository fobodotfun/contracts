# FOBO hook

Source of **FoboHook**, the Uniswap v4 hook behind [fobo.fun](https://fobo.fun), with the libraries and interfaces it imports.

| | |
|---|---|
| Chain | Robinhood Chain (4663) |
| FoboHook | `0x0Af57F62982D03066ef917AcAd87F771c06528Ec` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Verified source | [Sourcify (exact match)](https://repo.sourcify.dev/4663/0x0Af57F62982D03066ef917AcAd87F771c06528Ec) |

## What it does

- Owns every FOBO pool and its liquidity: the hook places the launch positions itself, and nobody else can add liquidity or donate.
- Charges a tax on the quote side of every swap (no LP fee): 2.5% (1.5% to the token's floor, 0.6% to its creator, 0.4% to the protocol), and in a token's first 60 seconds a launch tax falling linearly from 90% to 2.5%.
- Keeps a single-tick floor under the price, sized to buy back every token held outside the pool, raised once per block on the state the block started with. The floor only moves up.
- Not upgradeable: no proxy, no `delegatecall`, no owner. Swaps need no custom `hookData`.

Hook permissions: `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeDonate`, `beforeSwapReturnsDelta`, `afterSwapReturnsDelta`.

## Build

```sh
git clone --recurse-submodules https://github.com/fobodotfun/contracts
cd contracts
forge build
```

Solidity 0.8.26, `via_ir`, optimizer 200 runs, EVM `cancun`. Uniswap v4-core is pinned at v4.0.0 (`lib/v4-core`).

## License

MIT
