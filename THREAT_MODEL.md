# Threat Model, Bondwire

Scope: the four on-chain contracts in this repo, [`AgentBond`](contracts/agent-bond/src/AgentBond.sol), [`StreamPay`](contracts/stream-pay/src/StreamPay.sol), [`CommitStake`](contracts/commit-stake/src/CommitStake.sol) and [`CommitStakeV2`](contracts/commit-stake-v2/src/CommitStakeV2.sol), deployed ownerless on Arc Testnet. `CommitStakeV2` was missing from this line until 2026-08-05 even though half the sections below are about it and it is the one under active use. All four custody USDC, so the model below asks one question per adversary: **can this actor make the contract pay out money it should not, or freeze money it should release?** Every mitigation listed is enforced by a specific code path and exercised by the test suite (unit + adversarial + 10,000-run fuzz + 10,000-run invariant campaigns; see each project's README for the live numbers).

## Trust assumptions (stated up front)

- **AgentBond**: the *agent chooses* which enforcer contract may lock/slash its bond, and caps it (`setSlashAllowance`). An enforcer is trusted *up to that cap and no further*. Dispute policy lives in the enforcer, by design.
- **CommitStake**: the *staker chooses* the verifier and the beneficiary at `create`. The verifier is trusted to judge pass/fail honestly, but it can neither redirect the money to itself nor hold it hostage (see below).
- **StreamPay**: no third party at all; only sender and recipient have any authority over a stream.
- The token is real Arc USDC (1:1 transfers). The contracts nevertheless defend against non-standard tokens via balance-delta custody, so a misconfigured deployment fails safe.

## Adversaries and defenses

### 1. Malicious verifier / enforcer (the trusted judge turns hostile)

**Attack:** CommitStake's verifier resolves `false` dishonestly to move the stake; AgentBond's enforcer slashes a healthy agent.

**Defense, damage is capped and cannot be redirected:**
- The payout destination is fixed *before* the judge acts: `CommitStake.create` pins `beneficiary` (`CommitStake.sol:113-120`), `AgentBond.lock` pins `creditor`. A hostile judge can trigger the payout, but only to the address the funding party already accepted, it cannot pay itself.
- AgentBond exposure is bounded by the agent's own grant: `lock` spends `slashAllowance`, which the agent sets with `setSlashAllowance`. A slash burns capacity permanently (`slash` does not restore allowance), so a hostile enforcer cannot recycle one grant into repeated slashes.
- **Correction (2026-07-24), since fixed: the revoke was not final on the contract deployed at the time.** An earlier version of this line said the agent "can revoke to zero at any time". That overstated the contract as it then stood. `release` restored the released amount to the allowance unconditionally, so while an obligation is still Active an enforcer can defeat a `setSlashAllowance(e, 0)` by releasing it (capacity comes back) and locking again. The exposure **cap is never exceeded** and no extra funds can be taken, this is not theft above the grant, but the agent cannot unilaterally end the relationship while the enforcer keeps one obligation in flight. **Fixed and deployed 2026-07-31** (an earlier version of this line said "not deployed"): grant generations + race-free `increase/decreaseSlashAllowance` now ship in the live AgentBond (`0x4383…702c`), which is exact-match verified. On the deployed contract a revoke *is* final. Two consequences worth stating: the fix added `allowanceEpoch` to the `Obligation` struct, which is what surfaced the hand-copied-ABI decode bug described in [AUDIT_SUMMARY.md](./AUDIT_SUMMARY.md); and `decreaseSlashAllowance(e, 1)` abandons the capacity return of every in-flight obligation, not just the one unit, so the tightening is blunter than the name suggests.
- Tested: `test_slash_paysCreditorAndBurnsCapacity`, `testFuzz_slash_paysExactlyLockedAmount`, `test_revokeAllowance_blocksNewLocks`, and the `invariant_exactlyOnePayout` campaign proving a stake can never reach both sides.

**Residual risk (accepted, documented):** a dishonest verifier *can* misjudge the outcome within those bounds. That is the stated trust model, pick your verifier/enforcer the way you pick an escrow agent. The primitive guarantees the blast radius, not the judge's honesty.

### 2. Silent verifier / abandoned obligation (griefing by doing nothing)

**Attack:** the judge simply never acts, freezing the funds forever.

**Defense, every escrow has a unilateral exit:**
- CommitStake: after the deadline, **anyone** may call `slashExpired` (`CommitStake.sol:158-166`); silence converges to the same outcome as a failed commitment, so going silent buys the verifier nothing. Resolution and expiry windows cannot overlap: `resolve` requires `block.timestamp <= deadline` (`CommitStake.sol:132`), `slashExpired` requires `> deadline` (`CommitStake.sol:161`).
- AgentBond: an obligation opened with a non-zero deadline lets the **agent self-release** after expiry (`release`), no enforcer can hold a bond hostage indefinitely.
- StreamPay: either party can `cancel` at any time (`StreamPay.sol:186-203`); the recipient keeps exactly the vested part, the sender reclaims the rest, so neither side can freeze the other's money.
- Tested: `testFuzz_silentVerifier_expiryPaysBeneficiary` (random late caller), `test_agentSelfRelease_afterDeadline`, `test_cancel_splitsCorrectly`, plus the invariant handlers which fuzz expiry/self-release paths across 150,000 calls.

### 3. Griefing via dust / repeated locks

**Attack:** lock an agent's bond in many tiny obligations, or open dust streams, to clog accounting.

**Defense:** every lock spends real allowance the agent granted, so the total griefable amount equals the cap the agent chose; zero-amount operations revert everywhere (`AMOUNT_ZERO` / `DEPOSIT_ZERO` checks); per-stream/per-commitment accounting is isolated (no shared pool), proven by `invariant_perStreamConservation` and `test_secondStream_cannotDrainFirst`, N dust entries can never touch each other's funds.

### 4. Front-running

**Attack surfaces considered:**
- *Allowance race (AgentBond):* an enforcer sees the agent's `setSlashAllowance(e, 0)` revocation in the mempool and front-runs it with `lock`. Outcome: it can lock at most the **previously granted** cap, funds the agent had already put at that enforcer's discretion. No privilege escalation; equivalent to the enforcer acting a block earlier. The agent's exposure bound (the cap) is never exceeded, enforced by the `ALLOWANCE` check (`AgentBond.sol:145`) and the `invariant_bondEquation` campaign.
- *Withdraw vs. cancel race (StreamPay):* whichever lands first, the recipient receives exactly the vested amount and the sender exactly the remainder, `cancel` computes the split at execution time (`StreamPay.sol:191-193`). Order cannot change anyone's total. Proven by `testFuzz_cancelSplitsExactly` (random pre-withdrawals before cancel) and `invariant_withdrawNeverExceedsVested`.
- *Resolve vs. expiry race (CommitStake):* the strict `<= deadline` / `> deadline` split makes the two paths mutually exclusive in any ordering; `NOT_ACTIVE` guards make the loser of the race a clean revert, never a double payout (`test_cannotDoubleResolve`, `invariant_exactlyOnePayout`).
- There is no price, auction, or oracle anywhere in the stack, the classic value-extraction front-running targets do not exist.

### 5. Reentrancy

**Attack:** a token (or creditor/beneficiary contract) re-enters during a transfer to double-withdraw or double-slash.

**Defense, belt and suspenders:**
- Every state-changing function is `nonReentrant` (single-slot guard, each contract's lines 12-25).
- Checks-effects-interactions: status flips and accounting updates happen **before** any external transfer in every payout path (`StreamPay.cancel` sets `Ended` + freezes `withdrawn` before paying, `StreamPay.sol:196-200`; `CommitStake.resolve/claim/slashExpired` set terminal status first; `AgentBond.slash` debits `locked`/`bond` first).
- Tested with hostile tokens that actively re-enter: `test_reentrancy_noDoublePay` (StreamPay), `test_reentrancy_noDoublePay_onClaim/onSlash` (CommitStake), `test_reentrantSlash_blocked` (AgentBond), the reentry attempt itself must fail, not just the theft.

### 6. Insolvency / cross-account drain (the quiet killer)

**Attack:** exploit bookkeeping drift, e.g. a fee-on-transfer token credits more than arrived, so one user's withdrawal is paid from another's escrow.

**Defense:** all three contracts record **balance-delta custody** on the way in (`received = balanceOf(after) - balanceOf(before)`, e.g. `StreamPay.sol:116-119`): the books can only ever claim what physically arrived. This is the property the invariant campaigns hammer hardest, solvency is asserted as *real token balance == independently tracked flows*, never as the contract agreeing with itself:
- `invariant_solvent_flowConservation` (all three), 10,000 runs × depth 15 = 150,000 randomized calls each, zero violations.
- `invariant_bondEquation` (AgentBond): `free + locked == deposits − slashed − withdrawn` against a ghost ledger built from observed transfers only.
- `test_feeOnTransfer_escrowStaysSolvent` / `test_feeOnTransfer_solvent_bothCanExit`: explicit hostile-token scenarios.

### 7. Privileged-role rug

**Attack:** admin drains the contracts or upgrades the logic.

**Defense:** structural, there is no owner, no admin function, no upgrade hook, no pausability, and no `selfdestruct` in any of the three contracts. The only addresses that can ever move a given escrow's funds are the ones named in that escrow's record. Nothing to compromise, nothing to subpoena.

### 8. Sockpuppet-arbiter attack (CommitStakeV2, the honest verifier's slice)

> **Correction, 2026-07-24.** Every earlier version of this section classified this as *griefing, not theft*, on the claim that "the attacker nets ≈ gas (no profit, by the same burn)". **That claim was wrong.** A PoC measurement (two independent runs, below) shows the attack is *profitable*. The corrected analysis stands here in full rather than being quietly deleted, because the point of this document is that its numbers can be checked.

**Attack:** CommitStakeV2 adds a dispute arbiter, named by the staker at `create`. A staker names an arbiter that is only address-distinct from the parties, locks an honest verifier's bonded slice, lets the verifier resolve *correctly*, challenges as the harmed party, and has its sockpuppet arbiter overturn the correct verdict. It is exploitable to the extent the verifier granted a broad slash allowance, exactly the open-market "free bond is a credit score, anyone can hire me" posture the repo advocates, so the precondition is not exotic.

**What the attacker actually nets.** In the overturn branch the arbiter fee lands on the same entity twice:
- `damage = feeAccrued + fee` is paid to the *harmed party* out of the **verifier's slashed slice** (the overturn branch of `arbitrate`);
- `fee` is paid to the *arbiter* out of the **challenger's own challenge bond**, and the challenger is refunded the remainder.

With independent parties this is correct: the second leg reimburses a real cost, and a control run confirms an independent challenger's net delta is exactly **0**. When challenger, harmed party and arbiter are one entity, the second leg is a refund of its own money, so the first leg is pure profit **taken from the verifier's bond**. Measured net gain: `min(feeAccrued + arbiterFee, slice)`.

Measured (Foundry PoC, attacker's total USDC delta across all its addresses, gas excluded):

| Stake | Verifier slice | `arbiterFee` | Attacker net | Burned |
|---|---|---|---|---|
| 1 USDC (dust) | 150 USDC | 5 USDC | **+5.000000 USDC** | 145 USDC |
| 1 USDC (dust) | 10,000 USDC | ~9,999 USDC | **+9,998.999999 USDC** | ~1.000001 USDC |

The `SLICE_TOO_SMALL` check in `create` requires `verifierSlice > amount + feeDeposit + arbiterFee`, which guarantees the surplus burn is *strictly positive* but can leave it as small as 1 wei. There is **no cap on `arbiterFee` relative to the slice**, so the profit scales to nearly the whole slice. **This is theft from the verifier, not griefing**, and the §7a surplus burn bounds only *how much is destroyed*, not *how much the attacker keeps*.

Note that two in-code NatSpec comments carry the same superseded reasoning (the `SLICE_TOO_SMALL` natspec, "a lie must be a mathematical loss in every outcome" / "damage can no longer reach the slice", and the `arbitrate` overturn comment). They are left byte-for-byte untouched on purpose: the deployed CommitStakeV2 is exact-match verified, and editing even a comment would change the metadata hash and break the recompile-to-bytecode check a judge may run. Read them against this section.

**Defense (deployed release):** the only contract-level bound is the slash allowance the verifier grants AgentBond, spent per `lock`. An operator running against the deployed contract **must** grant a minimal per-job allowance, since the slice it authorises is the maximum an attacker can extract. Blanket allowances are unsafe on the deployed release. The symbolic spec proves the *accounting* of a slash, not the *justness* of the verdict, and arbiter honesty is a stated trust assumption, exactly as the verifier's is.

**Defense (the fix, implemented, tested, deployed 2026-07-31):** branch [`fix/arbiter-griefing-optin`](https://github.com/Mnorbert87/bondwire/pull/1) (Draft PR #1):
- **Per-commitment arbiter opt-in**, a verifier must `approveArbiter(arbiter, true)` before any staker may name that arbiter over its bond (mirrors `setSlashAllowance`: consent to the *judge*, not just the enforcer). Address-distinctness alone is no longer sufficient.
- **Slice leverage cap**, `verifierSlice <= 3 × (amount + feeDeposit + arbiterFee)`: a dust stake can no longer lock a verifier's whole bond.
- Full suite green at the time (88 tests then, 125 today); the Halmos §7a routing spec is unchanged.

**What that fix does and does not close (corrected 2026-07-24).** The opt-in kills the sockpuppet precondition and the leverage cap kills the dust-stake amplification, so together they remove the practical attack. They do **not** remove the underlying profit leg: `damage` reimburses `arbiterFee` out of the slice regardless of whether the arbiter was genuinely independent, which is not provable on-chain. A complete fix needs `arbiterFee` bounded relative to the slice (or excluded from `damage`). Tracked as open, not claimed as solved.

**Deployed 2026-07-31** (supersedes an earlier "why not deployed" note here). The fix ships in the live CommitStakeV2 (`0xf345…1474`), which is itself exact-match verified. The earlier note kept the fix on a branch to preserve the verification of the previous deployment; we took the other side of that trade and redeployed hardened, so **the deployed contract no longer carries the attack described above**. What remains open is the profit leg in the paragraph above: `arbiterFee` is still reimbursed out of the slice, and bounding it is not shipped.

### 9. USDC blacklist bricks terminal transitions (push-only payouts, all three contracts)

**Raised by an external audit, 2026-07-28; the two sub-cases below we separated ourselves after walking the control flow.** Every payout in the stack is a *push*: `_routeStake` / `_routeChallengeBond`, the overturn payout to the harmed party in `arbitrate`, the liveness branch and the fee residue in `slashVerifierExpired`, `StreamPay.cancel` and `AgentBond.slash` all call `_safeTransfer`, which is a hard `require`. There is no pull/claim fallback, no rescue path and no owner anywhere in the three contracts, by design. The settlement token is real Circle USDC, which can blacklist an address, and transfers to a blacklisted address revert. So one blacklisted counterparty can make a terminal transition permanently unexecutable.

The repo already pinned "revert rather than silently lose funds" as intended behavior (`CommitStakeV2EdgeMutation.t.sol:49-81`, against a false-returning token). What is new is that a blacklist makes that failure **selective and per-recipient** rather than token-wide: the rest of the system keeps working while one commitment is stuck.

**9a. Blacklisted before the challenge — the lying verifier walks.** The sharper of the two, and it does not present as a payout bug at all. `challenge` pulls the challenge bond from the challenger with `_safeTransferFrom`, so a blacklisted harmed party **cannot open the dispute in the first place**. Nothing reverts later because nothing later happens: the window expires, the clean branch of `finalize` runs, the verifier's slice is released **in full**, and the stake routes on the unchallenged verdict. A false verdict becomes final because the only party entitled to contest it was frozen out. Note the asymmetry — no payout line reverts, which is exactly why reading only the transfer sites misses this.

**9b. Blacklisted after the challenge — genuine deadlock.** The dispute is open and both exits are blocked: `arbitrate(overturn)` reverts on the payout to the harmed party, and the silent-arbiter branch of `finalize` reverts too, because the challenger and the harmed party are always the same address. Nothing is stolen, but the commitment cannot reach a terminal state. The AgentBond `byAgentExpired` self-release still frees the verifier's bond at the backstop deadline, so that lock is bounded; the staked USDC is not.

**Related, same mechanism:** a blacklisted `creditor` makes `AgentBond.slash` uncallable, and the agent then self-releases its **entire bond** at the deadline. The slash does not merely freeze — it converts into a full recovery for the defaulting agent.

**Severity: medium, not high.** Counterparties are pinned by the funding party at `create`, so this is counterparty-selection risk rather than an attacker-reachable griefing vector, and the AgentBond backstop bounds every bond lock. One claim in the original finding — that a blacklisted verifier could escape its own liveness slash — **does not hold**: `create` enforces `feeStart >= deadline + challengeWindow`, while `slashVerifierExpired` is permissionless, has no upper time bound, and becomes callable at `deadline + 1`, where `streamedTotal` is still 0 and `StreamPay.cancel` skips the recipient payment entirely. The timing sits with the defender, not the attacker.

**Status: acknowledged, not fixed.** A correct fix is a `pendingWithdrawal` + `claim()` fallback with every push wrapped so the state transition always completes. That touches every payout path in all three contracts and needs a blacklist-mock test across all nine terminal branches. We are not shipping that as a rushed pre-submission change, and it could not be deployed anyway without invalidating CommitStakeV2's exact-match verification. Operator mitigation today: treat counterparty selection as the security boundary it actually is.

### 10. Staker-chosen time parameters were unbounded (CommitStakeV2)

`create` checked only lower bounds on `deadline`, `challengeWindow` and `arbiterDeadline`. The staker picks all three; the verifier only granted a slashing allowance and never consented to these values. Yet it is the verifier's bonded slice that stays locked: `resolve` moves no bond, `finalize` cannot run before `resolvedAt + challengeWindow`, and the AgentBond backstop is derived from the same parameters, so it is no escape. A hostile staker could set `deadline = now + 10 years` and disable a verifier's bookable capacity for that long, for gas plus its own escrowed stake. Denial of capital rather than theft — but free bond *is* the verifier's product.

Not covered by §3: that section reasons in the amount dimension ("the total griefable amount equals the cap the agent chose") and bounds *how much*, never *for how long*. The §8 fix branch does not close it either — a leverage cap is not a time bound. Worth stating plainly: the existing invariant campaign bounds deadlines to 30 days (`CommitStakeV2Invariant.t.sol:100`), so a green campaign was never evidence against this.

**Fix, implemented and tested, deployed 2026-07-31:** branch [`fix/commitstake-param-bounds`](https://github.com/Mnorbert87/bondwire/tree/fix/commitstake-param-bounds) adds `MAX_DEADLINE_HORIZON` (90d), `MAX_CHALLENGE_WINDOW` (30d) and `MAX_ARBITER_DEADLINE` (30d), bounding the worst case at 90 + 30 + 30 + 7 days. The same branch fixes `recommendedSlice`, which still took `(amount, maxAccruableFee)` after the gate-4 fix folded `arbiterFee` into `SLICE_TOO_SMALL`: a direct caller passing only the fee deposit got a slice `create` then rejected (`amount = 100, feeDeposit = 0, arbiterFee = 60` returned 150 while `create` demands > 160 — fail-closed, and the SDK folded the legs by hand). 125 tests green on `commit-stake-v2` today, both fixes mutation-checked. This is why the fixes waited for a full redeploy instead of being patched into the previous deployment, a constraint we measured rather than assumed: changing a **single character in a comment** alters the solc metadata hash appended to the bytecode and breaks the exact-match verification.

### 11. Deliberate decisions an audit is likely to re-flag

Listed so a reviewer need not rediscover that they were considered.

- **`verifier == beneficiary` and `verifier == staker` are allowed.** Only the *arbiter* is gated at `create` (the three `ARBITER_IS_*` requires), and the NatSpec is scoped to the arbiter accordingly. All three actor overlaps are reasoned through in `contracts/commit-stake-v2/TEST_AUDIT.md`. A verifier that is also the beneficiary is incentivised to lie `fail` — exactly the false-fail case the staker may challenge, where an **overturn** leaves the verifier net negative. Two caveats, the second one corrected 2026-08-08 after it was raised in review and reproduced by reading the deployed source:
  1. That defense assumes the staker *does* challenge. Against a passive staker the overlap is free money, and the staker chose that verifier itself.
  2. **It also assumes the arbiter is not the verifier's.** `create` requires `arbiterApproved[verifier][arbiter]`, so the set of arbiters a staker may name is chosen by the verifier. A verifier that approves only its own sockpuppet turns the challenge from a defense into a second loss: on `uphold` the stake routes to the beneficiary (`_routeStake`, `CommitStakeV2.sol:752-753`), the slice is *released* rather than burned (`:581`), and the remainder of the challenge bond goes to the verifier (`:587`). With `verifier == beneficiary` and `arbiterFee = 0` the colluding pair collects the stake plus the whole challenge bond, keeps its slice, and nothing burns — so a staker who challenges ends up worse off than one who does not. Nothing here is outside §1's stated trust boundary (a named arbiter is a root of trust, and the primitive bounds the blast radius rather than vouching for the arbiter), but the recourse sentence above was written as though challenging always helps, and it does not. **Practical consequence for anyone using this contract: check `arbiterApproved` before you stake, and do not accept a commitment whose only permitted arbiter is one the verifier controls.** The burn is an overturn-branch device; it is not a general anti-collusion guarantee.
- **Back-dated `start` in `StreamPay.createStream`.** Already documented and dismissed under "Notes considered and dismissed" in `SECURITY_AUDIT.md`: the sender front-loads accrual with its own funds. Re-raised by the 2026-07-28 audit as a new finding; it is not.
- **`_safeApprove` does not zero before approving.** True, and unreachable: the single call site is immediately followed by `createStream`, which consumes the full allowance, so the next approval always starts from zero. We tried to break this with a fee-on-transfer token and failed.

> **Removed 2026-08-05.** A second copy of §8 sat here, below §11, carrying the pre-2026-07-24
> verdict that the correction at the top of §8 explicitly retracts. It called the attack
> "griefing / availability, not theft" — the exact sentence §8 now records as wrong — and it
> broke the section numbering, which ran 1 to 11 and then 8 again. Its unique content (the
> opt-in, the leverage cap, the deployment record) is all present in §8 above.

### 12. `arbiterFee` is a free parameter inside a cap that was supposed to bound it

**Reported by an external review, 2026-08-05. Independently reproduced before being written down:
the exploit below ran green against the source that is deployed today, and the regression tests are
in `CommitStakeV2GriefBounds.t.sol` on branch `fix/commitstake-grief-bounds`.**

`arbiterFee` is never escrowed. No transfer moves it at `create`, and none moves it later unless a
challenge is actually opened, in which case it is carved out of the *challenger's* bond. It
nonetheless appears in the denominator of both create-time sizing rules, including
`MAX_SLICE_LEVERAGE`, whose stated job is to stop a dust stake from locking a verifier's whole bond.
A parameter that costs nothing and raises a ceiling is not bounded by that ceiling.

Combined with a `deadline` that had only a lower bound of "not in the past", a permissionless
`slashVerifierExpired`, and a liveness branch that refunds the stake in full:

| Stake | `arbiterFee` | Slice | Deadline | Result |
|---|---|---|---|---|
| 1 USDC | 9,000 USDC | 10,000 USDC | `now + 1s` | the verifier's whole bond burned, stake refunded, attacker's cost is gas |
| 10 USDC | 5,000 USDC | 6,000 USDC | any | challenging a false `pass` costs 6,500 USDC, so the beneficiary cannot |

The control case is what pins it on the free parameter rather than on the cap: with
`arbiterFee = 0`, the same parameters revert with `SLICE_ABOVE_LEVERAGE_CAP`. The cap works. It is
simply not reachable while `arbiterFee` can inflate its own denominator.

**Three written claims are false because of this, and one of them cannot be edited.**

- §8 above: "a dust stake can no longer lock a verifier's whole bond." It can.
- The `MAX_SLICE_LEVERAGE` natspec in the contract: "so a dust stake can never lock a verifier's
  whole bond behind one job."
- The challenge-bond band natspec: the cap means "an over-sized bond can never be used to price out
  the (non-consenting) beneficiary either." The band caps the spam margin; `arbiterFee` is added on
  top of it.

The two natspec comments are in the source the deployed bytecode is exact-match verified against.
Editing them would change the metadata hash and break the recompile check a judge may run, so they
stay byte-for-byte as they are and are corrected here instead, the same policy §8 already applies to
its own superseded comments. Read them against this section.

**Severity.** Not theft: nothing is transferred to the attacker, the slice burns. It is destruction
of a verifier's bookable capacity at the price of gas, and it defeats the specific defense the repo
advertises against exactly that. The contract-level bound that does still hold is the one §8 already
names: the slash allowance the verifier grants AgentBond is spent per `lock`, so an operator running
against the deployed contract must grant a minimal per-job allowance rather than an open one. That
is a real mitigation and it is the only one available without a redeploy.

**Status: fixed on a branch, not deployed.** `fix/commitstake-grief-bounds` adds a
`MIN_RESOLVE_WINDOW` floor on the deadline and bounds `arbiterFee` by the value actually escrowed.
The branch runs main's 125 tests plus 5 new regression cases, all green. Stated plainly because the number matters more than the reassurance: the fix
does not remove the burn. A verifier that misses its window still loses the slice. What it bounds is
the amplification, from unbounded to `MAX_SLICE_LEVERAGE x (MAX_ARBITER_FEE_LEVERAGE + 1)` = 33x the
escrowed value, and a test asserts that ceiling rather than claiming it. Deploying it costs the
exact-match verification and moves every address again, which is the same trade taken on 2026-07-31
and is a human decision, not a technical one.

> **Reference style, 2026-08-05.** This document used to point at source *line numbers*.
> An external review resolved them and found that every reference into a file edited since
> they were written now landed somewhere else: the `AgentBond.slash` pointer sat inside
> `lock`, the `setSlashAllowance` pointer inside `withdraw`, the `SLICE_TOO_SMALL` pointer on
> `ARBITER_IS_VERIFIER`. The references into `StreamPay` and `CommitStake` were all still
> correct, for the only reason that matters: those two files were never edited. A document
> whose promise is that its numbers can be checked cannot use anchors that rot on every
> commit, so the pointers are now function and identifier names, which move with the code.

## What this model does *not* cover

- **Economic design of enforcers/verifiers** built on top, a badly designed enforcer can misuse the capacity an agent grants it (within the cap). Audit the policy layer separately.
- **Key management** of the participating EOAs/agents.
- **Arc consensus / RPC layer** below the EVM.
- Formal verification (Certora et al.) is explicitly out of scope for this phase; the assurance here is adversarial testing + fuzz + invariant campaigns with honest, reproducible numbers.
