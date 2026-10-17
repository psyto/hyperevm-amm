You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. This is round 2.

Round 1 (yours) found 5 issues: docs/reviews/r1.md lists them, the fixes and their regression tests; your round-1 PoCs are in docs/reviews/r1-poc.t.sol.txt (they assert the old behaviour, so they no longer apply as-is). Claude rebuilt the rebalance state machine in src/HedgedPool.sol around one invariant, written in docs/design.md: what leaves the EVM reserves for Core stays owed until seen back in the EVM balances.

Review by breaking: for every finding, write a Foundry test under test/poc/ that demonstrates it, run `forge test`, report the numbers. Only add files under test/poc/; do not edit src/ or existing tests.

1. Check each round-1 fix actually closes the issue, including variants (e.g. other orders of calls, a partial IOC fill, a bridge that arrives after STUCK_DELAY gave it up, a send dropped on Core after expectations were fixed, ops float below KEEP_HYPE_WEI because gas used it).
2. Attack the new code: the invariant itself (can expectH/expectU be wrong in either direction; can finish close with value missing or be blocked forever), `arrived()`/`coreBefore`, the direction recheck in order() and the caps (max computed on reserves + in-flight), MIN_NOTIONAL, fundOps, the buy leg, any new way to freeze the pool or move LP value to the keeper, a trader or a donor.
3. Anything still wrong about HyperCore semantics (cite sources).

Read docs/step0-corewriter.md and docs/step1-bridging.md for the measured testnet behaviour. Output: findings with severity, PoC name and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
