Found 2 issues. Added PoCs in [Round2StateMachine.t.sol](test/poc/Round2StateMachine.t.sol).

1. High — IOC can execute on the wrong side after the direction check  
   PoC: `test_PoC_iocLimitCrossesPoolPriceDuringCoreWriterDelay` — PASS. It emits a sell IOC at 39.897 while total pool inventory is priced at 40.000 USDC/HYPE.

   Root cause: `order()` checks direction using a Core price read now, but CoreWriter order actions execute several seconds later. For small price gaps, the fixed 1% sell limit is already below pool price; a price reversal during that delay can fill the order at a loss to the pool.

   Fix: bound sell limits to at least the full pre-bridge pool price and buy limits to at most it; use directional tick rounding (ceil sell floors, floor buy caps). Reject/retry if that produces no executable IOC. Hyperliquid documents that CoreWriter orders are delayed and appear first as enqueued, then as Core executions. [Source](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore)

2. High — `STUCK_DELAY` abandonment still writes off a bridge that arrives late  
   PoC: `test_PoC_lateBridgeAfterStuckDelayIsUnaccounted` — PASS. After abandoning a 100-USDC buy bridge, `finish()` restores `Idle` with `rU = 3,900`; a later 100-USDC Core credit remains outside LP accounting.

   Root cause: the timeout turns an unconfirmed transfer into a terminal loss and clears `inFlight`. Once idle, there is no reconciliation/recovery route for that Core balance. This is especially material because the measured contract-account USDC deposit failure is precisely the triggering condition.

   Fix: retain an explicit unsettled-bridge debt and add a reconciliation/recovery transition that can return late Core balances even after timeout. Do not permit the normal terminal accounting transition solely because the expected balance was not observed.

Round-one status: dust rejection, retry-stable expectations, immediate reversal handling, and the basic stuck-bridge escape are correctly covered; partial IOC return accounting is consistent with the current send-all-Core-balance logic. The ops float is excluded from LP NAV as intended, but requires keeper top-ups because Core-to-EVM transfers consume Core HYPE; Hyperliquid confirms Core-side HYPE gas is required. [Source](https://hyperliquid.gitbook.io/hyperliquid-docs/onboarding/how-to-use-the-hyperevm)

`forge test`: 21 passed, 0 failed, 0 skipped.

VERDICT: CHANGES