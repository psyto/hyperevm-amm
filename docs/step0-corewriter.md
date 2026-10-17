# Step 0: a contract that trades on HyperCore

Run on HyperEVM testnet (chain 998) on 2026-10-17. `CoreProbe` at
`<probe-1>`, owned by the key holder.

## What was done
| # | Action | How | Result |
|---|---|---|---|
| 1 | Deploy `CoreProbe` | `forge create … --legacy` | small block was enough |
| 2 | Give the contract a Core account with 15 USDC | `script/core_send.py <probe> 15` (sendAsset spot→spot) | `exists()` true, `usdc().total` = 15e8 |
| 3 | 14 USDC spot → perp | `moveUsd(14e6, true)` (action 7) | `withdrawable()` = 14e6 by the next read |
| 4 | Buy 0.0002 BTC IOC at mid +2% | `order(3, true, 83172e8, 0.0002e8, false, 3, 1001)` (action 1) | filled at 81541 / 81549 in two fills; position visible ≤ 4 s after the tx |
| 5 | Close, reduce-only IOC at mid −2% | `order(3, false, …, 0.0002e8, true, 3, 1002)` | position 0 |
| 6 | Perp → spot, then all USDC back | `moveUsd(…, false)`, `sendSpot(owner, 0, 1498264500)` (action 6) | probe empty, owner +14.982645 |

Cost: 1.00 USDC new-account fee (charged to the sender in step 2, on top of the 15) + 0.017
USDC fees and spread.

## Things that are not obvious
- **Units differ between write and read.** Orders take `sz` × 1e8 (0.0002 BTC = 20000). The
  position precompile (0x800) returns `szi` in the market's `szDecimals` (BTC 5 → 20).
  `entryNtl` and `withdrawable` are USD × 1e6; spot balances are token wei (USDC 8 decimals).
- **Prices still need the market's tick.** `limitPx` is × 1e8 but must be a valid HyperCore
  price (5 significant figures, at most `6 − szDecimals` decimals); otherwise HyperCore drops the
  order and nothing on the EVM side says so.
- **A contract's Core account is `default`, not unified**: spot and perp are separate, so it
  has to move USDC to perp (action 7) before it can trade perps.
- **A unified-account sender cannot use `usdSend` or `spotSend`** ("Action disabled when
  unified account is active"). `sendAsset` spot→spot works.
- **Sending to an address with no Core account costs the sender 1 USDC.**
- **A transport error is not a failed transaction.** In one run the RPC rate-limited `cast
  send`, which printed an error, but the transaction had gone through: USDC left perp while the
  position was still open (margin fell to 1.63 USD for a 16 USD position at 20x). Always read
  the state back before the next step, and never move collateral before reading the position
  as 0.
- Writes cost ~47K gas; CoreWriter emits the raw action as a log (`RawAction(address,bytes)`),
  which is the only on-EVM trace of what was sent.

## Next
The AMM step: a pool whose skew is hedged on HyperCore through these same actions, with the
hedge reconciled by reading the position back in a later block.
