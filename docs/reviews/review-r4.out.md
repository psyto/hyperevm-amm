Found 3 issues. PoCs added in [R4CoreHype.t.sol](test/poc/R4CoreHype.t.sol).

1. High — an IOC fill between `sendBack()`’s snapshot and its later Core `sendAsset` can permanently lock the pool.

   - PoCs: sell and buy variants both pass.
   - Result: `expectH`/`expectU` is fixed from pre-fill balances; the delayed IOC then spends the asset promised to the EVM. The bridge action cannot deliver its original amount, while retries cannot lower the expectation. `finish()` remains impossible without an external recapitalization.
   - Root cause: 0x801 reads the Core state used to construct the EVM block, while CoreWriter actions run afterwards; limit orders are separately delayed. [HyperCore timing](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings), [CoreWriter docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore).
   - Fix: do not send assets or fix return expectations while an IOC can still execute. Require an authoritative terminal settlement/rejection acknowledgement, or retain the round as paused until a protocol-verifiable reconciliation is available. A longer timeout is not sufficient.

2. Medium — unsolicited Core HYPE can freeze large swaps and LP withdrawals.

   - PoC passes: a 100-HYPE Core donation raises `reserveH` to 200 HYPE while `rH` remains 100; the normal LP burn reverts `NotEnoughEvmHype`.
   - Root cause: pricing and pro-rata redemption use live Core HYPE, but synchronous outputs only use EVM HYPE. Any Core user can send a spot asset to the pool address. [Core spot-transfer API](https://hyperliquid.gitbook.io/Hyperliquid-docs/for-developers/api/exchange-endpoint).
   - Fix: add a permissionless/safely queued Core-to-EVM reconciliation path, or pause direct payouts whenever Core inventory is nonzero and use asynchronous withdrawals. Do not quote immediately payable outputs from inaccessible inventory.

3. Low — an unactivated Core account charges LP HYPE for activation and initial ops funding.

   - PoC passes: the measured 0.02321424 HYPE activation charge plus the 0.01 HYPE retained ops float reduces LP `rH` by 0.03321424 HYPE on the first untraded sell.
   - Root cause: `start()` permits bridging before keeper-funded Core activation, despite the stated keeper-funded invariant. New Core accounts charge the destination’s first transaction a one-quote-token fee. [Activation-fee documentation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/activation-gas-fee), [measured testnet result](docs/step1-bridging.md).
   - Fix: require verified pre-activation and a Core HYPE ops balance before opening LP trading or allowing `start()`.

The r3 live-Core-HYPE fix does correctly cover late fills after `finish`, including partial fills: both sides remain live-counted. It also avoids double-counting during `OnCore`/`Ordered`/`Returning` because swaps and liquidity are paused. A late bridge after give-up is now live-counted and recoverable. `arrived()` correctly uses `coreBefore` when Core already holds HYPE, although an unsolicited donation during that interval is treated as arrived inventory. The remaining failure is the expectation snapshot race above, not reserve valuation.

`forge test --match-path test/poc/R4CoreHype.t.sol -vvv`: 4 passed.  
`forge test`: 31 passed.

VERDICT: CHANGES