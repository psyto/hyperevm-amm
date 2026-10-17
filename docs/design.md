# Pool design

A HYPE/USDC constant-product pool on HyperEVM that **arbitrages itself on HyperCore** instead of
leaving the gap to outside arbitrageurs.

## Why
In a plain x·y=k pool, every move of the outside price is closed by an arbitrageur, who keeps the
difference (loss-versus-rebalancing, LVR). On HyperEVM the pool can reach the deepest HYPE
market itself: HyperCore spot `@1035` on testnet (`@107` HYPE/USDC on mainnet) through CoreWriter.

## The rule: no books
The pool's reserves are its **actual balances, read every time**:

```
reserveH = EVM HYPE balance + Core HYPE (above the keeper's ops float)
reserveU = EVM USDC balance + Core USDC
```

Core balances come from the spot-balance precompile (0x801). Prices and LP shares use these sums;
payouts come only from the EVM side (`NotEnoughEvmHype` / `NotEnoughEvmUsdc`).

Why: the EVM gets no signal when a CoreWriter order fills or a transfer lands. Review rounds 1–5
(docs/reviews/) all found holes in versions that kept their own books (`rH`/`rU`, expected
arrivals, stages, timeouts) and tried to reconcile them with what Core did. With balances only:

| Event | Effect |
|---|---|
| an IOC fills seconds later, or never | value moves between two counted Core balances, or nothing changes |
| a Core → EVM send is rejected (e.g. a pending order spent the balance first) | the tokens stay on Core, counted |
| a transfer lands later than expected | counted the moment it lands |
| someone donates to the pool on the EVM or on Core | counted (a gift to LPs) |

## The one gap: tokens in transit
A transfer between the EVM and Core is in neither balance while it moves. Hyperliquid documents
the ordering ([interaction timings](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings)):
EVM → Core transfers are processed right after the EVM block that sent them; Core → EVM transfers
are queued until the next HyperEVM block. So every function that starts a transfer sets
`quietUntil = block.number + QUIET_BLOCKS` (2), and swaps, liquidity and the keeper's own steps
wait until it passes. This rests on documented block ordering, not on a time guess. If a credit
were ever later than that, reserves would be understated for a while (prices off for that time)
but nothing would be written off: it is counted when it lands.

## USDC only moves Core → EVM
USDC sent EVM → Core into a contract's Core account did not arrive on testnet
(docs/step1-bridging.md; reported as a testnet restriction). So HYPE is bought on Core with the
**USDC float** on the pool's Core account, sales add to it, and USDC goes to the EVM when payouts
need it.

## Functions
| Function | Who | What |
|---|---|---|
| `add`, `remove`, `swapHypeForUsdc`, `swapUsdcForHype` | anyone | x·y=k with a 30 bp fee on `reserveH` / `reserveU`; wait out `quietUntil` |
| `bridgeHype(amount)` | keeper | HYPE to the pool's Core account, to sell. Only when the pool is cheap, ≤ `maxRebalance`, ≥ 11 USDC, and only once the ops float is there (activation is the keeper's cost) |
| `order(sellHype, amount)` | keeper | one IOC on the Core spot market, spending what is on Core. Direction rechecked on live reserves; size ≤ `maxRebalance`; limit 1% off the Core price but never worse than the pool price (the order runs seconds later), rounded to the tick away from a loss |
| `toEvm(hypeWei, usdcWei)` | anyone | Core → EVM. Others must move ≥ 11 USDC worth and cannot take USDC below the keeper's `floatFloor` (kept for buys) |
| `fundOps()`, `setFloatFloor()` | keeper | ops float (Core HYPE for gas, not in reserves); the USDC floor |
| first `add` | keeper | anything already in the pool would otherwise go to whoever mints first |

`maxRebalance`: the amount that moves `reserveU / reserveH` to the Core price, never past it.
A sell: `dh = (p·h − u) / 2p`. A buy: `du = (u − p·h) / 2`.

## Facts this rests on (measured on testnet)
- CoreWriter writes run after the EVM block; IOC fills were visible ≤ 4 s later.
- Core → EVM credits do not call `receive()`; contracts only see a larger balance.
- The first transfer into a new Core account pays account activation (1 USDC, or its value in
  HYPE taken from the transfer).
- Core → EVM USDC arrived within 1 s and used Core HYPE for gas (hence the ops float).
- Units: order `sz`/`limitPx` × 1e8; spot balances in token wei (HYPE 8, USDC 8); EVM HYPE 18,
  EVM USDC 6; spot price `8 − szDecimals` decimals.

## Reviews
Codex, adversarial, with PoCs (docs/reviews/): r1 5 findings, r2 2, r3 2, r4 3, r5 4. After r5
the pool was rebuilt on balances only (above); r6 in progress.

## Open
- The pool has not run on testnet yet (needs ~1.5 testnet HYPE for an 11 USDC rebalance).
- Pausing: anyone moving ≥ 11 USDC of Core inventory to the EVM pauses swaps for 2 blocks;
  bounded by the inventory above the float floor.
- HYPE on Core below the ops float is not counted (gas eats the float; the keeper tops it up).
- Whether the keeper can be made permissionless (bounded by the 0x808 price and per-call caps).
- Whether USDC EVM → Core into a contract works on mainnet (reported yes; untested).
