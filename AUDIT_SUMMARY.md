# Audit summary

What we checked, what we found, what we fixed, and what is still open. Written for a reviewer who
wants the short version and the ability to re-run any of it.

Last updated: 2026-08-10, when the §12 finding was fixed on chain and the stack redeployed.
(The hardened redeploy this document was first written for was 2026-07-31.)

---

## The short version

The contracts deployed before 2026-07-31 carried three defects we had found ourselves, documented
publicly, and deliberately **not** fixed, because fixing them meant redeploying and losing the
exact-match verification we had advertised. We decided the honest trade was the other way round, so
the stack was redeployed hardened. All three contracts are now fully verified and exact-match.

Nothing below was found by an outside auditor. It was found by attacking our own code, and the
tests that catch each defect ship in the repo.

---

## What we audited

| Layer | Method |
|---|---|
| Unit + adversarial | 234 tests across four Foundry projects, 0 failed |
| Fuzz | 23 properties, 10,000 runs each |
| Invariants | 16 campaigns, 10,000 runs × depth 15 = 150,000 calls, `fail_on_revert = true` |
| Symbolic | 5 Halmos proofs over the money paths (solvency, surplus-positivity on both slash branches, split conservation, fee residue). No-double-pay is stateful and belongs to the invariant campaign, not to these |
| Mutation | revert-class mutants on the accounting and the new gates |
| Static | Slither + Aderyn, every finding triaged |
| On-chain | every documented address and transaction re-measured against the live chain |

---

## What we found, and fixed

**1. A verifier could be griefed by an arbiter it never agreed to.**
A staker could name any address as arbiter on a commitment that locked someone else's bond. The
§7a surplus burn already made the attack unprofitable, but "unprofitable" is not "impossible."
Fixed with a per-commitment arbiter opt-in: the verifier consents to the judge, not just to the
escrow contract.

**2. A hostile staker could lock a verifier's capital for years.**
`deadline`, `challengeWindow` and `arbiterDeadline` are chosen by the staker, and the verifier's
capital pays for them. There was no ceiling. Fixed with `MAX_DEADLINE_HORIZON` (90d),
`MAX_CHALLENGE_WINDOW` (30d), `MAX_ARBITER_DEADLINE` (30d), plus a slice leverage cap so a dust
stake cannot lock a whole bond.

**3. A revoked slash allowance was not actually final.**
`release` returned capacity unconditionally, so an enforcer holding one live obligation could
defeat `setSlashAllowance(e, 0)` by releasing and re-locking, indefinitely. The exposure cap was
never exceeded, so this was not theft — but "the agent can revoke at any time" was not true of the
deployed contract, and we had said it was. Fixed with grant generations: a release only returns
capacity under the current generation.

**4. The three fixes together surfaced a fourth defect that neither showed alone.**
Adding `allowanceEpoch` to `AgentBond.Obligation` put a new field **before** `status`.
`CommitStakeV2` kept a hand-copied six-field view of that struct, so `getObligation(id).status`
decoded the epoch number instead of the status. Under one epoch value every obligation read back as
`Active`, and the liveness path then tried to slash an already-released obligation and reverted,
stranding the staker's stake. Caught by a backstop test, not by review.

This is the interesting one, because the class matters more than the instance: **every place where
one contract or page hand-copies another's ABI is a silent-decode risk.** We swept all of them —
four dApp pages and the SDK — and they now flip in the same change as the addresses, never before.
A conformance test (`sdk/test.abi-conformance.mjs`) compares the SDK's hand-written fragments to
the compiled artifacts so the next drift fails loudly instead of decoding garbage.

**5. Verification was weaker than the badge suggested.**
Before the redeploy, AgentBond and StreamPay showed a green "verified" badge on the explorer that
was served from Blockscout's bytecode database against an **older** source, not against the repo as
published. A recompile reproduced the runtime body but not the metadata trailer. We only found this
because we stopped trusting the badge and diffed the bytecode ourselves. After the redeploy all
three are `is_fully_verified = true`, `is_partially_verified = false`, and a local recompile matches
the deployed runtime byte for byte with only the constructor-set immutables differing.

**6. `arbiterFee` was free, and it sat inside the cap that was supposed to bound the leverage.**
The only finding here that came from outside. Reported on 2026-08-05 and reproduced before being
believed: a 1 USDC stake with a 9,000 USDC `arbiterFee` (never escrowed, at any point) passed both
sizing gates, locked a verifier's entire bond, and burned it through the permissionless liveness
branch with the stake refunded in full. Cost to the attacker: gas. With `arbiterFee = 0` the same
parameters revert, so the leverage cap worked and was simply walked around by a parameter that cost
nothing. Not theft, the slice burns; destruction of a verifier's bookable capacity.

Fixed and deployed 2026-08-10 in `0x548532aa4B59598188D49b3e74Fdf27aaE127bb6`: `MIN_RESOLVE_WINDOW`
(1 hour) floors the resolve deadline, `MAX_ARBITER_FEE_LEVERAGE` (10) bounds the fee by the value
actually escrowed. The fix bounds the amplification at 33x rather than removing the burn, and a test
asserts that number and that one micro-USDC past it reverts. The standing operator advice is
unchanged and independent of it: grant a minimal per-job slash allowance, never an open one.
Details in [THREAT_MODEL.md](./THREAT_MODEL.md) §12.

The gap between the report and the deployment is itself worth stating: the fix sat on a branch for
five days because deploying it meant moving every address again and re-earning every cited
transaction, and the demo video had already been cut against the previous deployment. That was a
judgement call about a submission, not a technical constraint, and the video still shows the old
address. See CHANGELOG.md.

---

## Still open, by choice

**USDC blacklist can strand a terminal transition.** Every payout is a push, and Circle USDC can
blacklist an address. A blacklisted counterparty can make one commitment unable to reach a terminal
state, and in one variant a harmed party frozen out of opening a dispute lets a false verdict stand.
Severity is medium rather than high: counterparties are pinned by the funding party at `create`, so
this is counterparty-selection risk, not an attacker-reachable griefing vector, and AgentBond's
self-release backstop bounds every bond lock. A correct fix is a `pendingWithdrawal` + `claim()`
fallback across every payout path in all three contracts. We are not shipping that as a rushed
pre-submission change. Details in [THREAT_MODEL.md](./THREAT_MODEL.md) §9.

**Aggregate leverage is not bounded, only per-commitment leverage is.** The time and leverage
ceilings bound one commitment. N commitments stack, so an attacker with a third of a verifier's
bond in capital can pin the whole bond and roll it forward. The verifier's exit is real, though: a
revoke is now genuinely final, which is what fix 3 above bought.

**A one-unit tightening is generational.** `decreaseSlashAllowance(e, 1)` abandons the capacity
return of every in-flight obligation, not just the one unit. The cap is never exceeded, so no funds
are at risk, but the penalty is blunter than the function name suggests.

---

## What a reviewer can re-run

```bash
git clone https://github.com/Mnorbert87/bondwire
cd bondwire/contracts/commit-stake-v2
git clone --depth 1 --branch v1.16.1 https://github.com/foundry-rs/forge-std lib/forge-std
forge test -vv
```

For the verification claim, recompile and compare against the chain rather than reading the badge:

```bash
forge build
cast code 0x548532aa4B59598188D49b3e74Fdf27aaE127bb6 --rpc-url https://rpc.testnet.arc.network
# diff against out/CommitStakeV2.sol/CommitStakeV2.json .deployedBytecode.object
# only the constructor-set immutable addresses should differ
```

The full internal trail lives in [THREAT_MODEL.md](./THREAT_MODEL.md),
[SECURITY_AUDIT.md](./SECURITY_AUDIT.md) and the four audit documents under
[`contracts/commit-stake-v2/`](./contracts/commit-stake-v2/).
