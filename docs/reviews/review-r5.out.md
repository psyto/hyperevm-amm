Found 4 issues. Added PoCs in [R5Lifecycle.t.sol](test/poc/R5Lifecycle.t.sol).

1. High — accepted but late Core→EVM credits become permanently unaccounted.

   - PoCs: `test_poc_retryOfLateSellProceedsBecomesUnaccounted`, `test_poc_settleTimeoutDropsAcceptedButLateCreditFromAccounting`.
   - Result: both pass. A retry can send delayed sale proceeds without raising `expectU`; `finish` closes after an earlier credit, and the later credit is excluded forever. Separately, after `SETTLE_DELAY`, an accepted-but-not-yet-credited transfer is neither on Core nor in `rU`; its later EVM credit is also excluded.
   - Root cause: `finish` assumes a missing credit was rejected and remains on Core, omitting the valid in-flight state.
   - Fix: do not finalize while any Core→EVM send may still credit without an authoritative terminal receipt. Track pending sends and reconcile late EVM balances before reopening, including retry sends.

2. Medium — a round N+1 order overwrites the spend lock for a still-pending round N order.

   - PoC: `test_poc_crossRoundOrderOverwritesSpendLock`.
   - Result: passes. A sell locks HYPE, but a subsequent buy replaces `lastOrderSoldHype`; `sendBack` then sends the HYPE that the earlier sell can still spend. The current timeout converts the original permanent freeze into at least a one-hour pause, rather than making the invariant true.
   - Root cause: one `lastOrderSoldHype` / `lastOrderAt` record cannot represent multiple outstanding Core orders.
   - Fix: prohibit a new order until every preceding order is conclusively settled/rejected, or retain per-order pending-asset locks.

3. Medium — anyone can drain the Core USDC float and prevent buy rebalances.

   - PoC: `test_poc_anyoneCanDrainFloatAndBlockBuys`.
   - Result: passes. A third party calls Idle `sendBack`, then `finish`, moving all float to EVM. A valid keeper buy thereafter reverts because `coreU() == 0`; this design has no EVM→Core restoration path.
   - Root cause: permissionless reconciliation also permissionlessly changes the inventory needed for buys.
   - Fix: restrict float withdrawals to keeper-authorized bounded operations, or maintain a protected minimum Core float / dedicated permissionless reconciliation that cannot drain buy liquidity.

4. High — the one-hour timing boundary is not a documented safety guarantee.

   - Hyperliquid documents Core→EVM transfers as queued until the next HyperEVM block, not as having a maximum completion time; it documents order actions as delayed “a few seconds,” again without a hard upper bound. [Interaction timings](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings), [CoreWriter documentation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore)
   - Therefore `SPEND_LOCK` and `SETTLE_DELAY` are operational guesses, not correctness boundaries. If the transfer assumption is wrong, the failure is not merely a pause: the timeout path permanently under-accounts accepted late credits (finding 1). The documented block ordering also confirms EVM reads precede CoreWriter processing. [Interaction timings](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings)

`forge test --match-path test/poc/R5Lifecycle.t.sol -vvv`: 4 passed.  
`forge test`: 37 passed.

VERDICT: CHANGES