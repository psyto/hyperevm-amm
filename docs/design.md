# Pool design

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
- **HYPE on Core counts too** (review r3): `reserveH() = rH + coreH()`, Core HYPE above the
  keeper's ops float. A CoreWriter order can fill at any time after `order()`, with no
  settlement signal on the EVM; with both Core balances counted, a late fill only moves value
  between them. HYPE is paid out only from `rH` (`NotEnoughEvmHype`).
- The first mint is the keeper's: a float already on Core would otherwise go to whoever mints first.
- LP shares, proportional mint/burn. A rebalance state: `Idle → OnCore → Ordered → Returning → Idle`.

## Why a float
USDC sent EVM → Core into a contract's Core account did not arrive on testnet
(docs/step1-bridging.md; reported as a testnet-only restriction). Core → EVM works. So USDC only
ever moves Core → EVM: sales on Core fill the float, buys on Core spend it, and the keeper moves
float to the EVM when it is needed there.

## Swaps
x·y=k with a fee on `reserveH()` / `reserveU()`, `minOut`. Swaps, adds and removes are paused while a
rebalance is in flight.

## Invariants
1. What leaves the EVM reserves or the float for the other side stays owed until it is seen there
   (review r1). `sendBack` fixes `expectH`/`expectU` once; retries (in a later block) resend only
   what a dropped send left on Core (`floatAfter`) and never lower them. After `SETTLE_DELAY`,
   `finish` closes at the actual balances: a send Core rejected left its tokens on Core, counted.
2. Never send from Core a balance a pending order can still lower (review r4). For `SPEND_LOCK`
   after an order, the token it spends stays on Core; the token it receives only grows, so its
   read is a safe lower bound. The EVM gets no settlement signal for CoreWriter orders, so this
   rests on timing: 1 hour against fills measured within 4 s.
3. Everything on the pool's Core account counts (review r3); only the EVM side pays out.

Other rules: Ways out of every stage: `order` reverts if
the price has turned (then `sendBack` returns the HYPE untraded); `sendBack` from `OnCore` once
the HYPE has arrived, or after `STUCK_DELAY`. Rebalances under 11 USDC are refused. The Core HYPE
float is keeper-funded (`fundOps`), and `start` requires it (review r4: otherwise activation is
paid from LP HYPE). `sendBack` from `Idle` and `finish` are open to anyone, so Core inventory
(including donations) can always be brought to the EVM for payouts.

## Rebalance (keeper, v1 owner-only)
1. **start(sellHype, amount)** — sell: bridge HYPE to `0x2222…`. Buy: earmark `amount` of the float
   (must be ≤ `coreU()`); nothing moves. Both bounded by `maxRebalance` and `MIN_NOTIONAL`.
2. **order()** — recheck the direction on current reserves (counting bridged HYPE not yet on
   Core), then one IOC on the Core spot market. Limit: 1% off the Core spot price (0x808), but
   never worse than the pool's own price (review r2: the order runs seconds later), rounded to
   the tick away from a loss (sell up, buy down).
3. **sendBack(uToEvm)** — after the order delay: the token the order received back to the EVM
   (HYPE above the ops float, or up to `uToEvm` of the USDC float); the token it spent stays on
   Core for `SPEND_LOCK`. Also callable from `Idle`, by anyone.
4. **finish()** — when the EVM balances reach what was sent (or after `SETTLE_DELAY`), set
   `rH`/`rU` to them and unpause. Anyone can call it.

How far to rebalance: only toward the Core price, never past it — the amount that moves
`reserveU/reserveH` to the Core mid, capped per call.

## Facts this rests on (measured on testnet, docs/step0-corewriter.md, docs/step1-bridging.md)
- CoreWriter writes run after the EVM block; IOC fills were visible ≤ 4 s later. There is no
  settlement signal on the EVM, hence counting both Core balances.
- Core → EVM credits do **not** call `receive()`; the contract only sees a larger balance.
  So `finish()` must compare balances, not wait for a callback.
- The first transfer into a new Core account pays account activation (1 USDC, or its value in
  HYPE taken from the transfer).
- USDC EVM → Core into a contract's Core account did not arrive; Core → EVM arrived within 1 s.
  A non-HYPE Core → EVM send uses Core HYPE for gas, hence the keeper-funded ops float.
- Units: order `sz`/`limitPx` × 1e8; spot balances in token wei (HYPE 8, USDC 8); EVM HYPE 18,
  EVM USDC 6.

## Reviews
Codex, adversarial, with PoCs (docs/reviews/): r1 5 findings, r2 2, r3 2, r4 3, all fixed with
regression tests (`test_r1_*` … `test_r4_*`). r5 in progress.

## Open
- The pool has not run on testnet yet (needs ~1.5 testnet HYPE for an 11 USDC rebalance).
- Filling the float the first time: a sale, or a direct Core send to the pool's address before
  the keeper's first mint.
- HYPE on Core below the ops float is not counted (gas eats the float; the keeper tops it up).
- Whether a keeper can be made permissionless (bounded by the 0x808 price and per-call caps).
- Whether USDC EVM → Core into a contract works on mainnet (reported yes; untested).
