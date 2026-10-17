# Step 3: the pool on testnet, both directions

HyperEVM testnet, 2026-10-17. `HedgedPool` (best bid/ask version) at `<pool-2>`,
keeper = LP = the key holder. HYPE/USDC spot `@1035`; Core book about 40.74 / 41.56 (2% wide).

| # | Step | Call | Result |
|---|---|---|---|
| 1 | Core account | key holder sends 1 USDC on Core to the pool (sender pays the 1 USDC activation), then `fundOps{0.015 HYPE}` | `userExists` true; 0.015 HYPE arrived in full (no activation taken: the account existed) |
| 2 | seed, deliberately cheap | `add{0.66 HYPE}(1 USDC)` | reserves 0.665 HYPE / 2 USDC (incl. Core), pool price 3.01; `maxRebalance` = sell 0.308 HYPE |
| 3 | sell leg | `bridgeHype(0.3)`, 2 blocks, `order(true, 0.305)` | landed on Core next read; IOC sold **0.30 at 40.737** (the bid), fee 0.0086 USDC. Reserves 0.365 HYPE / 14.21 USDC, pool price **3.01 → 38.94** (Core mid 41.15) |
| 4 | make the pool dear | key holder sends 25 USDC on Core to the pool | counted at once: pool price 107.4; `maxRebalance` = buy 12.10 USDC |
| 5 | buy leg (Core float) | 30 s quiet, `order(false, 12)` | IOC bought **0.28 at 41.561** (the ask) with float USDC, fee 0.0002 HYPE. Pool price **107.4 → 42.77** |
| 6 | Core → EVM | `toEvm(0.2848 HYPE, 26.575 USDC)` | both credited by the next reads; reserves unchanged (0.6448 HYPE / 27.58 USDC), now all on the EVM |
| 7 | swap | `swapUsdcForHype(1 USDC)` | 0.02249 HYPE |
| 8 | exit | `remove(all shares)` | all back to the key holder except the locked minimum (7.7e-10 HYPE) and the Core ops float (0.00998 HYPE) |

An earlier deployment (`<pool-1>`, the r6 fixes) set the sell limit 1% below the Core *last trade*
(0x808). On testnet the last trade sat at the ask of the 2% book, so the limit (41.159) was above
the best bid (40.75) and the IOC did not fill. Nothing broke: reserves were unchanged. That is
why the next version prices off the best bid/ask (0x80e with asset id 10000 + spot index).

## What it showed
- Both rebalance directions work against the real Core book, and the no-books reserves stayed
  right through bridging, fills, a Core donation and Core → EVM sends, with no reconciliation.
- The quiet periods were short in practice: transfers were visible by the next read.
- The Core → EVM USDC send cost 0.00002 HYPE of the ops float.
