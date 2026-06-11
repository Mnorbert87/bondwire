# Static analysis — Arc Agentic Stack (Phase 3)

**Scope:** CommitStakeV2, AgentBond, StreamPay. **Tools:** Slither 0.11.5 (crytic, via Foundry +
solc 0.8.24) and Aderyn 0.6.8 (Cyfrin). **Date:** 2026-06-11. Local + deterministic, no network,
no keys. Run from each Foundry project root (`slither . --exclude-dependencies`; `aderyn --src src`).

This is **own verification continuing the existing lineage** (gate-4 cold audit → HIGH fix), not a
fresh external audit. Triage discipline: every finding is classed **REAL** or **FALSE-POSITIVE**
with a concrete reason; a tool flag is not a vulnerability until a path is shown.

## Headline

**Zero new vulnerabilities.** Both tools, across all three contracts, surface only (a) reentrancy
flags that are structurally closed by the `nonReentrant` mutex on every state-mutating entrypoint,
(b) by-design timestamp comparisons (minute/hour-scale windows), and (c) the deliberate
balance-delta + no-return-token SafeERC20 pattern. The gate-4 HIGH (uncapped `arbiterFee`) is
already fixed and is **not** re-surfaced. No tool found a solvency, double-pay, or surplus-burn
bypass.

## CommitStakeV2 — Slither (25 results) + Aderyn (1 High, 6 Low)

| Detector (tool) | Sev | Count | Verdict | Reason |
|---|---|---|---|---|
| `reentrancy-balance` (Slither) | High | 3 | **FP** | All in `create`/`challenge`, both `nonReentrant` (mutex, src:81-86). External calls are to the Arc **USDC** gas-token (chain-native, non-reentrant) and the audited AgentBond/StreamPay. The `balanceOf` before/after reads are the fee-on-transfer-safe **balance-delta** accounting, inside the guard. No reentry path exists. |
| `reentrancy-no-eth` (Slither) | Med | 7 | **FP** | Same mutex + trusted-callee argument. The contract holds no ETH (USDC-native chain); the detector's ETH-free reentry shape is closed by `nonReentrant`. |
| `incorrect-equality` (Slither) | Med | 3 | **FP / benign** | Two are `data.length == 0` inside `_safeTransfer`/`_safeApprove` — the canonical OZ SafeERC20 no-return-token check (a *length* test, not a balance/oracle strict-equality). One is `amount == 0` to skip an empty challenge-bond leg. None is the dangerous strict-balance equality the detector targets. |
| `reentrancy-benign` (Slither) | Low | 3 | **FP** | Detector's own "benign" class (writes that don't affect the external call's effect) + the mutex. |
| `timestamp` (Slither) | Low | 6 | **By-design** | The deadline / challengeWindow / arbiterDeadline mechanism runs at **≥180s** (demo) to hours (prod). A validator's few-second timestamp leeway cannot move an outcome across a window this wide. Documented design tradeoff (VERIFIER_ECONOMICS §7 timing-gate). |
| `low-level-calls` (Slither) | Info | 3 | **Intentional** | `_safeTransfer/_safeTransferFrom/_safeApprove` are the SafeERC20-style wrappers (`require(ok && (data.length==0 || abi.decode(data,(bool))))`) — exactly to tolerate Arc-USDC / no-return tokens. |
| `H-1 Reentrancy: state change after external call` (Aderyn) | High | 8 | **FP** | Same as `reentrancy-balance`: all 8 instances are inside `create` (`nonReentrant`); the "external call" is the USDC `balanceOf`/`transferFrom` and `streamPay.createStream`. CEI is not line-ordered (balance-delta needs the post-call read) but reentrancy is prevented by the mutex. |
| `L-4 Unsafe ERC20 Operation` / `L-3 Unchecked Return` (Aderyn) | Low | — | **FP** | The flagged ops ARE the checked safe-wrappers; return data is validated. Aderyn flags the raw `.call` shape, not the (present) check. |
| `L-5 Unspecific pragma` (`^0.8.24`) | Low | — | **Accept** | Reusable primitive keeps the caret; the deployed artifact pinned exactly `0.8.24` (foundry.toml + verified Blockscout metadata). Could tighten to `=0.8.24`; not a security issue. |
| `L-2 PUSH0` | Low | — | **Non-issue on Arc** | Arc EVM is Cancun (verified compiler settings: `evmVersion: cancun`) — PUSH0 is supported. |
| `L-1 Large literal` / `L-6 public-not-used-internally` | Low | — | **Style** | BPS constants / `0x…dEaD`; view getters. No impact. |

## AgentBond — Slither (5 results) + Aderyn (1 High, 3 Low)

Same shape: the single Aderyn H-1 reentrancy is `deposit`/`lock`/`slash` doing balance-delta
around a trusted-USDC transfer under AgentBond's own `nonReentrant`; Slither's flags are the same
reentrancy/low-level/timestamp classes. **All FP / by-design** — AgentBond is the already-audited
Phase-1 primitive (reused, not redeployed). No new finding.

## StreamPay — Slither (13 results) + Aderyn (1 High, 4 Low)

Same triage: reentrancy flags under `nonReentrant`, balance-delta accounting, `withdrawn ==
deposit` strict-equality (the terminal-state transition — exact by construction, not an oracle
compare), timestamp accrual (StreamPay accrues by wall-clock **by design** — documented honest
caveat). **All FP / by-design.** StreamPay is the audited Phase-1 primitive.

## Net

No static finding requires a code change. The reentrancy class — the only "High" either tool
raises — is uniformly closed by the per-entrypoint `nonReentrant` mutex plus the trusted-token
callee set (Arc USDC + the stack's own audited contracts). The balance-delta + SafeERC20-wrapper
patterns the tools dislike are precisely the fee-on-transfer / no-return-token hardening the
adversarial suite proves. Symbolic verification (HALMOS_VERIFICATION.md) targets the solvency,
surplus-positivity and no-double-pay invariants directly, as the positive complement to this
negative (find-a-bug) pass.

## Optional CI

A `.github/workflows/static-analysis.yml` (Slither + Aderyn on push) is worth adding, **but** the
local `gh` token has **no `workflow` scope** — pushing `.github/workflows/**` is rejected. If added,
it must go in a **separate commit** Főnök pushes after `gh auth refresh -s workflow`; do not let the
rest of the work fail on it. (See memory `reference_gh_token_no_workflow_scope`.)

## Annotations landed in source (2026-06-11)

Every by-design item above now carries an inline `// slither-disable-next-line <detector>` directive
in `src/CommitStakeV2.sol`, each with a one-line reason pointing back to this grid — so the source
and this `.md` tell one truth, and a future reviewer sees *why* a finding is absent from the code
itself. Verified: with the directives, `slither . --exclude-dependencies --fail-pedantic` reports
**0 results / exit 0**. The signal is genuine, not always-green — removing any single directive makes
the corresponding finding re-surface and the run exit non-zero (demonstrated by temporarily dropping
the `resolve` timestamp directive → `1 result`, exit 255). The CI must therefore run Slither
**with** these in-source directives and `--fail-pedantic`, so the pipeline goes red only on a *new,
un-accepted* finding. The directive detector names: `reentrancy-balance`, `reentrancy-benign`,
`reentrancy-no-eth`, `timestamp`, `incorrect-equality`, `low-level-calls`.
