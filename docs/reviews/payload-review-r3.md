You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. This is round 3.

Since your round 2 (docs/reviews/r2.md, review-r2.out.md), two things changed in src/HedgedPool.sol:
(a) the design changed: the pool keeps a USDC float on its own Core account and USDC only ever moves Core -> EVM. Buys on Core spend the float; sales add to it; `sendBack(uToEvm)` (also callable from Idle) moves float to the EVM. Prices and LP shares use `reserveU() = rU + coreU()` (coreU read live from the 0x801 precompile); payouts come only from `rU` (`NotEnoughEvmUsdc`). The deposit-wallet leg is gone. Retries of `sendBack` happen only in a later block and resend only what a dropped send left above `floatAfter`. docs/design.md describes it.
(b) your round-2 finding 1 is fixed (IOC limits bounded by the pool price, directional tick rounding); finding 2 is handled by sendBack from Idle (see r2.md).

Review by breaking: for every finding write a Foundry test under test/poc/, run `forge test`, report numbers. Only add files under test/poc/.

Attack especially what the float introduces:
1. Pricing and shares off a live precompile read: donations of USDC to the pool's Core account (anyone can send to it on Core), sandwiching a donation with swaps/adds/removes, first-depositor with a pre-funded float, add/remove when most USDC is on Core, rounding of coreU (8 -> 6 decimals).
2. Whether coreU can be stale or wrong while Idle (e.g. a pending Core->EVM credit after finish, a late IOC, a send that Core rejects after expectations were fixed, HYPE gas for USDC sends running out), and whether finish can close while value is in transit.
3. The state machine with the float: buy leg earmarking (`inFlight` vs coreU at order time), sendBack from Idle (can the keeper or anyone use it to move value or freeze the pool), the `floatAfter` retry logic, `sentInBlock`.
4. Anything left from rounds 1-2 and HyperCore semantics (cite sources).

Read docs/step0-corewriter.md and docs/step1-bridging.md for measured testnet behaviour. Output: findings with severity, PoC and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
