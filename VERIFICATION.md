# Verification, pinned to a commit

One page, one table: which instrument ran, **on which commit**, when, and what it printed.

Commit under test: **`faef4697c12a2181fcdff3a0883a128bc6259a33`** (`faef469`, 2026-08-10) — the
same source the live `CommitStakeV2` at
[`0x548532aa4B59598188D49b3e74Fdf27aaE127bb6`](https://testnet.arcscan.app/address/0x548532aa4B59598188D49b3e74Fdf27aaE127bb6)
was built from. The bytecode identity is re-measured below, not assumed.

All runs: local, deterministic, **no network, no keys, no transaction.** macOS 25.5, 2026-09-30.

## Why this page exists

The repo already carried a four-layer audit trail, but each layer was dated to a different commit.
The 2026-08-10 deploy moved the source, and after it only the Foundry suite was re-run. Nothing was
broken by that — but nothing in the repo demonstrated it either, so a reader had to take the
symbolic and static layers on trust from documents anchored to an earlier commit. This page removes
the trust step for the instruments that need no network.

## The tree these runs used

```
git rev-parse HEAD                      -> faef4697c12a2181fcdff3a0883a128bc6259a33
git diff --name-only HEAD -- '*.sol'    -> (empty)
git submodule status                    -> forge-std 620536fa (v1.16.1), all four projects
```

Every Solidity file in the tree was identical to `faef469` when the runs below executed. A handful
of non-Solidity files (SDK prose, workflow comment text, the Slither triage database) were under
repair at the time; none of them is an input to a Solidity compile, a Foundry run, or Halmos, so
none of them can move a number on this page.

## The table

| Instrument | Version | Ran on commit | Run at (UTC) | Result |
|---|---|---|---|---|
| `forge test` — commit-stake-v2 | forge 1.7.1, solc 0.8.24 (cancun) | `faef469` | 2026-09-30 21:03 | **130 passed, 0 failed**, 10 suites, 46.2 s |
| `forge test` — agent-bond | forge 1.7.1, solc 0.8.24 | `faef469` | 2026-09-30 21:04 | **51 passed, 0 failed**, 8 suites, 85.8 s |
| `forge test` — commit-stake (v1) | forge 1.7.1, solc 0.8.24 | `faef469` | 2026-09-30 21:06 | **28 passed, 0 failed**, 7 suites, 54.7 s |
| `forge test` — stream-pay | forge 1.7.1, solc 0.8.24 | `faef469` | 2026-09-30 21:06 | **25 passed, 0 failed**, 5 suites, 45.1 s |
| Invariants (inside the above) | — | `faef469` | 2026-09-30 21:03–21:07 | **16 invariants**, 10 000 runs × 150 000 calls each, **0 reverts** |
| `halmos` symbolic proofs | halmos 0.3.3 | `faef469` | 2026-09-30 21:08 | **5 passed, 0 failed**, 7.75 s, `bounds: []` on all five |
| `forge lint` (all four projects) | forge 1.7.1 | `faef469` | 2026-09-30 21:08 | exit 0; warnings only, **0 in any `src/`** except by-design `block.timestamp` |
| Deployed-bytecode identity | solc 0.8.24 + `broadcast/run-latest.json` | `faef469` | 2026-09-30 21:09 | **prefix match `True`**, remainder = exactly the 3 constructor args |
| `slither --fail-pedantic` | slither 0.11.5 | `faef469` | 2026-09-30 21:18 UTC | **exit 0, 0 results** after the triage database was regenerated on this commit (see below) |

Aggregate on `faef469`: **234 tests, 16 invariants, 5 symbolic proofs, 0 failures.**

### Reproducing it

```bash
# 234 tests + 16 invariants
for p in commit-stake-v2 agent-bond commit-stake stream-pay; do
  (cd contracts/$p && forge test)
done

# 5 symbolic proofs
(cd contracts/commit-stake-v2 && halmos --function check_ --solver-timeout-assertion 0)

# lint
for p in commit-stake-v2 agent-bond commit-stake stream-pay; do
  (cd contracts/$p && forge lint)
done
```

## Test detail

The v1 contracts have not moved in months; the column says when each `src/` last changed, so a
reader can see how much drift each verification run had to cover.

| Project | `src/` last moved | Suites | Tests | Invariants | Runs × calls | Reverts |
|---|---|---|---|---|---|---|
| commit-stake-v2 | `3122e86`, 2026-08-10 | 10 | 130 | 5 | 10 000 × 150 000 | 0 |
| agent-bond | `1796160`, 2026-07-29 | 8 | 51 | 4 | 10 000 × 150 000 | 0 |
| commit-stake (v1) | `425e278`, 2026-06-11 | 7 | 28 | 4 | 10 000 × 150 000 | 0 |
| stream-pay | `425e278`, 2026-06-11 | 5 | 25 | 3 | 10 000 × 150 000 | 0 |

The sixteen invariants, by name:

- **commit-stake-v2** — `EscrowHoldsExactlyOpenObligations`, `FeeEscrowLegFullyBacked`,
  `LieAlwaysNetNegativeForVerifier`, `StateMachineExactlyOneTerminal`,
  `TerminalRoutingConservesValue`
- **agent-bond** — `bondEquation`, `lockedNeverExceedsBond`, `solvent_bookMatchesBalance`,
  `solvent_flowConservation`
- **commit-stake (v1)** — `solvent`, `solvent_byOwnBooks_feeToken`, `exactlyOnePayout`,
  `solvent_flowConservation`
- **stream-pay** — `perStreamConservation`, `solvent_flowConservation`, `withdrawNeverExceedsVested`

## Symbolic detail

`halmos --function check_ --solver-timeout-assertion 0`, run in `contracts/commit-stake-v2`,
2026-09-30 21:08 UTC, on `faef469`:

```
Running 5 tests for test/SymbolicSpec.t.sol:SymbolicSpec
[PASS] check_FeeResidue_NeverExceedsUnbooked(uint256,uint256,uint256,uint256)          (paths: 7,  time: 2.45s, bounds: [])
[PASS] check_StakeLeg_Solvency(uint256,uint256,uint256)                                (paths: 5,  time: 1.06s, bounds: [])
[PASS] check_StreamPay_SplitConserves(uint256,uint256,uint256)                         (paths: 5,  time: 0.11s, bounds: [])
[PASS] check_SurplusPositive_Liveness(uint256,uint256,uint256,uint256,uint256)         (paths: 7,  time: 0.40s, bounds: [])
[PASS] check_SurplusPositive_Overturn(uint256,uint256,uint256,uint256,uint256,uint256) (paths: 14, time: 3.68s, bounds: [])
Symbolic test result: 5 passed; 0 failed; time: 7.75s
```

`bounds: []` on all five means complete symbolic coverage, not a loop-bounded approximation.

**Relationship to [`contracts/commit-stake-v2/HALMOS_VERIFICATION.md`](./contracts/commit-stake-v2/HALMOS_VERIFICATION.md):**
that document is the standing write-up of the proofs and their assumptions, and its most recent
recorded run is dated 2026-08-09 against commit **`5fdb466`** — a commit **before** the 2026-08-10
deploy moved `CommitStakeV2.sol`. It has deliberately not been rewritten. The run above is the
re-run on the deployed commit, and it produces the **same five proofs with the same path counts
(7 / 5 / 5 / 7 / 14)**. Read `HALMOS_VERIFICATION.md` for what the proofs mean; read this page for
the fact that they still hold on `faef469`. Line numbers quoted in that document were anchored to
`5fdb466` and have drifted — trust the function names over the numbers.

## Lint detail

`forge lint` exits 0 in all four projects. Every warning, by file:

| Project | Warning | Count | Where |
|---|---|---|---|
| commit-stake-v2 | `block-timestamp` | 8 | `src/CommitStakeV2.sol` |
| commit-stake-v2 | `block-timestamp` | 9 | `test/CommitStakeV2Invariant.t.sol` |
| commit-stake-v2 | `unsafe-typecast` | 3 | `test/CommitStakeV2Adversarial.t.sol` |
| commit-stake-v2 | `unsafe-typecast` | 3 | `test/CommitStakeV2ColdAudit.t.sol` |
| agent-bond | `block-timestamp` | 1 + 1 | `src/AgentBond.sol`, `test/AgentBondInvariant.t.sol` |
| commit-stake | `block-timestamp` | 3 + 6 | `src/CommitStake.sol`, three test files |
| stream-pay | `block-timestamp` | 3 + 4 | `src/StreamPay.sol`, `test/StreamPayInvariant.t.sol` |

**All six `unsafe-typecast` warnings are in test files. Zero truncating casts in any `src/`.** The
`block-timestamp` warnings in `src/` are unavoidable in a deadline escrow: the windows are hours to
days, validator drift is seconds. They are the same class the static-analysis triage already
accepted as by-design.

## Deployed-bytecode identity

Re-measured here rather than cited, because it is the single strongest claim in the repo and it is
cheap to check. The CREATE transaction in
`contracts/commit-stake-v2/broadcast/Deploy.s.sol/5042002/run-latest.json` was compared against the
creation code that `solc 0.8.24` produces from this tree:

```
chain 5042002, broadcast timestamp 1786345642418  ->  2026-08-10 07:07:22 UTC
contract CommitStakeV2 @ 0x548532aa4b59598188d49b3e74fdf27aae127bb6

deployed init code : 31224 hex chars
local creation code: 31032 hex chars
PREFIX MATCH       : True
remainder          : 192 hex chars = exactly 3 ABI words, nothing else

  arg0 usdc      = 0x3600000000000000000000000000000000000000   (Arc USDC predeploy)
  arg1 agentBond = 0x4383ea48837ef7e60fc22bd67945bcbf0551702c
  arg2 streamPay = 0x6c2ae6f8ba7c0259eaba8ef4048c8bfc68bab262
```

This is local and deterministic: it does not rest on an explorer's "verified" badge. It proves the
init code that was broadcast is the code this source compiles to, with the three documented
constructor arguments and no trailing bytes.

Note the direction of the proof: it ties **the broadcast transaction** to **this source**. Tying it
to the *current on-chain state at this address* needs `eth_getCode`, which needs network — see
below.

## Static analysis

Run separately, not from this page: the gate and its triage database were re-triaged against
`faef469` in a parallel step, because running Slither here too would have put two writers on
`contracts/commit-stake-v2/slither.db.json`. Result of that run, 2026-09-30 21:18 UTC:
`slither . --exclude-dependencies --fail-pedantic` → **exit 0, 0 results**. Control: the same
command against the *previous* database returns **exit 255 with 25 results**, which is what the
gate had been doing since the source moved on 2026-08-10. See
[`contracts/commit-stake-v2/STATIC_ANALYSIS.md`](./contracts/commit-stake-v2/STATIC_ANALYSIS.md).

What is known and should be stated plainly: the previously accepted findings are a set of 25, in
six by-design detector classes (reentrancy guarded by the `nonReentrant` mutex, by-design timestamp
comparisons, and the deliberate balance-delta / no-return-token transfer pattern). The triage
database keys each finding by a content-derived id, so when the source moved on 2026-08-10 the
suppressions stopped matching and the gate went red — an id mismatch, not a new finding.

## What this page does NOT cover

Listed because a verification page that only lists its successes is not one.

**Needs network, therefore not measured here:**

- **Current on-chain state.** Whether the three addresses still hold code today, their balances,
  their transaction counts, and whether the live `AgentBond` returns the 7-field obligation tuple
  today. The bytecode section above proves what was *broadcast*, not what `eth_getCode` returns
  right now.
- **The published npm package.** Whether `bondwire-sdk` 0.4.0 is on the registry today.
- **GitHub Actions status.** The gating workflow's live run state. Only local instrument runs are
  on this page.
- **`bondwire.dev` and any hosted demo.** Not exercised.

**In scope but deliberately not re-run today:**

- **Static analysis** — separate re-triage, see above.
- **Mutation testing.** [`MUTATION_TESTING.md`](./contracts/commit-stake-v2/MUTATION_TESTING.md)
  records a re-run dated 2026-08-05 (commit `b5780d8`). `CommitStakeV2.sol` changed afterwards, at
  `3122e86` on 2026-08-10. **That layer is therefore still anchored to a pre-deploy source and is
  the one remaining gap in this table.** It is a local run and can be closed the same way.
- **Gas profile.** [`GAS_PROFILE.md`](./contracts/commit-stake-v2/GAS_PROFILE.md) is a cost
  measurement, not a correctness claim; it is not treated as a verification layer here.

**Out of scope entirely:**

- **A paid external audit.** None has been commissioned. Everything on this page is own
  verification with public tooling, reproducible by anyone who clones the repo.
- **Mainnet.** Every address, demo and SDK default in this repo is Arc testnet (chain 5042002).
  There is no mainnet deployment.
- **Usage or traction claims.** This page is about whether the code does what it says, not about
  who calls it.

## How to keep this page honest

It is pinned to a commit on purpose. If `src/` moves, every row above becomes a claim about an
older source, exactly like the documents this page was written to fix. The rule is the one the
2026-08-10 deploy broke: **when the source moves, re-run the instruments and re-pin this table in
the same change** — do not date it and hope.
