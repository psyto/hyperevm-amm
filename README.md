# hyperevm-amm

Learning HyperEVM by building something on it: a HYPE/USDC x·y=k pool that **closes its own gap
to the HyperCore price by trading on HyperCore**, instead of leaving it to outside arbitrageurs.

Status (2026-10-17): a learning project, not audited, not for real funds. The contract-side
building blocks (orders, transfers both ways) have run on HyperEVM testnet; the pool itself
has only run in tests. It has been through three adversarial review rounds by Codex (all
CHANGES, all fixed); round 4 is in progress.

## How it works
- **Reserves live in two places.** HYPE and USDC on the EVM (`rH`, `rU`) and on the pool's own
  HyperCore account (`coreH()`, `coreU()`, read live through the spot-balance precompile). Prices
  and LP shares use the sums; payouts come only from the EVM side.
- **Rebalancing (keeper).** When the pool price drifts from the Core spot price, the keeper runs
  `start → order → sendBack → finish`: bridge HYPE to Core (sell) or earmark the Core USDC float
  (buy), send one IOC on the Core spot market through CoreWriter, bring tokens back to the EVM,
  and close once the EVM balances show them. Swaps and liquidity are paused in between.
- **USDC only moves Core → EVM.** Sales on Core fill the USDC float, buys spend it, and the keeper
  moves float to the EVM when traders or LPs need it there. (USDC sent EVM → Core into a
  contract's Core account never arrived on testnet.)
- **Invariant.** What leaves one side stays owed until it is seen on the other. IOC limits never
  cross the pool price. Every stage has a way out.

Details: [docs/design.md](docs/design.md).

## Layout
| Path | What |
|---|---|
| `src/Core.sol` | CoreWriter actions (orders, transfers, `sendAsset`) and precompile reads |
| `src/HedgedPool.sol` | the pool |
| `src/CoreProbe.sol` | a small contract used to measure HyperCore behaviour on testnet |
| `docs/step0-corewriter.md` | testnet: a contract trading on HyperCore and reading the result back |
| `docs/step1-bridging.md` | testnet: moving HYPE and USDC between the EVM and Core from a contract |
| `docs/reviews/` | Codex review rounds: payloads, outputs, PoCs, and what was fixed (`r1.md`–`r3.md`) |
| `script/lib.sh` | rate-limit-safe `cast` helpers for the public testnet RPC |
| `script/core_send.py` | send USDC on HyperCore, or print an address's Core state (`--state`) |

## Run
```
forge test
```
27 tests: CoreWriter encodings, and the pool against a simulated Core (mocked precompiles and a
recording CoreWriter).

## Things HyperEVM taught (measured on testnet)
- CoreWriter actions run after the EVM block, orders a few seconds later; nothing comes back.
- Order sizes are × 1e8, but the position precompile returns `szDecimals` units.
- Core → EVM credits do not call `receive()`; contracts only see a larger balance.
- A contract's Core account is not unified: spot and perp are separate.
- The first transfer into a new Core account pays ~1 USDC of activation.
- A rate-limited `cast send` may still have been broadcast: read state back before the next step.

## License
Apache-2.0
