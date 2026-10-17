Found 2 issues. Added verified PoCs in [Round3Float.t.sol](test/poc/Round3Float.t.sol).

1. High — fixed `ORDER_DELAY` can reopen the pool before an IOC settles

PoC: `test_PoC_lateIocFillOpensPoolWithPurchasedHypeMissingFromReserves` passes. A buy IOC remains pending past 10 seconds; `sendBack(0)` and `finish()` reopen the pool with `rH = 100`. When the IOC later buys 2.6 HYPE, `coreU()` reflects spent USDC but `rH` omits the acquired HYPE. A public trader then sells 1 HYPE to the AMM for over 1 USDC more than the reconciled quote.

Root cause: `sendBack()` treats elapsed time as order-settlement proof, while `finish()` only tests EVM balances and clears `inFlight`. Core read values are snapshots when the EVM block is built; CoreWriter actions run afterwards, and orders are deliberately delayed. [Hyperliquid interaction timings](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings), [CoreWriter documentation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore).

Fix: do not allow `finish()` to close an ordered round based solely on a timeout. Require an authoritative settlement/rejection acknowledgement for the specific order, or retain an unsettled-order debt and keep swaps/liquidity paused until later Core reconciliation proves no order can still execute.

2. Medium — first LP can capture a pre-funded Core float

PoC: `test_PoC_firstLpCapturesPreFundedCoreFloat` passes. After a third party directly sends 500 USDC to the pool’s Core account, a frontrunner initializes with only 0.01 HYPE and 11 USDC. After normal keeper reconciliation, they withdraw over 510.999 USDC, capturing essentially all of the 500-USDC float.

Root cause: initial shares use only `sqrt(h * u)` while withdrawals use `reserveU()`, which includes the pre-existing Core float. This contradicts the intended “direct Core send counts as a donation to LPs” bootstrap path in [design.md](docs/design.md:60).

Fix: prohibit permissionless initialization while `coreU() != 0`, or add an owner-controlled atomic bootstrap that assigns/mints the pre-funded float to its intended beneficiary or locked liquidity.

`forge test`: 26 passed, 0 failed, 0 skipped.

VERDICT: CHANGES