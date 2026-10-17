You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. This is round 6.

After your round 5 (docs/reviews/r5.md), Claude did not patch: src/HedgedPool.sol was rewritten. It keeps no books. Reserves are actual balances read every time: native HYPE + USDC on the EVM, plus Core HYPE above the keeper's ops float + Core USDC (0x801). No stages, expected arrivals, locks or timeouts. Any function that starts an EVM<->Core transfer sets a QUIET_BLOCKS=2 pause on swaps/liquidity/keeper steps, relying on Hyperliquid's documented ordering (EVM->Core processed right after the sending EVM block; Core->EVM queued until the next HyperEVM block). The keeper bridges HYPE (`bridgeHype`) and places IOCs (`order`) spending what is on Core; anyone can move Core inventory to the EVM (`toEvm`, others >= 11 USDC worth and not below the keeper's USDC `floatFloor`). docs/design.md is the spec. Earlier rounds' PoCs are in docs/reviews/rN-poc.t.sol.txt (they target removed APIs).

Review by breaking: for every finding write a Foundry test under test/poc/, run `forge test`, report numbers. Only add files under test/poc/.

1. The no-books model: any way a balance read can be wrong at a point where prices or shares are computed (transit windows, the QUIET_BLOCKS bound, a transfer started in a block where a swap already ran, CoreWriter actions in the same block as a swap, ordering of precompile reads vs. Core processing).
2. Balance-based AMM attacks: donations on the EVM (receive, selfdestruct-style forced sends) and on Core, sandwiching around keeper orders or toEvm, first-mint and share inflation, msg.value handling in add/swap, rounding of coreU/coreH.
3. Keeper and anyone powers: can the keeper extract LP value through bridgeHype/order/toEvm/setFloatFloor/fundOps; can anyone grief (toEvm pausing, MIN_NOTIONAL), drain the float, or freeze payouts.
4. Anything from rounds 1-5 that the rewrite reintroduced, and HyperCore semantics (cite sources).

Output: findings with severity, PoC and result, root cause, fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
