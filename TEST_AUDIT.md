# TEST_AUDIT — Independent Test-Suite Audit

**Scope:** the test suites of the three custody contracts in this repo — do they actually prove
what the contracts' documentation claims?

## Methodology

- **Fresh session, cold read.** The audit was performed by a separate Forge session that did not
  write the suites and had none of their creation context. It read the contracts and tests as a
  stranger would.
- **Adversarial brief:** *"find a way a broken contract would still pass this suite"* — i.e. attack
  the tests, not (only) the contracts.
- **Read-only.** The audit itself changed nothing; its single artifact was a probe test
  demonstrating the finding. The fix was applied afterwards, in a separate step, after sign-off
  (see [The fix](#the-fix)).

Run everything: `forge test` inside each of `contracts/agent-bond`, `contracts/commit-stake`,
`contracts/stream-pay`.

## Verdicts

| Contract | Verdict | Suite size (post-fix) |
|---|---|---|
| CommitStake | **PASS** (1 finding, fixed) | 28 tests, 0 failed |
| StreamPay | **PASS** (claim-wording finding, fixed) | 25 tests, 0 failed |
| AgentBond | **PASS** (evidence gap, fixed) | 32 tests, 0 failed |

### CommitStake (`contracts/commit-stake`)

Properties examined and confirmed actually tested:

- **Reentrancy / double-pay:** attacker token reenters `claim`/`slashExpired` during payout —
  blocked, exactly-once payout (`test/CommitStakeAdversarial.t.sol:23`, `:47`).
- **Access control:** fuzzed strangers cannot resolve or claim
  (`test/CommitStakeAdversarial.t.sol:127`, `:135`).
- **Exactly-one-payout lifecycle fuzz:** staker xor beneficiary is ever paid, once
  (`test/CommitStakeFuzz.t.sol`, 4 fuzz campaigns, 10k runs each).
- **Solvency invariants:** escrow balance == open stakes across random multi-actor sequences
  (`test/CommitStakeAdversarial.t.sol:238`, `test/CommitStakeInvariant.t.sol:131`, `:155`).
- **Fee-on-transfer / no-return units:** booked amount = received; both stakers exit; USDT-style
  token works end-to-end (`test/CommitStakeAdversarial.t.sol:69`, `:110`).

**FINDING (the one real issue):** see below.

### StreamPay (`contracts/stream-pay`)

- **Reentrancy, fee-on-transfer custody, access fuzz, terminal views:**
  `test/StreamPayAdversarial.t.sol:134` (`test_feeOnTransfer_escrowStaysSolvent`), plus
  `test/AuditProbe.t.sol` (view regressions left by an earlier audit pass).
- **Invariants:** flow conservation, withdraw ≤ vested, per-stream conservation
  (`test/StreamPayInvariant.t.sol:143`, `:153`, `:163`).
- Finding here was wording only: the inline claim (`src/StreamPay.sol`, deposit custody block)
  said "solvent even against fee-on-transfer / **rebasing** tokens … safe for **any** ERC-20" —
  rebasing and "any" were never tested. Fixed by narrowing the claim (see fix).

### AgentBond (`contracts/agent-bond`)

- **Reentrancy on slash payout:** blocked, exactly-once (`test/AgentBondAdversarial.t.sol:90`).
- **Invariants:** book == balance, flow conservation, bond equation, locked ≤ bond
  (`test/AgentBondInvariant.t.sol:154`, `:161`, `:172`, `:186`).
- **Evidence gap (finding):** the contract-level NatSpec (`src/AgentBond.sol:40`) claimed it
  "stays solvent against **any non-standard ERC-20**" — but the suite contained **zero**
  fee-on-transfer or no-return token tests. The claim had no evidence at all here. Fixed by
  adding the unit evidence + narrowing the claim (see fix).

## The finding: fee-on-transfer custody over-claim

**The claim (pre-fix):** all three contracts' docs asserted balance-delta custody keeps them
"solvent even against fee-on-transfer / rebasing tokens" / "any non-standard ERC-20".

**The attack on the suite (how a broken contract could pass):** suppose a maintainer replaces
balance-delta booking with naive booking (`amount` instead of `received`). Every shipped fuzz and
invariant campaign uses a 1:1 `MockERC20`, where `received == amount` always — so **every suite
stays green** while the headline custody property is silently gone. Worse, the production solvency
invariant (`commit-stake/test/CommitStakeInvariant.t.sol:155`,
`invariant_solvent_flowConservation`) models payouts as "recipient received == escrow released",
a 1:1 assumption: pointed at a real fee token it would *fail against a correct contract*. The
suites were structurally incapable of ever exercising the claim.

**The proof:** `contracts/commit-stake/test/CommitStakeFeeTokenProbe.t.sol` (kept as a regression
test) re-runs the invariant's own ghost-conservation model with a 10% fee-on-transfer token:

- `test_ghostFlowModel_breaksUnderFeeToken` — the 1:1 ghost model provably does **not** hold under
  a fee token (the mismatch is exactly the outbound skim), so the shipped invariant can only ever
  run against a 1:1 mock and can never validate the claim.
- `test_contractStaysSolventByOwnBooks_underFeeToken` — the **contract itself is fine**: by its
  own books it stays exactly solvent and nothing gets stuck. The gap was in tests + docs, not an
  exploit. No funds were ever at risk on Arc (USDC is a standard 1:1 ERC-20).

**Severity:** documentation/test integrity, not an on-chain vulnerability.

## The fix

Approved by the owner, implemented in commit **`425e278`**
(*fix: scope ERC-20 custody claims to evidence (test-audit finding)*). Comment + test changes
only — no behavioural diff, the deployed Arc testnet instances are unaffected.

1. **AgentBond unit evidence added** — `contracts/agent-bond/test/AgentBondFeeToken.t.sol`,
   mirroring the CommitStake/StreamPay adversarial pattern:
   - fee-token deposits book only the received delta; **both** agents fully withdraw;
   - full deposit→allowance→lock→slash→withdraw lifecycle stays solvent by own books
     (escrow balance == Σ booked bonds; the outbound skim hits the recipient, not the escrow);
   - no-return (USDT-style) token full lifecycle through the safe-transfer helpers.
2. **NatSpec narrowed to the evidence** in all three contracts — `src/AgentBond.sol:39-43`
   (and the `deposit` doc), `src/StreamPay.sol:112-115`, `src/CommitStake.sol:104-107`. The
   claim is now: *balance-delta accounting books what actually arrived (balanceOf delta), not the
   requested amount; unit-tested with fee-on-transfer and no-return tokens; production token is
   Arc USDC, a standard 1:1 ERC-20; other exotic ERC-20 behaviours are out of scope.* The
   untestable words — "rebasing", "any non-standard ERC-20" — are gone.
3. **Probe kept as a regression test** (`contracts/commit-stake/test/CommitStakeFeeTokenProbe.t.sol`),
   so the suite-blindspot can't silently reopen.
4. **Fee-token invariant run added** — `contracts/commit-stake/test/CommitStakeFeeInvariant.t.sol`:
   the same multi-actor stateful campaign as the production invariant, but under a 10%
   fee-on-transfer token, with the ghost ledger built from the contract's own booked
   (balanceOf-delta) amounts. `invariant_solvent_byOwnBooks_feeToken` held over 10,000 runs /
   150,000 calls / 0 reverts.

### Post-fix suite results (all green)

```
agent-bond:    32 passed / 0 failed  (5 suites, incl. new AgentBondFeeToken units)
commit-stake:  28 passed / 0 failed  (7 suites, incl. probe + fee-token invariant)
stream-pay:    25 passed / 0 failed  (5 suites)
```

## Phase 3 backlog

- ~~`SECURITY_AUDIT.md` old wording + stale per-project test counts~~ — **resolved**: claims
  narrowed to the same evidence-scoped principle as the NatSpec, counts updated to the post-fix
  values above.
- Fee-token invariant runs for **StreamPay** and **AgentBond** (same own-book ghost pattern as
  `CommitStakeFeeInvariant.t.sol`); the unit evidence exists for both, the stateful campaign is
  the remaining nice-to-have.
