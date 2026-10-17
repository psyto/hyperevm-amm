## Finding

1. **Medium — invalid/wide Core books freeze permissionless HYPE recovery.**  
   [PoC](test/poc/R8FixPoc.t.sol:157) passes: with Core HYPE backing an LP withdrawal, a 40/44 book causes `toEvm(HYPE)` to revert `WideBook(953)`, leaving the LP unable to bring liquidity to EVM. `bridgeHype` is likewise blocked; keeper HYPE exits and public USDC-only exits still work.

   Root cause: `toEvm` invokes full `coreBbo()` validation although its anti-grief calculation needs only a conservative nonzero bid. The pool’s stated permissionless recovery path becomes dependent on the ask and spread.

   Fix: use a dedicated HYPE-exit valuation that requires only a nonzero bid. Keep full two-sided/spread validation for rebalance decisions. This retains the Round 7 zero-bid protection while allowing HYPE recovery during a wide or one-sided ask book.

## Round 7 fix checks

- Pricing fix holds: `executable` floors the sell net and ceils the buy gross; equality at the net bid does not authorize a sell, and the near-boundary gross ask does not authorize a buy. [PoC](test/poc/R8FixPoc.t.sol:93) passes.
- A fill at a better price only improves the result versus the conservative executable price.
- The current official spot schedule tops out at a 7 bp taker fee; tiers and staking discounts reduce it, so the 10 bp constant has current headroom. [Hyperliquid fees](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees)
- Zero, crossed, and wide books are cleanly rejected. `add`, `remove`, and swaps do not directly read the quote; confirmed in [PoC](test/poc/R8FixPoc.t.sol:142). The practical LP issue is when `remove` needs Core HYPE transferred first.

Added only [R8FixPoc.t.sol](test/poc/R8FixPoc.t.sol:1). `forge test`: **37 passed, 0 failed**.

VERDICT: CHANGES