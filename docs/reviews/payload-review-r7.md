You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. This is round 7, and it is narrow.

Rounds 1-6 are recorded in docs/reviews/r1.md-r6.md. After r6 one change went in without review: the commit "price off the Core best bid/ask, not the last trade" (see `git log`). Why: on testnet the last-trade precompile 0x808 sat at the ask of a 2% book, so a sell limit 1% below it never filled (docs/step3-pool-testnet.md). Now src/HedgedPool.sol reads best bid/ask from 0x80e with asset id 10000 + spot index (src/Core.sol `bbo`), uses the mid as `corePx()` for `maxRebalance`, sets the IOC limit at the bid (sell) / ask (buy) bounded by the pool price, and refuses orders when the book is wider than MAX_SPREAD_BPS (5%). The pool then ran on testnet in both directions with this code (docs/step3-pool-testnet.md).

Review only this change and what it touches. Review by breaking: for every finding write a Foundry test under test/poc/, run `forge test`, report numbers. Only add files under test/poc/.

1. Correctness of the BBO read: asset id, decimals (8 - szDecimals for spot), an empty side (bid or ask 0), a crossed or locked book, the spread computation and its rounding, overflow/underflow (ask < bid).
2. Manipulation: the mid now drives maxRebalance and the toEvm MIN_NOTIONAL check. Can someone move the Core top of book cheaply (a tiny order at a far price, spoofing a wide side) to make the keeper's order or maxRebalance act against LPs, or to grief? Compare with the previous last-trade price. Is the 5% spread cap enough, or should the limit also be bounded by something else?
3. Limits at the bid/ask: IOC at the touch fills only the top level; is anything wrong with size vs. top-of-book depth, fees, or tick rounding (`_toTick` with a bid/ask that is already a valid tick)?
4. Cite Hyperliquid sources for the 0x80e semantics if you find any (it is not in the official docs; Claude checked it against the testnet book).

Output: findings with severity, PoC and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
