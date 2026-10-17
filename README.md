# hyperevm-amm

Learning HyperEVM by building an exchange whose pool hedges on HyperCore.

- `src/Core.sol` — CoreWriter actions (write to HyperCore) and precompile reads.
- `src/CoreProbe.sol` — step 0: a contract that holds a Core account, trades, and reads back.
- `docs/step0-corewriter.md` — the testnet run and what it taught.
- `script/core_send.py` — fund an address on HyperCore, or print its Core state (`--state`).

```
forge test
```
