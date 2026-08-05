# Gas profile, CommitStakeV2 (+ V1 comparison), in USDC

**Source:** `forge test --gas-report` (solc 0.8.24, optimizer 200). **Date:** 2026-06-11.
**Arc gas:** USDC **is** the gas token. Live gas price observed at the real V2 deploy:
**40.0 gwei**. Conversion: `USDC = gas × 40e9 / 1e18 = gas × 4e-8`.
**On-chain anchor:** the **live** `CommitStakeV2` (`0xf3457ABf…af1474`, the redeploy of
2026-07-31) was created by [`0xd26d8942…9b6f973e`](https://testnet.arcscan.app/tx/0xd26d89427dd0d87171bd51afc9f793443a5cbeeddff9285f34771eae9b6f973e)
using **3,279,071 gas**. That transaction landed at an effective gas price of **23.6 gwei**, so it
actually cost **0.0774 USDC**; at the 40 gwei constant this table uses it would be 0.1312 USDC.
The 40 gwei figure is kept as the conservative conversion for every row below, so the table
overstates rather than flatters.

> Anchor corrected 2026-08-05. Until then this line pointed at `0xe066071a…3047dfdb`,
> **3,955,666 gas → 0.1582 USDC** — the creation transaction of the *pre-redeploy*
> `0x1f1CA31b…698CA9`. The number was real, it just described a contract that is no longer the
> deployed one. Measured, not inferred: `cast receipt` on both transactions.

`Max` columns are the **full-path** cost of each function (fee stream opened, slice slashed, burn
fired). That is the number a user actually pays on the heaviest branch.

## CommitStakeV2, per function (Max path)

| Function | Gas (max) | USDC @40 gwei | Notes |
|---|---:|---:|---|
| **Deploy** | 3,279,071 | **0.13116** | real on-chain (anchor), live deploy `0xd26d8942…9b6f973e`; it actually paid 0.0774 USDC at 23.6 gwei |
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
