# Step 1: moving tokens between the EVM and Core from a contract

HyperEVM testnet, 2026-10-17. `CoreProbe` v2 at `<probe-2>`.

| Path | How | Result |
|---|---|---|
| HYPE EVM → Core | contract sends 0.1 HYPE to `0x2222…` | arrived by the next read. First transfer into the new Core account paid `accountActivationGas` 0.02321424 HYPE (≈ 1 USDC) out of the amount |
| HYPE Core → EVM | `sendAsset(0x2222…, spot, spot, 1105, 0.05e8)` | arrived by the next read. **`receive()` was not called** (no `Received` event); the balance just grew |
| USDC Core → EVM | `sendAsset(0x2000…0000, spot, spot, 0, 1.5e8)` | arrived within 1 s as ERC20 `0x2B33…`. Cost 0.00002 HYPE from the contract's Core HYPE (a non-HYPE send needs Core HYPE for gas) |
| USDC EVM → Core, contract calls `deposit` | approve + `CoreDepositWallet.deposit(4e6, spot)` | **not credited** after 20+ min. The wallet emitted `Transfer(probe → 0x2000…0000, 4e6)`; no ledger entry on Core for anyone |
| USDC EVM → Core, EOA `depositFor(probe)` | EOA approve + `depositFor(probe, 1.5e6, spot)` | **not credited** either; same `Transfer(probe → 0x2000…0000)` |
| USDC EVM → Core, EOA `deposit` (control) | EOA approve + `deposit(1e6, spot)` | credited to the EOA within 1 s |

So on testnet today, USDC sent through the deposit wallet **to a contract's Core account** did not
arrive, whoever called it; to an EOA it did. Cause unknown. 5.5 testnet USDC are unaccounted for.
Before relying on it on mainnet, ask Circle/Hyperliquid or test with a dollar.

## What it means for the pool
- Selling HYPE on Core works end to end: HYPE in through `0x2222…`, IOC on `@1035`, USDC back
  through `0x2000…0000`. `finish()` has to compare balances, which it does.
- Buying HYPE on Core cannot start from EVM USDC. Options: keep a USDC float on the pool's Core
  account (filled by earlier HYPE sales) and count it through the spot-balance precompile, or
  have the buy leg skip USDC entirely.
- The pool's Core account must keep some HYPE for Core → EVM USDC sends (`KEEP_HYPE_WEI`).
