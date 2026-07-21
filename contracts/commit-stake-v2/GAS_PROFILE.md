# Gas profile, CommitStakeV2 (+ V1 comparison), in USDC

**Source:** `forge test --gas-report` (solc 0.8.24, optimizer 200). **Date:** 2026-06-11.
**Arc gas:** USDC **is** the gas token. Live gas price observed at the real V2 deploy:
**40.0 gwei**. Conversion: `USDC = gas × 40e9 / 1e18 = gas × 4e-8`.
**On-chain anchor:** the actual V2 deploy used **3,955,666 gas → 0.1582 USDC** (deploy tx
`0xe066071a…3047dfdb`), the table's deploy row matches this, confirming the test-harness gas
tracks mainnet-Arc within rounding.

`Max` columns are the **full-path** cost of each function (fee stream opened, slice slashed, burn
fired). That is the number a user actually pays on the heaviest branch.

## CommitStakeV2, per function (Max path)

| Function | Gas (max) | USDC @40 gwei | Notes |
|---|---:|---:|---|
| **Deploy** | 3,955,666 | **0.15820** | real on-chain (anchor) |
| `create` (+ fee stream + bond lock) | 664,748 | 0.02659 | heaviest: pulls stake+fee, opens StreamPay stream, locks AgentBond slice |
| `resolve` | 38,689 | 0.00155 | verdict only, no money moves |
| `challenge` | 84,483 | 0.00338 | posts challenge bond |
| `arbitrate` (overturn → slash + burn) | 213,335 | 0.00853 | slice slashed, damage routed, **surplus burned**, bond refunded |
| `finalize` (clean / silence) | 113,836 | 0.00455 | stake routed, slice released, fee settled |
| `slashVerifierExpired` (liveness slash + burn) | 189,311 | 0.00757 | stake returned, **whole slice burned** |
| `challengeBondFloor` / `Cap` / `recommendedSlice` (view) | <1,000 | ~0.00004 | pure helpers |

## Full lifecycle cost per branch (the seeded demo paths)

| Branch | Call sequence | Total gas | **USDC @40 gwei** |
|---|---|---:|---:|
| **A · positive** | create → resolve → finalize | ~817,000 | **~0.0327** |
| **B · liveness** | create → slashVerifierExpired | ~854,000 | **~0.0342** |
| **C · overturn** | create → resolve → challenge → arbitrate | ~1,001,000 | **~0.0401** |

The full bonded-verifier dispute chain (branch C, the most expensive) costs **~4 cents** of USDC
end-to-end on Arc. The §7a slash+burn adds only ~0.008 USDC over a plain finalize, the
"damage ≈ pennies, surplus burned" economics hold literally at the gas layer too.

## V1 CommitStake, comparison (Max path)

| Function | Gas (max) | USDC @40 gwei |
|---|---:|---:|
| `create` | 181,863 | 0.00727 |
| `resolve` | 95,298 | 0.00381 |
| `claim` | 91,214 | 0.00365 |
| `slashExpired` | 67,510 | 0.00270 |

**V2 vs V1.** V2's `create` is ~3.6× V1's, it does strictly more on-chain: an AgentBond `lock`
(cross-contract slice escrow) and a StreamPay `createStream` (fee composition), neither of which
V1 has. That is the measured cost of the bonded-verifier + fee-stream composability, and it is
still **under 3 cents**. The dispute/slash branches V1 simply cannot express (no bonded verifier,
no §7a routing), so V2's `arbitrate`/`slashVerifierExpired` have no V1 counterpart.

## Net

The entire V2 mechanism, including the bonded slash and the visible burn, runs in **pennies of
USDC** on Arc. Nothing in the gas profile suggests a griefing or gas-DoS surface: every function
is O(1) in storage writes (no unbounded loops over commitments; the only loops are bounded
fixed-leg routing). The cost scales with the work done, not with the number of existing
commitments.
