You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Round 8, narrow: check the fixes for your round 7.

Your round 7 (docs/reviews/r7.md, review-r7.out.md, PoCs in r7-poc.t.sol.txt) found 2 issues in the best bid/ask pricing. Claude's fix is the commit that fixed round 7 (the latest commits before this review): `executable()` returns bid × (1 − 10 bp) and ask × (1 + 10 bp, rounded up); `maxRebalance`/`_maxExecutable` sell only when that net bid beats the pool price and buy only when that gross ask is below it, sizing toward that price; `order` uses the same, with the limit at the bid/ask; `coreBbo()` now rejects bid == 0, ask < bid, and spread > 5% (rounded up) for every caller; `toEvm` values HYPE at the checked bid for non-keepers. Your three PoCs now fail with BadQuote / BadQuote / WrongDirection.

Review only this change. Review by breaking: write any PoC under test/poc/, run `forge test`, report numbers. Only add files under test/poc/.

1. Do the fixes close both findings, including variants (fee higher than 10 bp on the real fee schedule, the IOC filling at a better price, rounding in `executable` and `_maxExecutable`, pool price exactly at the net bid)?
2. Does the stricter quote check create a new freeze or grief: e.g. anyone making the Core book one-sided or wide to block `toEvm` HYPE transfers by others, `bridgeHype`, or anything LPs need (swaps, add, remove must not depend on the quote: confirm)?
3. Anything else in the diff.

Output: findings with severity, PoC and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
