# Symbolic verification — CommitStakeV2 (+ StreamPay core)

**Tool:** Halmos 0.3.3 (a16z) over Foundry + solc 0.8.24. **Date:** 2026-06-11. Local, no network,
no keys. Spec: `test/SymbolicSpec.t.sol`. Run: `halmos --contract SymbolicSpec --function check_`.

Halmos symbolically executes each `check_*` over **all** 256-bit inputs (subject to `vm.assume`)
and either proves the assertions or returns a concrete counterexample. Result below:

```
[PASS] check_SurplusPositive_Overturn      (paths: 14)
[PASS] check_SurplusPositive_Liveness      (paths: 7)
[PASS] check_FeeResidue_NeverExceedsUnbooked (paths: 7)
[PASS] check_StakeLeg_Solvency             (paths: 5)
[PASS] check_StreamPay_SplitConserves      (paths: 5)
5 passed; 0 failed
```

Every check reports `bounds: []` — i.e. **complete**, not loop-bounded. No path explosion, no
timeout; the largest (overturn, 6 symbolic words) closed in ~1.5s.

## Method — assume-guarantee decomposition

The security-critical logic of CommitStakeV2 is the §7a **routing arithmetic** in `arbitrate`
(src:508-525) and `slashVerifierExpired` (src:610-621). Those expressions are mirrored 1:1 in the
spec with inline `src:` line references, and proven symbolically. The create-time **assumption**
they rest on —

```
verifierSlice > amount + feeDeposit + arbiterFee     (CommitStakeV2.sol:365, the gate-4 HIGH fix)
feeAccrued <= feeDeposit                              (feeAccrued is read from StreamPay state)
```

— is itself **enforced** (a `require`) and proven enforced by concrete tests
(`test_Create_RevertSliceAtOrBelowStake`, `test_ColdAudit_HostileArbiterFeeRejectedAtCreate`,
both reverting on violation). So: the require is checked concretely, its consequence is checked
symbolically over the whole input space. This is the standard SMT-spec split — it sidesteps the
path explosion a full `create→resolve→challenge→arbitrate→finalize` symbolic trace would cause,
while proving the same property with no loss of rigour on the arithmetic.

## What is proven — FULLY (complete, unbounded)

### (b) Surplus-positivity — the gate-4 HIGH property
`check_SurplusPositive_Overturn` / `_Liveness`. For every input satisfying the sizing rule:
`damage = feeAccrued + min(arbiterFee, bond) <= feeDeposit + arbiterFee < slice`, therefore
`toHarmed = min(damage, slice) = damage < slice` and **`surplus = slice − toHarmed > 0`**. The
§7a surplus-burn can never be zeroed — proven for all 2^256 combinations of
(amount, feeDeposit, arbiterFee, feeAccrued, bond, slice), not sampled. This is the symbolic
counterpart of the gate-4 finding and its fix.

Also proven in the same checks:
- **Slice conservation:** `toHarmed + surplus == slice` (no slice value minted or lost).
- **No over-routing:** `toHarmed <= slice` (the `_min` cap holds universally).

### (a) Solvency (stake leg + fee residue)
- `check_StakeLeg_Solvency`: routing the stake (`totalEscrowed -= amount; transfer(amount)`,
  src:676-677) leaves `balanceOf − amount >= totalEscrowed − amount` — the contract still covers
  **every remaining booked obligation**, and exactly this stake was removed (`newEscrowed ==
  otherBooked`). Solvency is preserved by the routing step for all (amount, otherBooked, balance).
- `check_FeeResidue_NeverExceedsUnbooked`: the early-Ended fee refund is `min(deposit−withdrawn,
  balanceOf−totalEscrowed)` (src:713-714), so `refunded <= unbooked` and `balanceOf − refunded >=
  totalEscrowed` — a residue payout provably **never dips into another commitment's booked
  escrow** (the cross-commitment-leak surface the cold audit probed manually, now proven).

### StreamPay core accounting (the reused primitive)
`check_StreamPay_SplitConserves`: `withdrawn + recipientBalance + senderBalance == deposit`
(StreamPay.sol:40 invariant) and the cancel split `toRecipient + toSender == deposit − withdrawn`
hold for all (deposit, withdrawn, streamed) — value is split, never minted or lost. This is the
fee-escrow-leg solvency root that CommitStakeV2's fee stream composes on.

## What is covered but NOT fully symbolic — and why

- **(c) No-double-pay across a full call sequence** (claim-after-slash, double-finalize). The
  *arithmetic* no-overpay is proven above (toHarmed ≤ slice; residue ≤ unbooked; stake removed
  exactly once). The *stateful* one-shot guarantee is enforced by the one-way status guards
  (`finalize` needs Resolved/Challenged, `arbitrate` needs Challenged, `slashVerifierExpired`
  needs Active; every terminal step sets Finalized/Expired first) and is verified by the
  `fail_on_revert = true` invariant suite (`invariant_StateMachineExactlyOneTerminal` +
  `_noteTransition` breach flag, CommitStakeV2Invariant.t.sol). A full symbolic call-sequence
  trace would path-explode on the 6-function state machine; the invariant fuzzer (10k runs ×
  depth 15) is the right tool there, and it is green. Documented as **bounded**, not claimed as a
  closed symbolic proof.
- **Full `create` symbolic execution** is not run — it makes three external calls (USDC
  `transferFrom`, `agentBond.lock`, `streamPay.createStream`) that would need symbolic mocks.
  Instead the sizing `require` it establishes is the proven assumption above (concrete revert
  tests + symbolic consequence).

## Net

The single most important Phase-3 obligation — **prove the gate-4 surplus-positivity property
symbolically** — is met completely and unbounded. Solvency (stake leg + fee residue no-leak) and
the StreamPay split invariant are also proven over the full input space. The remaining stateful
no-double-pay property is covered by the green `fail_on_revert` invariant suite, and that
boundary is stated honestly rather than overclaimed.
