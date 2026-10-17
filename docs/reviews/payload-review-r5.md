You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. This is round 5.

Your round 4 (docs/reviews/r4.md, review-r4.out.md) found 3 issues. Claude's fixes in src/HedgedPool.sol, written up as invariants in docs/design.md:
(1) For SPEND_LOCK (1 h) after an order, sendBack never sends the token that order spends (sell -> HYPE, buy -> USDC); the received token only grows, so its read is a lower bound. finish closes at actual balances after SETTLE_DELAY (1 h), on the reasoning that a send Core rejected left its tokens on Core, where they are counted live.
(2) sendBack from Idle and finish are permissionless.
(3) start requires the keeper's ops float on Core (NoOpsFloat).
r4.md explains why two of your PoCs still pass (by design / inconsistent setup); challenge that if you disagree.

Review by breaking: for every finding write a Foundry test under test/poc/, run `forge test`, report numbers. Only add files under test/poc/.

1. Do the fixes hold? The lock across rounds (an order in round N, sendBack/start in round N+1 within the hour; a buy after a sell), the lock using one `lastOrderSoldHype` flag, SETTLE_DELAY closing while a credit is actually still in flight (double count or loss?), retries after the lock expires, `floatAfter` with a locked USDC side.
2. What permissionless sendBack/finish opens: griefing (repeatedly pausing the pool, draining the USDC float to the EVM so buys cannot run, front-running the keeper's start), any way to make value disappear or be counted twice, interaction with swaps right after a permissionless finish.
3. The timing assumptions themselves: are 1 h SPEND_LOCK / SETTLE_DELAY defensible given Hyperliquid's documented CoreWriter delays and Core->EVM transfer semantics (cite sources)? What breaks if they are wrong, and is the failure loss or only a pause?
4. Anything left from rounds 1-4.

Output: findings with severity, PoC and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
