# hyperevm-amm

Learning HyperEVM by building something on it: a HYPE/USDC x·y=k pool that **closes its own gap
to the HyperCore price by trading on HyperCore**, instead of leaving it to outside arbitrageurs.

Status (2026-10-17): a learning project, not audited, not for real funds. The contract-side
building blocks (orders, transfers both ways) have run on HyperEVM testnet; the pool itself
has only run in tests. Five adversarial review rounds by Codex found holes every time in the
pool's own bookkeeping, so after round 5 it was rebuilt to keep no books at all; round 6 is in
progress.

## How it works
- **No books: reserves are balances.** HYPE and USDC on the EVM plus HYPE and USDC on the pool's
  own HyperCore account (read live through the spot-balance precompile). Prices and LP shares use
  the sums; payouts come only from the EVM side. A Core order that fills late, a transfer that
  lands late or is rejected: each only changes balances that are already counted.
- **One gap, covered by block ordering.** Tokens moving between the EVM and Core are briefly in
  neither balance. Hyperliquid documents that such transfers complete within the next HyperEVM
  block, so after any transfer the pool waits 2 blocks before swaps and liquidity resume.
- **Rebalancing (keeper).** When the pool price drifts from the Core spot price, the keeper
  bridges HYPE to Core and sells it with an IOC, or buys HYPE with the USDC float on Core. IOC
  limits never cross the pool price.
- **USDC only moves Core → EVM.** Sales fill the USDC float, buys spend it, and anyone can bring
  Core inventory to the EVM (USDC only above the keeper's floor). (USDC sent EVM → Core into a
  contract's Core account never arrived on testnet.)

Details: [docs/design.md](docs/design.md).

## Layout
| Path | What |
|---|---|
| `src/Core.sol` | CoreWriter actions (orders, transfers, `sendAsset`) and precompile reads |
| `src/HedgedPool.sol` | the pool |
| `src/CoreProbe.sol` | a small contract used to measure HyperCore behaviour on testnet |
| `docs/step0-corewriter.md` | testnet: a contract trading on HyperCore and reading the result back |
| `docs/step1-bridging.md` | testnet: moving HYPE and USDC between the EVM and Core from a contract |
| `docs/reviews/` | Codex review rounds: payloads, outputs, PoCs, and what was fixed (`r1.md`–`r5.md`) |
| `script/lib.sh` | rate-limit-safe `cast` helpers for the public testnet RPC |
| `script/core_send.py` | send USDC on HyperCore, or print an address's Core state (`--state`) |

## Run
```
forge test
```
26 tests: CoreWriter encodings, and the pool against a simulated Core (mocked precompiles and a
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
