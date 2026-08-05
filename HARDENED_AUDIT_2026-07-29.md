# Bondwire — Adversarial Audit of `deploy/hardened-2026-07-29`

**Scope:** the first branch on which three independently developed fixes sit on one tree:
per-commitment arbiter opt-in, CommitStakeV2 time/leverage ceilings, and AgentBond grant
generations (`allowanceEpoch`). Nothing on this branch has ever been deployed.

**Verdict:** the three on-chain fixes hold up. Every gate is genuinely load-bearing (8/8
mutations killed by the pre-existing suite). **The break is off-chain: the exact bug class that
was fixed in the Solidity interface is still live in the SDK**, and it feeds the Agent Passport.

**Guardrails observed:** zero chain operations, zero private-key use, zero transactions (no
anvil either). Everything below is source-level, `forge test`, or local ABI encoding. Work is
committed to `deploy/hardened-2026-07-29` only.

---

## Methodology (what was actually run)

| Step | Command |
|---|---|
| Baseline, all four projects | `forge test` in `contracts/{agent-bond,stream-pay,commit-stake,commit-stake-v2}` |
| Interface parity, structs + enums | side-by-side extraction of `Obligation` / `Stream` and both `Status` enums from the real contracts vs the hand-copied interfaces in `CommitStakeV2.sol` |
| Interface parity, selectors | `cast sig` on all five `IAgentBond` and three `IStreamPay` members vs the real declarations |
| SDK ABI drift | `node sdk/test.abi-conformance.mjs` (**new**, compares every SDK fragment to `out/*.json`) |
| SDK mis-decode proof | local `ethers.AbiCoder` encode-as-7 / decode-as-6, no chain |
| Mutation campaign | 8 mutations across the new gates, each run against the **pre-existing** suite with my own tests removed |
| Counter-tests | `CommitStakeV2HardenedAudit.t.sol` (6), `AgentBondEpochAudit.t.sol` (5) — **new** |

Baseline before any change: agent-bond 43, stream-pay 25, commit-stake 28, commit-stake-v2 118.
All green, 0 skipped.

---

## F1 — HIGH. The struct fix was applied to the Solidity interface but NOT to the SDK

**`sdk/bondwire.js:45`**

```
"function getObligation(uint256 id) view returns (tuple(address agent, address enforcer,
   address creditor, uint256 amount, uint64 deadline, uint8 status))"
```

Six fields. The real `AgentBond.getObligation` now returns **seven** — `allowanceEpoch` sits
before `status`, exactly the shift that was caught and fixed in `CommitStakeV2`'s local
`IAgentBond` copy. ABI decoding of a static tuple is positional and does not revert on a short
ABI: the extra trailing word is ignored and **`status` is read from the `allowanceEpoch` slot**.

**Attack path, played through.** `allowanceEpoch` is bumped by `setSlashAllowance` and
`decreaseSlashAllowance` — both called by the **agent itself**. So the agent controls the value
the SDK mistakes for its own obligation status. `passport()` (`sdk/bondwire.js:460-485`) buckets
obligations by that field:

```
if (st === 2) done++;                                  // "Released"
else if (st === 3) { slashed++; slashedAmt += o.amount; }  // "Slashed"
else if (st === 1) active++;
reliability = done / (done + slashed)
score = reliability*55 + bondSize*30 + taken*15
```

An agent that makes its **first** grant with `increaseSlashAllowance` (which deliberately does
not bump the epoch) keeps `allowanceEpoch = 0` forever. Every obligation it ever takes then
decodes as `status = 0` (`None`) and falls through all three branches: a **genuinely slashed
obligation is counted neither as slashed nor as settled**, and `slashedAmt` stays 0. The
passport — the product's headline "money-backed reputation", which `mcp/server.mjs` tells agents
to call *before hiring or paying* — under-reports the agent's own slash history, and the agent
picks the field that does it.

**Proof, run locally, no chain:**

```
epoch 0, live (Active)  -> SDK reads status: 0 (None)
epoch 2, live (Active)  -> SDK reads status: 2 (Released)
epoch 3, live (Active)  -> SDK reads status: 3 (Slashed)
```

**Why this is not merely cosmetic on-chain either.** `CommitStakeV2` reads the same field at
runtime to choose between releasing and slashing the verifier's slice, and **both paths fail
silently rather than reverting**:

- `CommitStakeV2.sol:819` `_releaseSliceIfActive` — `if (status == Active) release(...)`
- `CommitStakeV2.sol:829` `_slashSliceIfActive` — `if (status != Active) return 0;`

Under the old, misaligned interface an obligation locked at epoch 2 decodes as `Released`, so
`_slashSliceIfActive` **skips the slash and reports 0 received** — a lying verifier keeps its
slice and the §7a burn computes on zero. That is the bug that was already found and fixed here;
this section records that the fix is load-bearing and that a regression is silent, not loud.

**Counter-test written and run:** `sdk/test.abi-conformance.mjs`. Compares every hand-written SDK
fragment against the compiled artifact by canonical `name(inputs)->(outputs)` signature. It fails
today on exactly one fragment and passes on the other 20, which is also useful negative evidence
— nothing else has drifted.

```
[AgentBond]
  ✗ FAIL getObligation
      SDK      getObligation(uint256)->((address,address,address,uint256,uint64,uint8))
      contract getObligation(uint256)->((address,address,address,uint256,uint64,uint64,uint8))
❌ 1 ABI DRIFT(S)
```

**Fix:** add `uint64 allowanceEpoch` before `uint8 status` in the SDK fragment, and wire
`test.abi-conformance.mjs` into CI so the next struct change cannot ship half-applied.
> **Done 2026-08-05** (an external review pointed out this line had stayed an intention for a
> week): `.github/workflows/test.yml` now has an `sdk-abi-conformance` job. The test also no
> longer dies with a raw ENOENT when the artifacts are missing; it names the build command.

> Source change disclosure: to make the ABIs testable I added the `export` keyword to the three
> `*_ABI` constants in `sdk/bondwire.js`. Non-behavioural, and the only edit I made to shipped
> source; everything else I added is new test files.

---

## F2 — MEDIUM. The MCP's value-moving path cannot succeed, and the quote does not know it

`mcp/server.mjs` `bondwire_commit_execute` calls:

```js
await bw.commit({ verifier, beneficiary, amount, verifierSlice, goal });
```

No `arbiter`. `Bondwire.commit()` throws unconditionally on that (`sdk/bondwire.js:359-361`,
`"commit: 'arbiter' is required"`). So the MCP's headline escrow tool fails **before** signing —
100% of the time, on any input.

This branch adds a second unmet precondition on top: even with an arbiter supplied, `create` now
requires `arbiterApproved[verifier][arbiter]` (`CommitStakeV2.sol:378`). `bondwire_commit_quote`
runs a live passport check on the verifier and produces a confident preview, but it never reads
`arbiterApproved`, so it promises an execute that the contract will reject.

**Severity reasoning:** fails closed, no funds at risk, no signature produced — so this is
correctness and product surface, not a security hole. It is MEDIUM because the quote/execute
split is the MCP's stated safety model, and a quote that cannot be executed hollows it out.

**Fix:** add an `arbiter` parameter to both MCP tools, and read `arbiterApproved` inside
`bondwire_commit_quote` so the preview refuses (or warns) up front.

---

## F3 — LOW. The leverage cap and the bond-band floor carve out an unsatisfiable region

`create` now enforces three constraints on the slice at once. With
`V = amount + feeDeposit + arbiterFee`:

| constraint | source |
|---|---|
| `slice >= 4` | `CommitStakeV2.sol:398` `SLICE_TOO_SMALL_FOR_BOND_BAND` |
| `slice > V` | `CommitStakeV2.sol:427` `SLICE_TOO_SMALL` |
| `slice <= 3V` | `CommitStakeV2.sol:433` `SLICE_ABOVE_LEVERAGE_CAP` (**new**) |

Feasible iff `max(4, V+1) <= 3V`, i.e. `V >= 2`. At **`V = 1`** the window is empty: `slice >= 4`
and `slice <= 3` cannot both hold, so `create` reverts for every possible slice value. `amount > 0`
(`:368`) is the only lower bound on the stake, so `amount = 1, feeDeposit = 0, arbiterFee = 0` is
valid input that was constructible before this branch (slice = 4 satisfied both old constraints)
and is impossible now.

**Counter-test written and run:** `test_F3_leverageCap_makesDustCommitmentUnconstructible` sweeps
slice 1..12 at `amount = 1` and asserts every one reverts; `test_F3_amountTwo_isStillConstructible`
proves the hole is exactly the `V = 1` point and not a general dust ban. Both pass.

**Fix (pick one):** raise the minimum stake explicitly (`require(p.amount >= 2)`) so the failure
is named rather than emergent, or exempt the leverage cap below the bond-band floor
(`slice <= max(4, 3V)`). Either way the collision should be a deliberate, documented line.

---

## F4 — MEDIUM. `beneficiary == verifier` is unchecked, and it lets the judge pay itself

`create` rejects three role collisions (`CommitStakeV2.sol:373-376`): `arbiter != verifier`,
`arbiter != staker`, `arbiter != beneficiary`. It says nothing about `beneficiary == verifier`.

With that pairing a `FAIL` verdict routes the entire stake to the verifier itself. THREAT_MODEL §1
states the defense as *"A hostile judge can trigger the payout, but only to the address the
funding party already accepted, **it cannot pay itself**."* On the code as written the second
clause holds only because the staker is assumed to choose a sane beneficiary — it is not enforced,
while three weaker collisions are.

**Counter-test written and run:** `test_F4_beneficiaryEqualsVerifier_letsTheJudgePayItself` creates
the commitment (accepted), resolves FAIL, finalizes, and asserts the verifier's balance rises by
the full stake. Passes — i.e. the behaviour is real.

**Severity reasoning:** the staker inflicts this on itself, and the overturn path still gives it
recourse (harmed party on a FAIL verdict is the staker). So this is not theft from a third party.
It is MEDIUM because an automated integrator building on the documented invariant will get a
different guarantee than the one it read.

**Fix (pick one):** add `require(p.beneficiary != p.verifier, "BENEFICIARY_IS_VERIFIER")` for
symmetry with the arbiter checks, or narrow the THREAT_MODEL sentence to say the guarantee is
"cannot redirect to an address the staker did not name".

---

## F7 — MEDIUM (documentation). The ceilings bound one commitment, not the aggregate

`CommitStakeV2.sol:262-273` states the worst case as *"These ceilings bound the worst case at
90 + 30 + 30 + 7 days."* That is true **per commitment**. Commitments stack: N of them each lock
their own slice, and the caps do not interact.

**Counter-test written and run:** `test_F7_aggregateLeverage_stacksAcrossCommitments` opens five
commitments each sitting exactly on the leverage cap and asserts the verifier's locked bond equals
the sum of all five slices, with an aggregate 3× capital ratio reachable. Passes.

Consequence: an attacker holding `B/3` of capital can pin a verifier's whole bond `B`, and by
rolling fresh commitments as old ones settle can extend that past any single-commitment ceiling.
The stake returns to the attacker on the happy path, so the recurring cost is fees and gas.

**The good news, and it is an interaction between two of the three fixes:** the AgentBond epoch
change gives the verifier a real exit that did not exist before. `setSlashAllowance(cs, 0)` now
genuinely blocks new locks, because releases of in-flight obligations no longer refill the grant
(the old release-then-relock trap). Verified by `test_F9_revokeIsFinal_releaseCannotFundARelock`.

**Fix:** state the bound in aggregate terms and name the escape hatch — "one commitment is bounded
at 157 days; a verifier under a rolling lock revokes with `setSlashAllowance(enforcer, 0)`, which
is final since the grant-generation change".

---

## F8 — MEDIUM. A one-unit tightening wipes the full capacity return of every in-flight obligation

`AgentBond.decreaseSlashAllowance` bumps the epoch (`AgentBond.sol`, decrease path), and `release`
restores capacity only when `o.allowanceEpoch == allowanceEpoch[agent][enforcer]`. The epoch is a
single flag, so the penalty is independent of the size of the tightening.

An agent that trims a 600 USDC grant by **one micro-USDC** causes an honest enforcer holding a
500 USDC obligation to lose the whole 500 of revolving capacity when it settles cleanly — not the
1 unit the agent asked to withdraw.

**Counter-test written and run:** `test_F8_oneUnitTightening_wipesFullCapacityOfInFlightObligation`
asserts exactly that, plus `test_F8_increaseDoesNotBumpEpoch_soRestoreSurvives` pins the deliberate
asymmetry on the increase path. Both pass.

**Severity reasoning:** the exposure cap is never exceeded and no custody is affected (the bond
returns to free on release — asserted). This is a capacity-accounting trade, not a loss of funds.
It is MEDIUM because the NatSpec sells `decreaseSlashAllowance` as the *race-free, gentle*
alternative to `setSlashAllowance`, while in this respect it is exactly as blunt as a full revoke.

**Fix:** either document that any tightening is generational (so "reduce by a little" is not a
thing), or make the restore proportional — restore `min(o.amount, currentAllowanceHeadroom)`
instead of all-or-nothing.

---

## Findings pinned as correct (with the test that pins them)

| # | Property | Test |
|---|---|---|
| F5 | `staker == verifier` self-dealing is allowed, value-neutral, leaves bond accounting intact | `test_F5_stakerEqualsVerifier_isNeutralButAllowed` |
| F6 | Revoking an arbiter mid-flight blocks new commitments but never strands a live dispute | `test_F6_revokingArbiterMidFlight_doesNotStrandTheDispute` |
| F9 | The revoke is genuinely final: release cannot fund a relock | `test_F9_revokeIsFinal_releaseCannotFundARelock` |
| F10 | The epoch is per `(agent, enforcer)`; revoking A does not strip B's restore | `test_F10_epochIsPerEnforcer_revokeDoesNotLeakAcross` |
| F11 | `allowanceEpoch` is `uint64` bumped `unchecked`; it wraps at `2^64-1`, documented bound | `test_F11_epochWrapsAtUint64Max_documentedBound` |

Interface parity was checked mechanically and is **clean** after the struct fix: `Obligation` and
`Stream` match field-for-field, both `Status` enums match value-for-value, and all eight copied
function selectors match the real declarations.

---

## Mutation campaign

Every mutation was run against the **pre-existing** suite (my own counter-tests moved out of the
tree first), because the question is whether the shipped tests hold the new gates.

| # | Mutation | Result |
|---|---|---|
| M1 | arbiter opt-in gate removed | killed, 4 failed |
| M2 | `MAX_DEADLINE_HORIZON` ceiling removed | killed, 2 failed |
| M3 | `MAX_CHALLENGE_WINDOW` ceiling removed | killed, 1 failed |
| M4 | `MAX_ARBITER_DEADLINE` ceiling removed | killed, 1 failed |
| M5 | leverage cap removed | killed, 1 failed |
| M6 | `release` epoch gate removed (old behaviour restored) | killed, 2 failed |
| M7 | `setSlashAllowance` epoch bump removed | killed, 1 failed |
| M8 | `decreaseSlashAllowance` epoch bump removed | killed, 1 failed |
| M9 | `IAgentBond.Obligation` reverted to the six-field form | killed, **1 failed — and that is the problem** |

**M9 deserves its own paragraph.** Reverting the struct to its old six-field shape — the exact
regression that would silently skip a lying verifier's slash — is caught by **exactly one test out
of 118**, `test_Backstop_VerifierSelfReleaseAfterBufferThenStakeStillRecoverable`, and only
*incidentally*: it is a backstop test, and it fails with an opaque `NOT_ACTIVE` that names neither
the interface nor the decode. One incidental test is thin cover for the most dangerous regression
in the repo, especially since the failure mode on the contract side is silent (skip, not revert).

**Counter-test written and run:** `test_F12_obligationDecodeMatchesAgentBond_fieldForField` reads
the same obligation through CommitStakeV2's copied `IAgentBond` and through `AgentBond` itself and
asserts all seven fields are equal, plus that a fresh obligation decodes as `Active(1)`. It turns
the incidental catch into a direct, named one.

**A note on method:** my first mutation pass reported three of these as "caught" on an empty
failure count. That was a false positive in my own harness — a build failure and a test failure
look identical when you only grep the summary line. Re-run individually with full output, all
three genuinely fail. The numbers above are from the corrected run.

---

## What I could NOT cover

- **No execution against any chain, including a local anvil.** The guardrail was zero chain
  operations, so the SDK and MCP findings (F1, F2) are proven by local ABI encoding and by
  reading the call path, not by a live round trip. F1's on-chain twin is proven by mutation.
- **No symbolic re-run.** The Halmos specs were not re-executed against the new gates; the three
  ceilings and the arbiter gate are `require`s at the entry point and do not change the §7a
  routing algebra the specs cover, but I did not prove that, I reasoned it.
- **No invariant campaign written for the new state.** `arbiterApproved` and `allowanceEpoch` are
  not touched by the existing invariant handlers, so no fuzzed multi-actor sequence exercises
  approve/revoke or epoch bumps interleaved with locks. That is the largest remaining gap and the
  natural next piece of work.
- **The `feeDeposit > 0` fee-stream path** was not combined with the new ceilings; my
  counter-tests all run with `feeDeposit = 0`.
- **Gas/DoS at scale** (many thousands of obligations against the passport's multicall paging) was
  not measured.
