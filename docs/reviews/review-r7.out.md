## Findings

1. **Medium — rebalance sizes on mid but executes at touch, realizing spread + fees against LPs.**  
   PoC: [R7BboPoc.t.sol](test/poc/R7BboPoc.t.sol:77) passes.

   A 40/42 book has a 41 mid and 487 bps spread, so it passes the 5% cap. With pool price 40, `order(true)` sells at the 40 bid because the mid says HYPE is overweight. A 1 HYPE fill yields $39.972 after Hyperliquid’s base 7 bp spot taker fee, reducing pool value at its own 41 midpoint by $1.028.

   Root cause: direction and `maxRebalance` use mid; execution uses bid/ask; the pool-price guard is gross and ignores both half-spread and fees. Hyperliquid documents nonzero spot taker fees. [Fees](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees)

   Fix: calculate sell direction/size from a conservative net bid and buys from a conservative gross ask, including a configured worst-case fee. Only trade when that executable price improves on the pool price by a margin.

2. **Medium — unvalidated BBO bypasses `toEvm`’s anti-grief minimum and malformed quotes panic orders.**  
   PoCs: [one-sided spoof](test/poc/R7BboPoc.t.sol:101) and [crossed-book panic](test/poc/R7BboPoc.t.sol:114) pass.

   `toEvm` calls unvalidated `corePx()`, unlike `order`. A zero bid plus one far ask makes one wei of HYPE appear worth at least $11, allowing a public transfer and its two-block pause. A crossed quote instead panics at `ask - bid`, rather than rejecting the quote cleanly. Empty quotes can also make the spread division divide by zero.

   Root cause: midpoint consumers (`corePx`, `maxRebalance`, `bridgeHype`, and `toEvm`) do not share quote validation.

   Fix: centralize quote validation: require nonzero bid/ask, `ask >= bid`, and a capped spread before computing a midpoint. For HYPE in `toEvm`, use conservative bid valuation or a fixed HYPE minimum; reject HYPE-only transfers when the book is incomplete.

## Other review notes

- For valid quotes, asset `10000 + spotIndex` is consistent with the CoreWriter order asset, and `8 - szDecimals` scaling is consistent with Hyperliquid’s documented generic spot-price rule. [Read precompiles](https://hyperliquid.gitbook.io/Hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore)
- I found no official Hyperliquid source documenting `0x80e`, its ABI, or its empty-side behavior. The generic precompile docs do not establish those semantics.
- Locked books work; valid `uint64` quotes are widened before midpoint arithmetic. Spread rounding floors, so a fractionally-over-500-bps book may pass.
- A tiny quote can only become BBO by improving the existing touch; an IOC at that touch cannot walk worse levels, so shallow spoofing mainly causes a tiny fill/cancel and keeper grief. It does not eliminate the two findings above. `_toTick` preserves an already-valid BBO tick.

Added only [test/poc/R7BboPoc.t.sol](test/poc/R7BboPoc.t.sol). `forge test`: **33 passed, 0 failed**.

VERDICT: CHANGES