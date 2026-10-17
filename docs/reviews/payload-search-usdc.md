You are Codex. Claude (another model) ran the experiment below and could not explain it. Research it on the web; do not trust Claude's framing.

Question: On Hyperliquid testnet (HyperEVM chain 998), why does USDC sent through Circle's CoreDepositWallet NOT get credited on HyperCore when the Core recipient is a smart contract, while it is credited for an EOA?

Observed 2026-10-17 (testnet):
- USDC ERC20 0x2B3370eE501B4a559b57D449569354196457D8Ab, CoreDepositWallet 0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206.
- Contract <probe-2> (already had a Core account: it held HYPE on Core after bridging HYPE via 0x2222...). It called approve + deposit(4e6, 4294967295). Tx succeeded; the deposit wallet emitted Transfer(contract -> 0x2000000000000000000000000000000000000000, 4e6). Nothing credited on Core to anyone after 20+ minutes (spotClearinghouseState and userNonFundingLedgerUpdates of the contract show nothing).
- An EOA called depositFor(contract, 1.5e6, 4294967295): same Transfer(contract -> 0x2000..00) log, also never credited.
- Control: the same EOA called deposit(1e6, 4294967295): credited to the EOA within 1 s.
- The same contract CAN bridge HYPE both ways and CAN send USDC Core -> EVM (sendAsset to 0x2000..00 via CoreWriter), both immediate.

Find: documented or reported reasons (Hyperliquid docs, Circle CCTP / CoreDepositWallet docs, hyper-evm-lib issues, Discord/Github/forum posts, audits). Candidate explanations to confirm or reject: contracts must be "finalized"/linked for non-HYPE EVM->Core credits; Core credits only senders with no EVM code; deposits for contracts need a specific Core action; testnet-only bug; recovery path for stuck funds. Report sources with URLs, and say clearly what is confirmed vs your inference. Under 400 words.
