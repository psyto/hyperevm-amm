You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Review by breaking: for every finding, write a failing Foundry test under test/poc/ that demonstrates it, run `forge test`, and report the numbers. You may only add files under test/poc/; do not edit src/ or existing tests.

Repo (this worktree): a HYPE/USDC x*y=k pool on HyperEVM that closes its own gap to the HyperCore spot price by trading on HyperCore through CoreWriter (`src/HedgedPool.sol`, helpers `src/Core.sol`). Read docs/design.md, docs/step0-corewriter.md and docs/step1-bridging.md first: they record measured testnet behaviour (CoreWriter actions run after the EVM block; Core->EVM credits do not call receive(); first Core transfer pays ~1 USDC activation; USDC EVM->Core into a contract's Core account did NOT arrive on testnet). Tests in test/HedgedPool.t.sol simulate Core with vm.mockCall and a recording CoreWriter.

Attack, in order of value:
1. Loss of LP funds or share mispricing: add/remove/swap math, first-depositor/donation attacks (receive() accepts any HYPE; finish() sets reserves to raw balances), rounding, the in-flight accounting (rH/rU reduced in start, restored in finish), the Core-side HYPE dust (KEEP_HYPE_WEI) not counted.
2. The rebalance state machine: stuck states (an IOC that does not fill, a dropped sendAsset, the USDC leg that cannot reach Core), keeper griefing, sendBack callable twice from Returning (expectH/expectU recomputed), finish() satisfiable by donations, anything that lets the keeper or anyone extract value.
3. Unit/decimal errors: Core spot price decimals (8 - szDecimals), sz lot rounding, _toTick (5 significant figures, max 8 - szDecimals decimals), USDC 6 vs 8 decimals, HYPE 18 vs 8, maxRebalance formulas and their bound.
4. Anything about HyperCore semantics the code gets wrong (cite the source).

Output: a list of findings, each with severity (critical/high/medium/low), the PoC test name and its result, root cause, and a concrete fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
