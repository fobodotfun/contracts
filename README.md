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

## Governance

Every owner power sits behind the 2-of-3 owner Safe, and the two that matter most sit behind more:

```
Safe (2-of-3)
 ├─ TimelockController (OpenZeppelin, 48h minimum delay; the Safe proposes and executes; no admin)
 │    └─ owns FoboBurner        every owner action on the buyback funds is announced 48h before it can run
 └─ owns FoboQuoteGate          which owns FoboFactory
      ├─ allow(quote): only after probe() (exact receipt, no callback), 7,200 blocks (~24h) and an unchanged sample
      ├─ disallow(quote): immediate
      └─ the factory's other owner functions pass straight through (pause, signer rotation stay immediate)
```

`FoboBoundedFeed` wraps the Chainlink ETH/USD feed for `FoboLimitOrders`: same interface, every call forwarded, but an
answer outside $100–$100,000 or a move over 50% against the previous round reverts instead of settling a fill.
`script/Govern.s.sol` deploys the three and prints the Safe transactions; `script/govern-rehearsal.sh` runs the whole
change on a mainnet fork first. Addresses are listed in `docs/audit/` once deployed.

### Allowed quote tokens

A pool's quote is what it trades against. Besides ETH and $FOBO, the factory allows these (each probed on a fork by the
gate's rules; see `docs/audit/`): USDG `0x5fc5360d0400a0fd4f2af552add042d716f1d168`, and the stock tokens MSFT
`0xe93237c50d904957cf27e7b1133b510c669c2e74`, TSLA `0x322f0929c4625ed5bad873c95208d54e1c003b2d`, SPCX
`0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea`, GOOGL `0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3`, AMZN
`0x12f190a9f9d7d37a250758b26824b97ce941bf54`, AAPL `0xaf3d76f1834a1d425780943c99ea8a608f8a93f9`, NVDA
`0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec`, META `0xc0d6457c16cc70d6790dd43521c899c87ce02f35`.

## Audit

Coinsult's manual audit (2026-10-30), FOBO's response and the key-custody evidence are in `docs/audit/`.

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

## Tests

```sh
forge test
```

`test/` is the full suite (377 tests, fuzz at 1000 runs each, about a minute): unit tests per contract, the attack
scenarios kept as regression tests (`AttackEcon.t.sol`, `AttackRevenue.t.sol`, `Audit*.t.sol`), and the floor's fuzz
and invariant suites, among them `Fobo.t.sol` (`testFuzz_everyoneCanAlwaysExitAboveTheFloor`,
`testFuzz_floorHoldsAcrossTranches`) and `AuditInv.t.sol` (random trades across blocks, then every holder exits: no
floor ever drops, no raise ever fails). `script/Deploy.s.sol` is the deploy script the tests run against.

## Integrating

- **Gas.** On the first swap of a block in a pool whose floor can rise, the hook reserves gas up front for the raise
  (700k) and the fee credit (400k) and reverts `NeedGas` without it, so a swap can need about **1.2M gas** on that
  block and far less on others. Estimate on a block where the raise fires, not the cheapest simulation.
- **Referrals.** A swap's referral is credited to `tx.origin` unless it comes from `FoboLimitOrders`, which passes the
  trader in `hookData`. Swaps from smart-contract wallets or bundlers credit the bundler; that share goes to the team.
- **Sells fill completely or revert** (`PartialFill`): ask for what the pool can give.

## License

MIT
