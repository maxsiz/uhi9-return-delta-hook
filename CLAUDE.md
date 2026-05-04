# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A Foundry workshop scaffold for a Uniswap V4 hook (`src/InternalSwapPool.sol`) that explores the `beforeSwapReturnDelta` / `afterSwapReturnDelta` mechanism. The current source has the delta-returning logic *written but commented out* in `_beforeSwap` and `_afterSwap`; the hook compiles and runs as a near no-op. When making changes, the typical task is to selectively re-enable, modify, or replace those commented blocks — they are not dead code, they are the spec.

## Common commands

```bash
forge build                    # compile (CI runs `forge build --sizes`)
forge test -vvv                # run all tests with traces
forge test --match-test test_1 # run a single test
forge fmt                      # format (fmt-check is disabled in CI)
```

CI sets `FOUNDRY_PROFILE=ci`; locally the default profile is used. `ffi = true` is set in `foundry.toml`, so tests are allowed to shell out.

Submodules are required: after a fresh clone run `git submodule update --init --recursive`. Remappings (`remappings.txt`) resolve `@uniswap/v4-core/`, `v4-core/`, `v4-hooks-public/`, `forge-std/`, `solmate/`, etc. through the `lib/v4-hooks-public` submodule's nested deps — do not duplicate those libs at the top level.

## Architecture

### The hook contract

`InternalSwapPool` extends `BaseHook` from `v4-hooks-public` and declares permissions in `getHookPermissions()`:
- `beforeInitialize`, `beforeSwap`, `afterSwap`
- `beforeSwapReturnDelta`, `afterSwapReturnDelta`

Two pool-level invariants enforced in `_beforeInitialize`:
1. The pool **must** use the dynamic-fee flag (`key.fee == 0x800000`) → otherwise reverts `MustUseDynamicFee`.
2. One of the two currencies **must** be ETH (`address(0)`) → otherwise reverts `PoolShouldBeWithEth`.

Per-pool fee accounting lives in `_poolFees[poolId]` (`ClaimableFees { amount0, amount1 }`). The intent (currently commented) is:
- `_beforeSwap`: when `zeroForOne` and accumulated `amount1` fees exist, front-run the pool by selling internal token1 inventory for ETH at the current `sqrtPriceX96`. The resulting `BeforeSwapDelta` shifts amounts off the AMM, reducing slippage. `SwapMath.computeSwapStep` is used to price the partial fill, and `poolManager.sync` / `take` / `CurrencySettler.settle` move tokens.
- `_afterSwap`: skim a 1% fee on the unspecified-side amount, deposit it into `_poolFees`, and call `_distributeFees` which uses `poolManager.donate(...)` once `amount0 >= DONATE_THRESHOLD_MIN` (0.0001 ether).

When re-enabling either block, remember the sign convention for `BeforeSwapDelta` and `int128 hookDeltaUnspecified_`: positive = hook took/is-owed currency, negative = hook owes/sent currency. The currently-active selector returns are `beforeSwap.selector` and `afterSwap.selector` with zero deltas.

### Hook address encoding

V4 hooks must be deployed at an address whose low bits encode the enabled permissions. The test deploys via `deployCodeTo(...)` to a precomputed address built from `Hooks.BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG`. If you change `getHookPermissions()`, update the flag set at `test/InternalSwapPool.t.sol:57` to match — a mismatch makes `BaseHook`'s constructor revert.

### Test harness

`test/InternalSwapPool.t.sol` inherits `Deployers` (from `v4-core/test/utils`), which provides the standard fixtures: `manager`, `currency0/currency1`, `swapRouter`, `modifyLiquidityRouter`, `key`, `SQRT_PRICE_1_1`, `ZERO_BYTES`. The setup pattern is:
1. `deployFreshManagerAndRouters()` then `deployMintAndApprove2Currencies()`.
2. `deployCodeTo` the hook to the flag-encoded address.
3. `initPool(ethCurrency, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1)` — note ETH is `currency0`.
4. Seed liquidity via `modifyLiquidityRouter.modifyLiquidity{value: ...}` (ETH must be sent because currency0 is native).

`test/hlpEnvelopTest.sol` is a small mixin with `_formatEther` / `_padLeft` helpers used for human-readable `console2.log` output.

## Solidity / toolchain

- `solc 0.8.26`, `evm_version = cancun`, `optimizer_runs = 800`, `via_ir = false`.
- Lint disables `screaming-snake-case-immutable` and `screaming-snake-case-const`; `lint_on_build = false`.
- RPC endpoints and Etherscan keys in `foundry.toml` come from env vars (`ENVELOP_MAINNET`, `WEB3_INFURA_PROJECT_ID`, `WEB3_QUICKNODE_ID`, `ETHERSCAN_TOKEN`, etc.) — needed for `forge script` / verification, not for local tests.
