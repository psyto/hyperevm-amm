Findings: **1 high, 3 medium**. PoCs added in [R6AsyncOrderAndFloat.t.sol](test/poc/R6AsyncOrderAndFloat.t.sol).

1. **High — pending IOC can be sandwiched after `order()`**
   - `order()` does not pause EVM swaps. CoreWriter order actions are delayed for seconds, so a trader can move AMM price after the IOC is enqueued, then reverse after its Core fill.
   - PoC: `test_PoC_pendingIocCanBeSandwichedAfterOrder` passes; a 200-USDC sandwich profits **6.893005 USDC**.
   - Root cause: the IOC’s floor/cap is checked against the pool price at submission, not the pool price when it later executes.
   - Fix: the present primitives cannot safely permit concurrent AMM trading and an asynchronously settling external order. Remove the Core-order feature, or introduce a trustworthy settlement attestation/callback and block AMM operations until it confirms settlement. A timeout is not a correctness fix.

2. **Medium — anyone can repeatedly censor a pending HYPE sell**
   - An observer can call `toEvm` after `order(true, ...)`, move the entire Core HYPE input away, and cause the delayed IOC to reject. This can be repeated after each keeper re-bridge.
   - PoC: `test_PoC_anyoneCanCensorPendingSellIocByMovingItsHype` passes.
   - Root cause: public `toEvm` is immediate Core processing, while the order is delayed; no HYPE-side floor or pending-order exclusion exists.
   - Fix: prohibit public withdrawals of an asset committed to an order, which again requires a reliable settlement signal; alternatively make reconciliation keeper-only and accept the liveness tradeoff.

3. **Medium — public USDC recovery can disable all future HYPE bridging**
   - A Core→EVM USDC send consumes Core HYPE gas. One public qualifying send can take the ops balance below `KEEP_HYPE_WEI`; then `bridgeHype` always reverts `NoOpsFloat` until the keeper notices and tops up.
   - PoC: `test_PoC_publicUsdcSendCanDepleteOpsThresholdAndStopBridging` passes.
   - Root cause: `toEvm` is permissionless, while `bridgeHype` requires a strict pre-existing float threshold.
   - Fix: require enough HYPE surplus for the exact Core-side send fee, or make bridge activation depend on account existence plus post-bridge gas funding rather than a brittle pre-call threshold.

4. **Medium — keeper can freeze permissionless payout recovery via `floatFloor`**
   - The keeper can set `floatFloor` to all Core USDC. LP removal then fails for lack of EVM USDC, while non-keepers cannot call `toEvm` to restore liquidity.
   - PoC: `test_PoC_keeperCanFreezeCoreUsdcPayoutLiquidityWithFloor` passes.
   - Root cause: `floatFloor` is unbounded and makes payout liveness depend entirely on the keeper.
   - Fix: cap the protected float, or provide a permissionless withdrawal path that releases Core USDC when EVM-side LP payouts are insolvent.

Hyperliquid confirms that reads are snapshots when the EVM block is constructed, CoreWriter orders are delayed for seconds, and transfers/actions are processed after the EVM block; that ordering enables findings 1–2. [Interaction timings](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings), [CoreWriter and read-precompile documentation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore).

Test results: PoCs **4/4 passing**; full `forge test`: **30 passed, 0 failed**.

VERDICT: CHANGES