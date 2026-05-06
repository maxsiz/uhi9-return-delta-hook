# Uniswap V4 Hook Workshop: Auto-Compounding Variants

A Foundry scaffold exploring three **custom-accounting styles** for auto-compounding LP positions in Uniswap V4 hooks.

## Quick Start

```bash
forge build                         # Compile
forge test -vvv                     # Run tests with traces
forge test --match-test test_1      # Run specific test
forge fmt                           # Format code
```

## Hook Variants

Each variant uses the same **SelfLPLib** for shared math (range snapping, fee preview, rebalancing), but explores different custom-accounting approaches:

| Variant | Style | Status | Docs |
|---------|-------|--------|------|
| **SelfLPDirect** | Direct `modifyLiquidity` + flash accounting | ✅ Done | [docs/SelfLPDirect.md](docs/SelfLPDirect.md) |
| **SelfLPAfterDelta** | Return-delta hooks on add/remove liquidity | 🔨 WIP | docs/SelfLPAfterDelta.md |
| **SelfLPBeforeInternalize** | Pre-bake reinvest into swap via beforeSwapReturnDelta | 🔨 WIP | docs/SelfLPBeforeInternalize.md |

---

## SelfLPDirect (Baseline)

**Direct custom-accounting** — most straightforward approach.

- Position owned via `modifyLiquidity`, no PositionManager
- Fee preview view-side only (no SSTORE)
- Flash accounting: burn + mint deltas netted before settlement
- Gas-efficient: only physical token movement for residual amounts

**Key insight:** Burning and minting in the same callback allows delta netting, reducing token movements from 4 to 2.

→ [Full documentation & diagrams](docs/SelfLPDirect.md)

---

## Project Structure

```
src/
  ├── SelfLPDirect.sol              # Baseline hook
  └── lib/
      └── SelfLPLib.sol             # Shared helpers: range, fees, rebalancing

test/
  ├── SelfLPDirect.t.sol            # Tests with console2 logging
  └── hlpEnvelopTest.sol            # Formatting helpers

docs/
  ├── SelfLPDirect.md               # Baseline variant with diagrams
  ├── SelfLPAfterDelta.md           # (forthcoming)
  └── SelfLPBeforeInternalize.md    # (forthcoming)

CLAUDE.md                           # Developer guidance
```

---

## Testing

```bash
# Run all tests
forge test -vvv

# Run specific test
forge test --match-test seedPosition_initialState -vvv

# Gas snapshots
forge snapshot
```

**Tests include console2 logging** showing:
- Asset movements (ETH, token1 balances)
- Position ranges and liquidity
- Reinvest cycle details
- Accounting verification

---

## Architecture Decisions

### Why Three Variants?

Each variant demonstrates a different pattern for using Uniswap V4's custom-accounting system:

1. **SelfLPDirect** — Lower-level control, explicit delta management
2. **SelfLPAfterDelta** — Hook-authored return deltas for cleaner control flow
3. **SelfLPBeforeInternalize** — Pre-computation for maximum gas efficiency

All three show how to auto-compound without an NFT-based PositionManager.

### Why Flash Accounting?

Burning and minting a position inside the same callback unlock allows us to:
- Compute burn proceeds (credits)
- Compute mint requirements (debits)
- Net the two before final settlement

This reduces physical token movements by **~50%** compared to naive separate burns/mints.

---

## Shared Utilities

### SelfLPLib

All variants use these helpers:

- **`computeRange(tick, halfWidth, spacing)`** — Snap a symmetric range around current tick
- **`previewFeesETH(params)`** — View-side fee estimate in ETH terms (no SSTORE)
- **`computeReinvestSwap(sqrtPrice, range, balances)`** — Optional rebalancing (for future variants)

---

## Prerequisites

- Foundry: https://book.getfoundry.sh/getting-started/installation
- Submodules: `git submodule update --init --recursive`

---

## References

- **Uniswap V4:** https://github.com/uniswap/v4-core
- **Hooks:** https://github.com/uniswap/v4-hooks-public
- **V4 Core Docs:** https://docs.uniswap.org/contracts/v4/overview

---

## License

MIT
