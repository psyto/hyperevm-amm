You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. This is round 4.

Your round 3 (docs/reviews/r3.md, review-r3.out.md) found 2 issues. Claude's fixes in src/HedgedPool.sol: (1) Core HYPE above the keeper's ops float now counts in the reserves (`reserveH() = rH + coreH()`, read live from 0x801) alongside the USDC float, so a late IOC fill only moves value between two counted Core balances; HYPE is paid out only from `rH`. In `order()` the sell leg also counts bridged HYPE not yet on Core (`inFlight - arrived`). (2) Only the keeper may mint first. docs/design.md describes the whole design.

Review by breaking: for every finding write a Foundry test under test/poc/, run `forge test`, report numbers. Only add files under test/poc/.

1. Do the fixes hold? Variants: late fills on either leg, partial fills, a fill between start/order/sendBack/finish, a bridge that lands after give-up, the ops float below KEEP_HYPE_WEI (coreH then 0 while HYPE sits on Core), activation fees, `arrived()` against `coreBefore` when Core already held HYPE.
2. What counting Core HYPE live opens: donations of HYPE to the pool's Core account, sandwiching such a donation, the gap between rH and reserveH for swaps and removes (NotEnoughEvmHype as a freeze), double counting during OnCore/Ordered/Returning (sendBack moves HYPE out of coreH before EVM credit: is it ever both in expectH and in coreH, or in neither, at a point where prices are used?).
3. Anything left from rounds 1-3 and HyperCore semantics (cite sources).

Read docs/step0-corewriter.md and docs/step1-bridging.md for measured testnet behaviour. Output: findings with severity, PoC and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
