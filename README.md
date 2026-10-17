# hyperevm-amm

Learning HyperEVM by building an exchange whose pool hedges on HyperCore.

- `src/Core.sol` — CoreWriter actions (write to HyperCore) and precompile reads.
- `src/CoreProbe.sol` — step 0: a contract that holds a Core account, trades, and reads back.
- `src/HedgedPool.sol` — the pool (draft): x·y=k that rebalances itself on Core. `docs/design.md`.
- `docs/step0-corewriter.md`, `docs/step1-bridging.md` — testnet runs and what they taught.
- `script/lib.sh` — rate-limit-safe `cast` helpers for testnet.
- `script/core_send.py` — fund an address on HyperCore, or print its Core state (`--state`).

```
forge test
```
