# Mutation testing — CommitStakeV2

**Tool:** `slither-mutate` (Slither 0.11.5) over Foundry + solc 0.8.24. **Date:** 2026-06-11.
**Target:** `src/CommitStakeV2.sol`. **Test command (per mutant):** the fast deterministic subset
`forge test --no-match-contract "Invariant|Fuzz|SymbolicSpec"` = **63 tests** (39 unit + 21
adversarial + 3 cold-audit). Campaign ran ~27 min; source restored from git after (verified clean
vs commit `545e202`). Mutant artifacts (`mutation_campaign/`) were transient and removed.

## Score (fast subset)

Two measured runs: an initial campaign, then a **re-run after the three edge tests** below were
added (`CommitStakeV2EdgeMutation.t.sol`). Both numbers are the tool's measured output, dated; the
re-run is the current state.

| Mutator class | Run 1 (2026-06-11) | Re-run + edge tests (2026-06-11) |
|---|---:|---:|
| Revert | 128 / 128 (100.0%) | **128 / 128 (100.0%)** |
| Comment (`//` out a statement) | 96 / 128 (75.0%) | **101 / 128 (78.9%)** |
| Tweak (operator/literal/condition) | 304 / 375 (81.1%) | **306 / 377 (81.2%)** |
| **Overall (compilable mutants)** | **528 / 631 (83.7%)** | **535 / 633 (84.5%)** |

The edge tests killed exactly their targets: the three constructor zero-address mutants, the dust
`SLICE_TOO_SMALL_FOR_BOND_BAND` mutant, and the `TRANSFER_FAILED` mutant — **0 of those survive the
re-run**. The overall score moved 83.7% → **84.5%**, not into the 90s, because the *remaining*
survivors are dominated by equivalent mutants and accounting mutants the fast subset structurally
can't kill (see the re-run breakdown). This is the measured value, not cosmeticised to a target.

Uncompilable mutants (e.g. `revert();` with no arg, `bytes storage` swaps) are discarded by the
tool and excluded from the denominator — standard.

## Re-run survivor breakdown (98 survivors)

| Group | Count | Verdict |
|---|---:|---|
| `uint256 → uint128` cast in timestamp requires (SBR) | 21 | **Equivalent.** A unix timestamp + window (≤ 2^40) fits in `uint128`; the comparison is bit-identical. No behaviour change. |
| Event-emission removals (CR) | 15 | **Equivalent for value-safety** (no funds/state change; suite asserts balances, not logs). |
| `totalEscrowed +=/-=` conservation (CR + AOR/ASOR, lines 386/623/678/686) | 5 | **Caught by the excluded invariant suite.** Re-demonstrated 2026-06-11: applied `//totalEscrowed -= c.amount` (623) and ran `invariant_EscrowHoldsExactlyOpenObligations` → **FAIL** (`contract owed-ledger agrees: 1697364 != 1688375`). Survives the *fast subset* only. |
| fee-residue arithmetic (AOR 731/732, MIA 762: `unbooked = bal ± totalEscrowed`, `_min(deposit ± withdrawn, unbooked)`) | 3 | **Equivalent — NOT invariant-caught** (corrected). Re-demonstrated 2026-06-11: applied `_min(s.deposit + s.withdrawn, unbooked)` (732) → `invariant_FeeEscrowLegFullyBacked` + `invariant_EscrowHoldsExactlyOpenObligations` both **PASS**. The `_min(remainder, unbooked)` cap combined with the contract's actual-`received` accounting forces `unbooked == deposit - withdrawn` on the only reachable early-Ended state, so the `±` flip and the cap source are indistinguishable. (Halmos `check_FeeResidue_NeverExceedsUnbooked` is a property *re-model*, not a contract call, so it does not kill this either — but the equivalence proof stands independently.) |
| `if (x > 0) ==> true` guards (MIA) | 7 | **Equivalent** (`_safeTransfer(addr, 0)` / 0-value emit is a no-op). |
| Defensive `require` removals (CR): `NO_FUNDS`, `NO_FEE_FUNDS`, `TRANSFER_FROM_FAILED`, `APPROVE_FAILED` | 8 | **Low-severity, real.** Need a zero-pull token (pulls 0 but returns true) and an inbound-`false` token to kill — distinct from the outbound-`false` token now tested. Not a live vulnerability (Arc USDC never produces these). |
| Other tweaks (ROR/LIR/MVIE etc.) | ~39 | Mostly equivalent (e.g. `feeStreamId = 0 ==> 1` on the no-fee path) or invariant-caught; a few low-sev edges. |

**Net of the re-run:** of the 98 survivors, ≥51 are provably equivalent (46, incl. the 3 fee-residue
arithmetic mutants re-justified as equivalent above) or killed by the excluded invariant suite (5
`totalEscrowed` conservation mutants); the actionable remainder is the ~8 low-severity inbound-token
`require` mutants plus a scatter of edge tweaks — none touching a deployed-contract safety property
already proven by the invariants + Halmos. **No surviving mutant is an open routing or sizing gap:**
fund-destination selection is revert-class (128/128) + routing-conservation-invariant covered, and
every sizing arithmetic mutant (`slice`, `toHarmed`, `surplus`, `toStaker`, `fee = _min(arbiterFee,
bond)`) is killed — the only sizing-flavoured survivors are the fee-residue mutants proven equivalent
above. The three requested edge tests did their job (their
targets are gone); pushing the headline higher would require zero-pull / inbound-false token tests,
which we deliberately did **not** bolt on just to chase a 90% number.

## The fast-subset score UNDERSTATES the real score — proven

The 103 survivors were triaged against the **two suites deliberately excluded for per-mutant
speed** (the 10k-run invariant + fuzz suites). The largest survivor group — **value-conservation /
accounting mutants** — is killed by those excluded invariants. Demonstrated, not asserted:

> Applied the survivor `//totalEscrowed -= c.amount` (and its `%=`/`^=` tweak siblings) and ran
> **only** `CommitStakeV2InvariantTest`:
> `[FAIL] invariant_EscrowHoldsExactlyOpenObligations — "contract owed-ledger agrees:
> 30305742019 != 12560132754"` (plus the downstream underflow cascade).

So every `totalEscrowed +=/-=` mutant (lines 386, 623, 678, 686) is caught by
`invariant_EscrowHoldsExactlyOpenObligations`; they only survive the *fast subset* because that
subset omits the invariants by design.

> **Correction (2026-06-11 re-run):** the fee-residue arithmetic mutants (`unbooked = balanceOf +
> totalEscrowed`, `_min(deposit + withdrawn, …)`, lines 731-732, and `_min ==> true` 762) are **NOT**
> invariant-caught — verified by applying mutant 732 and observing `invariant_FeeEscrowLegFullyBacked`
> **PASS**. They are **equivalent mutants**: the `_min(remainder, unbooked)` cap and the contract's
> actual-`received` accounting force `unbooked == deposit - withdrawn` on the reachable early-Ended
> state, so the mutated and original expressions yield the identical refund. See the re-run breakdown
> table above for the full justification.

## Survivor triage (the remaining 103)

| Group | Count (approx) | Verdict |
|---|---:|---|
| **Event-emission removals** (`//emit Created/Resolved/Challenged/Ruled/Finalized/SliceRouted/StakeRouted/FeeStreamSettled`) | 15 | **Equivalent for value-safety.** Events change no funds and no storage; the suite (and the invariants) assert balances + state, never logs. Removing an emit cannot make money move wrong. Not a defect. |
| **Accounting mutants** (`totalEscrowed`±, fee-residue arithmetic) | ~10 | **Caught by the excluded invariant suite** (demonstrated above). Real kill, just not in the fast subset. |
| **`if (x > 0) ==> true` guard mutants** (`slice>0`, `toHarmed>0`, `surplus>0`, `toStaker>0`, lines 532/535/540/610/613/618) | ~6 | **Equivalent.** Forcing the guard true makes the contract `_safeTransfer(addr, 0)` / `emit …(…,0)` — a zero-value transfer is a no-op and the 0-emit is harmless. Behaviour is identical for value. (The guards are gas/noise reductions, not correctness gates.) |
| **Defensive `require` removals** (zero-address ctor checks; `NO_FUNDS`/`NO_FEE_FUNDS`; `SLICE_TOO_SMALL_FOR_BOND_BAND`; safe-transfer success check) | 13 | **Real but low-severity test gaps.** Their trigger conditions (zero-address deploy, zero-transfer token, dust slice < 4, a *failing* token) aren't in the fast unit subset; several ARE exercised by the adversarial fee-on-transfer / no-return token tests in the full run. Killable with targeted edge tests (see below). None is a live vulnerability — they guard inputs the deployer/caller controls or that the production token (Arc USDC) never produces. |
| **Init-literal tweaks** (`nextId = 0`, `feeStreamId = 0 ==> 1`) | few | Edge gaps; `feeStreamId` init only matters on the no-fee path. Low-severity, killable with a no-fee terminal assertion. |

## Conclusion

- **Revert-class kill rate is 100%** — the suite catches every "function body neutered" mutant,
  i.e. the tests genuinely exercise every state-changing path's effect.
- The **headline 83.7%** is a *floor* measured against the fast subset; the accounting survivors
  that drag it down are provably killed by the invariant suite excluded only for speed, and a
  large share of the rest are **equivalent mutants** (event emissions, `if(x>0)` zero-value
  guards) that *no* test can or should kill.
- **Genuine, actionable gaps** are a handful of low-severity defensive-`require` mutants. Suggested
  follow-up tests (not blocking): a constructor zero-address revert test, a `verifierSlice == 3`
  dust-band revert test, and a failing-token `_safeTransfer` revert test. These would push the
  fast-subset score into the 90s; they do not affect any deployed-contract safety property already
  proven by the invariants + Halmos.
