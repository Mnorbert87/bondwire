# TEST_AUDIT, CommitStakeV2 suite notes (for the cold-read auditor)

**Scope:** the CommitStakeV2 test suite, aligned to the FINALIZED spec
`contracts/bondwire-pub/VERIFIER_ECONOMICS.md` (§7a deterministic slash routing:
`damage` to the harmed party, surplus → BURN; post-burn challenge-bond band). The spec is the
authority, the suite encodes the SPEC's routing table, not the implementation's observed
behaviour.

Run everything: `forge test` inside `contracts/commit-stake-v2`
(fuzz: 10,000 runs; invariants: 10,000 runs × depth 15, `fail_on_revert = true`).

**Current result: 74 tests passed / 0 failed** (39 unit, 21 adversarial, 6 fuzz, 5 invariant,
3 cold-audit guards). See the 4th-gate audit section at the end for the HIGH/LOW fixes.

## Assert-derivation discipline (read this before auditing)

Every terminal-outcome assert in `test/CommitStakeV2.t.sol` and the economics block of
`test/CommitStakeV2Adversarial.t.sol` is derived from a **row of the §7a routing table** in
VERIFIER_ECONOMICS.md, and the test names its row in a comment. The audit question is therefore
mechanical: *for each terminal outcome, find the table row, and check the assert is that row* , 
not "does the assert match what the code does". The known temptation this guards against:
regenerating expected values from the implementation under test.

Table-row → test map:

| §7a row | Test |
|---|---|
| Clean pass | `test_CleanPass_StakeToStakerSliceReleased` |
| Clean fail | `test_CleanFail_StakeToBeneficiary` |
| Liveness (damage = accrued fee, arbiter cost 0, surplus → burn, stake returned) | `test_Liveness_StakeReturnedDamageZeroSliceBurned`, `test_Liveness_WithAccruedFee_DamageToStakerSurplusBurned` |
| False fail overturned (damage → staker, surplus → burn, bond refunded − fee) | `test_Overturn_FalseFail_DamageToStakerSurplusBurned`, `test_Overturn_WithAccruedFee_DamageIncludesOnChainAccrued` |
| False pass overturned (damage → beneficiary, surplus → burn) | `test_Overturn_FalsePass_DamageToBeneficiarySurplusBurned` |
| Frivolous challenge (bond → arbiter fee + remainder to honest verifier) | `test_Uphold_FrivolousChallengerLosesBond`, `test_Uphold_Fail_StakeStillToBeneficiary` |
| Arbiter silence (fails closed, bond returned in full, arbiter unpaid) | `test_ArbiterSilence_*` |

The anti-raid claim itself (§7a "Why this defangs the raid (G1)") has a direct test:
`test_Economics_RaidNetsZeroEvenOnArbiterError`, a staker≡beneficiary attacker challenging an
honest pass nets **exactly zero** on an erroneous overturn (the old routing paid it the whole
slice; break-even at ~17% arbiter error) and still loses the full bond on an uphold.

## The five invariants, and WHERE the state-machine transition prohibition sits

`test/CommitStakeV2Invariant.t.sol` checks the five mandated invariants against a ghost ledger
built from **real `balanceOf` deltas**, never the contract's own bookkeeping:

- **(a) nothing paid before terminal**, `invariant_StateMachineExactlyOneTerminal`
  (`paidTotal == 0` for live commitments) + `invariant_EscrowHoldsExactlyOpenObligations`.
- **(b) terminal routing conserves value**, `invariant_TerminalRoutingConservesValue`
  (line 487): `paid + burned == stakeIn + bondIn + sliceSlashed + feeReleased`. The §7a burn is
  a tracked destination, not a leak.
- **(c) a lie is always net-negative for the verifier**, `invariant_LieAlwaysNetNegativeForVerifier`:
  on every slashed outcome the measured slice loss strictly exceeds `stakeIn + maxFee`;
  **adjusted for §7a**: the routing change moves where the slice GOES (damage vs burn), not what
  the verifier LOSES, and two §7a-specific asserts are added, **a slash always burns a
  strictly-positive surplus** (now a genuine guarantee: the gate-4 sizing fix
  `verifierSlice > amount + feeDeposit + arbiterFee` keeps `damage < slice` universally, so
  `surplus = slice − damage > 0` by construction, see the gate-4 section below), and clean
  outcomes never burn.
- **(d) escrow solvency**, `invariant_EscrowHoldsExactlyOpenObligations` (line 471): real
  escrow balance == Σ open (stakeIn + bondIn), and the contract's own `totalEscrowed` ledger
  must agree.
- **(e) the state machine itself, THE "FIFTH INVARIANT". It does not live in the contract; it
  lives in the handler harness's breach flag.** Explicitly:
  - **`CommitStakeV2Handler._noteTransition` (line 334)** holds the legal-transition whitelist
    (Active→Resolved, Resolved→Challenged, Resolved→Finalized, Challenged→Finalized,
    Active→Expired, nothing else) and mirrors every observed transition against the on-chain
    status; any divergence or off-whitelist edge sets `breach`.
  - Every illegal-success probe (outsider/wrong-party calls, finalize/slash outside their exact
    preconditions, the same-timestamp finalize after a last-second challenge, double terminal
    transitions, terminal-without-outcome) also sets `breach` with a reason.
  - **`invariant_StateMachineExactlyOneTerminal` (line 442)** asserts `breach` stayed false and
    that every terminal commitment terminated exactly once with an immutable outcome.

  So: a state-machine violation is detected at the moment a handler op observes it, and the
  invariant run fails with the recorded `breachReason`. If you are looking for "where is the
  transition-prohibition asserted", it is this pair, by design, because the prohibition is a
  property of observed sequences, not of any single storage slot.

## What changed vs. the pre-§7a suite (routing realignment)

The previous 66-test suite validated the OLD (vulnerable) routing, whole slice to the
challenger on overturn, slice + stake to the staker on liveness, under which the
staker≡beneficiary raid broke even at ≈17% arbiter error. All terminal asserts were re-derived
from the §7a table (above); the raid now has a dedicated −EV test; the challenge-bond floor
tests moved from the (spec-rejected) 25%-of-stake rule to the post-burn band
`arbiterFee + [10%, 25%] × slice` (`test_Create_RevertBondBelowFloor`,
`test_Create_RevertBondAboveCap`, `testFuzz_Create_BondBandBoundary`).

Fee gating is now contract-enforced where the spec demands atomicity: the escrow itself opens
the StreamPay stream (it holds the sender-right; StreamPay's `cancel` is sender/recipient-only),
so the slash branches cancel atomically and read `feeAccruedToLyingVerifier` from StreamPay
state, never from a caller-supplied value. Tests:
`test_FeeStream_SlashCancelsAtomicallyAndRefundsStaker`,
`test_Liveness_WithAccruedFee_DamageToStakerSurplusBurned`,
`test_Overturn_WithAccruedFee_DamageIncludesOnChainAccrued`, and the early-recipient-cancel
residue case `test_FeeStream_RecipientEarlyCancelResidueForwardedToStaker`.

---

# 4th-gate independent adversarial audit (cold read)

**Method:** cold read, the auditor was deliberately given no prior "all green" report
(anchor-free). Adversarial frame: *find at least one way a faulty contract would still pass the
existing suite.* The §7a routing table was checked **backwards** (table row → is there an assert
that would FAIL on a mis-route?), not forward from the tests. Quota spent on attempts, not hits;
a clean verdict is backed by a per-property argument, never asserted bare.
**Toolchain:** forge 1.7.1, solc 0.8.24. **Run date:** 2026-06-11.
**Result:** one HIGH + one benign LOW found, **both now FIXED** (owner-approved fix round). Suite
71 → 74: `test/CommitStakeV2ColdAudit.t.sol` (3 guard tests) + the gate-4 sizing fix. All green.

## HIGH, `arbiterFee` was uncapped and fed `damage`, nullifying the §7a surplus-burn, **FIXED**

**Where:** `CommitStakeV2.create` enforced `verifierSlice > amount + feeDeposit` but **never
bounded `arbiterFee`** against the slice or stake. `arbitrate`'s overturn branch computes
`damage = feeAccrued + min(arbiterFee, challengeBondPaid)` and `toHarmed = _min(damage, slice)`
with `surplus = slice - toHarmed` burned.

**Attack (pre-fix):** a staker chose `arbiterFee >= verifierSlice` at create (legal, no
`ARBITER_FEE_*` check existed; the challenge-bond band `[arbiterFee+10%·slice,
arbiterFee+25%·slice]` scales *with* `arbiterFee`, so any `arbiterFee` was satisfiable). On an
overturn, `damage >= slice` ⇒ `toHarmed = slice` ⇒ **`surplus = 0`, nothing burned.** The §7a
surplus-burn, the central anti-raid / anti-collusion device, was fully disabled by a create
parameter. In the documented `staker≡beneficiary` raid with a colluding (bribed) arbiter, the
coalition `{staker, arbiter}` **recaptured the verifier's entire slashed slice** instead of being
capped at `damage`: the arbiter-fee leg is a pass-through that nets to zero *inside the coalition*,
so the whole slice was extracted. This violated the spec's own stated §9 bound ("the surplus-burn
caps how much such collusion can extract to `damage`"), `damage` was unbounded, so the cap was
meaningless.

**Fix applied (CommitStakeV2.sol create()):** the sizing rule is now the stronger, subsuming
inequality `require(verifierSlice > amount + feeDeposit + arbiterFee, "SLICE_TOO_SMALL")`. Since
`feeAccrued ≤ feeDeposit` and `min(arbiterFee, bond) ≤ arbiterFee`, this forces
`damage ≤ feeDeposit + arbiterFee < slice` on **every** slash branch ⇒ `surplus > 0` by
construction. The colluding-arbiter slice-recapture is closed: `damage` can no longer reach the
slice. Spec synced in the SAME round (VERIFIER_ECONOMICS.md §4 single-shot floor, §7a damage
discussion, §9 collusion-cap → now a true statement, Decided parameters).

**Why the suite missed it (and how that is now closed):** `invariant_LieAlwaysNetNegativeForVerifier`
asserts `assertGt(g.burned, 0)`, justified by "damage < slice by sizing." Pre-fix that was true
only because the invariant **handler capped `arbiterFee` at `amount`**
(CommitStakeV2Invariant.t.sol:131, `bound(feeSeed >> 8, 0, amount)`), so the hostile region
(`arbiterFee ≥ slice − amount − feeDeposit`) was structurally unreachable. **Now:** the handler
fuzzes `arbiterFee` up to `slice + amount` and try/catch-skips the create-revert (honouring
`fail_on_revert = true`), so the run actively exercises "a hostile commitment cannot be created";
and the fix makes `damage < slice` a contract guarantee, so the assert is honest.

**Regression guards (`test/CommitStakeV2ColdAudit.t.sol`, all PASS, the demos flipped to guards):**
- `test_ColdAudit_HostileArbiterFeeRejectedAtCreate`, `arbiterFee == slice − stake` (boundary,
  equality) and `arbiterFee == slice` (deep hostile) both `vm.expectRevert("SLICE_TOO_SMALL")`.
- `test_ColdAudit_MaxAllowedArbiterFee_StillBurnsPositive`, at the LARGEST legal arbiterFee
  (`slice − stake − 1`) an overturn still has `burned == slice − damage > 0`; harmed captures only
  `damage`, the rest burns.
- `test_ColdAudit_CollusionBoundedToDamageNotWholeSlice`, `staker==beneficiary` raid + colluding
  arbiter: coalition net `== damage` (NOT the slice), `burned == slice − damage > 0`. The §7a cap
  is now real.

## §7a routing table, backward verdict (row → protecting assert)

| §7a row | Protecting assert(s) | Verdict |
|---|---|---|
| Clean pass → staker, slice released | `test_CleanPass_StakeToStakerSliceReleased` + invariant (b)(d) | **clean**, stake delta + AgentBond release both asserted |
| Clean fail → beneficiary, slice released | `test_CleanFail_StakeToBeneficiary` + invariant (b) | **clean** |
| Liveness → stake returned, damage=accrued, surplus burned | `test_Liveness_*` (2) + invariant (c) | **clean**, burn>0 guaranteed (damage=feeAccrued≤feeDeposit<slice, no arbiter leg) |
| False fail overturned → damage to staker, surplus burned, bond refunded−fee | `test_Overturn_FalseFail_*`, `test_Overturn_WithAccruedFee_*`, `test_ColdAudit_MaxAllowedArbiterFee_StillBurnsPositive` | **clean**, surplus-positivity now guaranteed by the gate-4 sizing fix (`damage < slice`); the edge case is guarded |
| False pass overturned → damage to beneficiary, surplus burned | `test_Overturn_FalsePass_DamageToBeneficiarySurplusBurned`, `test_ColdAudit_CollusionBoundedToDamageNotWholeSlice` | **clean**, surplus-positivity now guaranteed (`damage < slice`); collusion bound guarded |
| Frivolous challenge upheld → bond: arbiterFee to arbiter, remainder to verifier | `test_Uphold_FrivolousChallengerLosesBond`, `test_Uphold_Fail_*` | **clean**, both legs asserted; `_min(arbiterFee, bondPaid)` cap covers arbiterFee>bond |
| Arbiter silence → fails closed, bond returned in full, arbiter unpaid | `test_ArbiterSilence_*` (2) | **clean** |

## Actor-overlap combinations probed

- **staker == beneficiary** (the documented raid): allowed by design (only the arbiter is gated,
  create() :331-333). Defanged by the surplus-burn, now across the FULL `arbiterFee` range after
  the gate-4 fix. Covered by `test_Economics_RaidNetsZeroEvenOnArbiterError` (small arbiterFee)
  and `test_ColdAudit_CollusionBoundedToDamageNotWholeSlice` (max legal arbiterFee, coalition
  bounded at `damage`, surplus burned).
- **staker == verifier**: allowed. The staker judges its own stake; on a self-pass the stake
  merely returns to it at finalize and the verifier slice (its own bond) is released, no
  third-party funds are reachable. The beneficiary, harmed by a pass, can still challenge. **No
  theft path**, self-dealing with the actor's own escrow + own bond.
- **verifier == beneficiary**: allowed. The verifier profits from a `fail`, so it is incentivised
  to lie `fail`, but that is exactly the false-fail case the staker may challenge, and an
  overturn slashes the verifier (`test_Economics_FalseFailOverturned_VerifierNetNegative`). The
  overlap collapses "lying verifier" and "beneficiary of the lie" into one address without adding
  a new route. **No new hole.**
- **arbiter == verifier / staker / beneficiary**: blocked in code
  (`ARBITER_IS_VERIFIER/STAKER/BENEFICIARY`, :331-333), `test_Create_RevertArbiterConflicts`.
  **Clean.**

## LOW, challenge-bond band unsatisfiable for dust-range slices, **FIXED**

For `verifierSlice ∈ {2,3}` micro-USDC, `challengeBondFloor` (round-up 10%) exceeded
`challengeBondCap` (floor 25%): `floor = arbiterFee + 1 > arbiterFee + 0 = cap`, so **no bond
value satisfied both `BOND_BELOW_FLOOR` and `BOND_ABOVE_CAP`** and `create` reverted with an
inscrutable pair. No funds at risk, only sub-4-micro-USDC commitments were affected.
**Fix applied:** `require(verifierSlice >= 4, "SLICE_TOO_SMALL_FOR_BOND_BAND")` at create gives a
clean explicit error; the mechanism is untouched.

## Zero-find disclosure

This was **not** a zero-find audit: one HIGH (uncapped `arbiterFee` defeated the §7a burn) and one
benign LOW, **both now fixed and converted to guards**. The state-machine transition prohibition
was not re-derived from scratch, per the notes above it lives in the handler breach flag +
`invariant_StateMachineExactlyOneTerminal`, read and accepted as the locus, not blindly
re-searched. The fee-stream Ended-branch and `unbooked` cap were probed for cross-commitment
leakage and found **clean**: `refunded` is capped at both `s.deposit - s.withdrawn` (per-stream)
and `balanceOf - totalEscrowed` (unbooked surplus), so a residue payout can never dip into another
commitment's booked escrow; with fee-on-transfer the staker may be *under*-refunded (acknowledged
solvency-over-completeness trade-off), never over.

## Error-class lesson (generalised, reuse on every future audit)

Both the gate-4 HIGH and the Phase-1 fee-on-transfer finding are the **same failure class**: *the
test domain was narrower than the contract's accepted input space.* A green invariant/fuzz suite
proves a property **only over the inputs it actually generates**, Phase-1 missed exotic tokens
because the mocks were standard; gate-4 missed `arbiterFee ≥ slice` because the handler bounded
`arbiterFee ≤ amount`. The standing audit move: for every create-parameter, ask "what is the
contract's *accepted* range, and does the fuzz domain span all of it, especially the region that
makes a derived quantity (here `damage`) cross a guard threshold (here `slice`)?" When the domains
differ, either widen the fuzz domain to the contract's edge (done here: handler now fuzzes
`arbiterFee` past the slice and asserts the revert) or tighten the contract so the gap cannot
matter (done here: the sizing rule now bounds `arbiterFee`). Prefer doing both.
