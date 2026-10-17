# Pool design (draft)

A HYPE/USDC constant-product pool on HyperEVM that **arbitrages itself on HyperCore** instead of
leaving the gap to outside arbitrageurs.

## Why
In a plain x·y=k pool, every move of the outside price is closed by an arbitrageur, who keeps the
difference (loss-versus-rebalancing, LVR). On HyperEVM the pool can reach the deepest HYPE
market itself: HyperCore spot `@1035` on testnet (`@107` HYPE/USDC on mainnet) through CoreWriter.

## State
- EVM reserves `rH` (HYPE, 18 decimals, native) and `rU` (USDC ERC20, 6 decimals).
- **The USDC float**: USDC on the pool's own Core account, read live through the spot-balance
  precompile (`coreU()`). The pool's USDC is `reserveU() = rU + coreU()`; prices and LP shares use
  it. USDC can only be paid out from `rU`, so a swap or a withdrawal larger than `rU` reverts
  (`NotEnoughEvmUsdc`) until the keeper brings float over.
- HYPE on Core beyond the keeper's ops float is not counted while Idle (it should not be there).
- LP shares, proportional mint/burn. A rebalance state: `Idle → OnCore → Ordered → Returning → Idle`.

## Why a float
USDC sent EVM → Core into a contract's Core account did not arrive on testnet
(docs/step1-bridging.md; reported as a testnet-only restriction). Core → EVM works. So USDC only
ever moves Core → EVM: sales on Core fill the float, buys on Core spend it, and the keeper moves
float to the EVM when it is needed there.

## Swaps
x·y=k with a fee on `rH` / `reserveU()`, `minOut`. Swaps, adds and removes are paused while a
rebalance is in flight.

## Invariant (review r1)
What leaves the EVM reserves or the float for the other side stays owed until it is seen there.
`sendBack` fixes `expectH`/`expectU` once; retries (in a later block) resend only what a dropped
send left on Core (`floatAfter`) and never lower them. Ways out of every stage: `order` reverts if
the price has turned (then `sendBack` returns the HYPE untraded); `sendBack` from `OnCore` once
the HYPE has arrived, or after `STUCK_DELAY`. Rebalances under 11 USDC are refused. The Core HYPE
float is keeper-funded (`fundOps`).

## Rebalance (keeper, v1 owner-only)
1. **start(sellHype, amount)** — sell: bridge HYPE to `0x2222…`. Buy: earmark `amount` of the float
   (must be ≤ `coreU()`); nothing moves. Both bounded by `maxRebalance` and `MIN_NOTIONAL`.
2. **order()** — recheck the direction on current reserves, then one IOC on the Core spot market,
   limit 1% off the Core spot price (0x808), rounded to the tick.
3. **sendBack(uToEvm)** — after the order delay: HYPE above the ops float back to the EVM, plus
   `uToEvm` of the USDC float; the rest stays as float. Also callable from `Idle` to move float.
4. **finish()** — when the EVM balances reach what was sent, set `rH`/`rU` to them and unpause.

How far to rebalance: only toward the Core price, never past it — the amount that moves
`reserveU/rH` to the Core mid, capped per call.

## Facts this rests on (measured on testnet, docs/step0-corewriter.md)
- CoreWriter writes run after the EVM block; IOC fills were visible ≤ 4 s later.
- Core → EVM credits do **not** call `receive()`; the contract only sees a larger balance.
  So `finish()` must compare balances, not wait for a callback.
- The first transfer into a new Core account pays account activation (1 USDC, or its value in
  HYPE taken from the transfer).
- Units: order `sz`/`limitPx` × 1e8; spot balances in token wei (HYPE 8, USDC 8); EVM HYPE 18,
  EVM USDC 6.

## Open
- Filling the float the first time: a sale, or a direct Core send to the pool's address (counts
  as a donation to LPs).
- Whether a keeper can be made permissionless (bounded by the 0x808 price and per-call caps).
