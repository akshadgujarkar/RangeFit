# AGENTS.md — RangeFit

## Project
RangeFit: Uniswap v4 hook + vault that re-ranges concentrated liquidity WITHOUT swapping,
by solving for the range that fits current inventory. Full spec: docs/PROJECT.md (source of truth).

## Stack
Solidity (Foundry, v4-core, v4-periphery), TypeScript keeper (viem), React+Vite+wagmi frontend, Python simulation.

## Rules
- Read docs/PROJECT.md sections relevant to the task before planning. Do not invent features outside the MUST/SHOULD list.
- Work on ONE milestone per conversation. Produce an implementation plan first; wait for approval.
- All on-chain math uses FullMath and Q96 fixed point. No floating point in Solidity. Test with real token decimals.
- Every public/external contract function needs a NatSpec comment and at least one test.
- Run `forge build && forge test` after every change; report failures honestly, never delete or weaken a failing test to pass.
- Never touch .env, never print or hardcode private keys, never run `forge script --broadcast` without explicit approval.
- Do not run destructive shell commands (rm -rf, git reset --hard, force-push) without asking.
- API names for Uniswap v4 change between versions: check the installed lib source in lib/ before using a function, do not rely on memory.
- If the spec and the code disagree, stop and ask; do not silently change the math.
- Keep dust, fee and settlement logic simple and auditable; prefer boring code.
- Always generate any required docs (.md files) and store them in the `docs/` folder ONLY (which is git-ignored).
