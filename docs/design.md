# Pool design (draft)

A HYPE/USDC constant-product pool on HyperEVM that **arbitrages itself on HyperCore** instead of
leaving the gap to outside arbitrageurs.

## Why
In a plain x·y=k pool, every move of the outside price is closed by an arbitrageur, who keeps the
difference (loss-versus-rebalancing, LVR). On HyperEVM the pool can reach the deepest HYPE
market itself: HyperCore spot `@1035` on testnet (`@107` HYPE/USDC on mainnet) through CoreWriter.

## State
- EVM reserves `rH` (HYPE, 18 decimals, native) and `rU` (USDC ERC20, 6 decimals).
- LP shares, proportional mint/burn.
- A rebalance state: `Idle → OnCore → Ordered → Returning → Idle`.

## Swaps
x·y=k with a fee, `minOut`, against `rH`/`rU`. Swaps, adds and removes are **paused while a
rebalance is in flight**: the reserves are then partly on Core and the pool cannot price them
until they come back. v1 accepts the pause (tens of seconds); v2 can price the in-flight leg
conservatively instead.

## Rebalance (keeper, v1 owner-only)
1. **start(sellHype, amount)** — bridge `amount` of the over-weight token to the pool's Core
   account. HYPE: transfer to `0x2222…`. USDC: `CoreDepositWallet.deposit(amount, spot)`.
   Record `inFlight`.
2. **order(limitPx)** — once the Core spot balance shows the amount, send one IOC on the spot
   market. `limitPx` is bounded against the Core spot price (0x808) read in the same call.
3. **return()** — after the order delay, read both Core spot balances and send them back to the
   EVM through each token's system address (action 13). Keep a small HYPE balance on Core: a
   non-HYPE send from Core needs HYPE for its gas.
4. **finish()** — when the EVM balances have grown by what Core showed, set `rH`/`rU` to the
   actual balances and unpause.

How far to rebalance: only toward the Core price, never past it — the amount that moves
`rU/rH` to the Core mid, less fees, capped per call.

## Facts this rests on (measured on testnet, docs/step0-corewriter.md)
- CoreWriter writes run after the EVM block; IOC fills were visible ≤ 4 s later.
- Core → EVM credits do **not** call `receive()`; the contract only sees a larger balance.
  So `finish()` must compare balances, not wait for a callback.
- The first transfer into a new Core account pays account activation (1 USDC, or its value in
  HYPE taken from the transfer).
- Units: order `sz`/`limitPx` × 1e8; spot balances in token wei (HYPE 8, USDC 8); EVM HYPE 18,
  EVM USDC 6.

## Open
- USDC EVM → Core through the deposit wallet: see the bridging run.
- Whether a keeper can be made permissionless (bounded by the 0x808 price and per-call caps).
