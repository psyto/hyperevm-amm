# Step 2: how long a CoreWriter order takes to run

HyperEVM testnet, 2026-10-17. `CoreProbe` v2 (`<probe-2>`) sent 10 IOCs of 0.3 HYPE on the
HYPE/USDC spot market `@1035` (asset 11035), alternating sell and buy, about 6 s apart, with
`script/measure_order_delay.sh`. Delay = Core fill time (`userFillsByTime`, ms) minus the EVM
block timestamp of the transaction (s).

| # | side | EVM block | delay |
|---|---|---|---|
| 1 | sell | — | 477 ms |
| 1 | buy | — | 413 ms |
| 2 | sell | — | 415 ms |
| 2 | buy | — | 391 ms |
| 3 | sell | — | 439 ms |
| 3 | buy | — | 405 ms |
| 4 | sell | — | 373 ms |
| 4 | buy | — | 468 ms |
| 5 | sell | — | 347 ms |
| 5 | buy | — | 429 ms |

All 10 filled. 347–477 ms after the block timestamp; since the timestamp is whole seconds, the
real delay is under 1.5 s in the worst case. (An 11th buy, sent by a script bug, also filled.)

## What it means
- On testnet the order "delay" is well under the "few seconds" the docs describe; mainnet may
  differ (the delay exists so CoreWriter cannot jump the queue of normal orders), so measure
  again there before relying on it.
- `ORDER_QUIET` = 30 s in `HedgedPool` is about 20× the worst case seen here.
- Cost: 10 round trips' worth of spread on 0.3 HYPE, about 1.2 testnet USDC; leftover HYPE and
  USDC were returned to the key holder.
