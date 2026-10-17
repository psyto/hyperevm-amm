You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Round 9, narrow: check the fix for your round 8.

Your round 8 (docs/reviews/r8.md, review-r8.out.md, PoCs in r8-poc.t.sol.txt) found that the full quote check in `toEvm` let a wide or one-sided ask block public HYPE recovery. Claude's fix is the latest commit on this branch (`git show HEAD`): for non-keepers, `toEvm` reads the raw BBO, requires only bid > 0 (else BadQuote(0,0)), and values HYPE at that bid for the 11 USDC minimum; `coreBbo()`'s full check (both sides, not crossed, spread <= 5%) stays for `maxRebalance`, `bridgeHype` and `order`.

Review only this change. Write any PoC under test/poc/, run `forge test`, report numbers. Only add files under test/poc/. Check: the r7 zero-bid protection still holds; a far-away but nonzero bid cannot make dust pass the minimum in a way that matters (compare the cost of placing that bid on Core with the harm: a 2-block pause); a crossed book (bid > ask) in toEvm; the keeper path; anything else in the diff.

Output: findings with severity, PoC and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
