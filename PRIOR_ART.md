# Prior art on Arc, and what Bondwire adds

Circle publishes sample apps that sit next to each of the three Bondwire primitives. A reviewer who
has seen them will otherwise read Bondwire as the same idea arriving late, so the comparison is
stated here in terms of **what each design trusts**, read from the source rather than from READMEs.

Read 2026-10-13 against shallow clones taken that day. Every statement below is from the
clone or from the GitHub API, not from a blog post.

| Circle sample | Adjacent to | License / activity |
|---|---|---|
| [`circlefin/arc-escrow`](https://github.com/circlefin/arc-escrow) | `CommitStakeV2` | Apache 2.0, 132 stars, 72 forks, last push 2026-06-18 |
| [`circlefin/arc-nanopayments`](https://github.com/circlefin/arc-nanopayments) | `StreamPay` | Apache 2.0, 44 stars, 47 forks, last push 2026-06-29 |
| [`circlefin/arc-x402-circle-wallets`](https://github.com/circlefin/arc-x402-circle-wallets) | `x402-demo/` | one file (a README), no license, 0 stars, pushed 2026-08-11 |

## `arc-escrow` and `CommitStakeV2`

`arc-escrow` is a Next.js app over Supabase, Circle Developer Controlled wallets and an OpenAI call
that validates the deliverable. Its one contract is
`contracts/escrow_smart_contract/RefundProtocol.sol`, 388 lines. What it binds:

- `pay(to, amount, refundTo)` records a `Payment` and credits `balances[to]`; the recipient pulls
  it with `withdraw(paymentIDs)` unless it was refunded first.
- `refundByArbiter(paymentID)` is `onlyArbiter` — the modifier is a `msg.sender != arbiter`
  check. It carries no counterparty signature, and falls back to the arbiter's own balance and a
  `debts` ledger when the recipient's balance is short.
- `earlyWithdrawByArbiter(...)` is also `onlyArbiter`, but does require the recipient's EIP-712
  signature over `EARLY_WITHDRAWAL_TYPEHASH`, so it is arbiter gated rather than unilateral.
- `refundByRecipient(paymentID)` lets the recipient hand their own payment back.

So the release condition is **the recipient's own pull**, reversible by a privileged address until
the payment is marked refunded. In the sample app the deliverable is judged by an OpenAI call, and
the route that runs after that verdict submits `withdraw(uint256[])` for the beneficiary. That is a
reasonable design for freelance work: "was the deliverable good" is not a question a chain can
answer.

**The difference is not that Bondwire removes the arbiter.** `CommitStakeV2` has one too, and the
honest statement of the difference is narrower:

1. **The verifier is bonded.** In `arc-escrow` there is no deposit the deciding party forfeits for
   a wrong verdict. `CommitStakeV2` is built around a different question, and it is the repo's own
   headline: *who pays when the verifier lies?*
2. **There is a challenge window before the arbiter can rule**, rather than a single discretionary
   call that settles it.
3. **The arbiter's fee is bounded and the resolve window is floored**, after an external review in
   August 2026 showed the fee was a free parameter inside the cap that was supposed to bound it.
   The exploit, its reproduction and the fix are kept in full in
   [`THREAT_MODEL.md` §12](./THREAT_MODEL.md), including the pre-fix deployment address, because a
   threat model that deletes what it fixed cannot be audited.

`AgentBond` and `StreamPay` are ownerless: no admin, no upgrade key.

## `arc-nanopayments` and `StreamPay`

`arc-nanopayments` is a LangChain buyer agent plus a Next.js seller over Circle Gateway, which
batches signed offchain authorizations into one onchain settlement. It pays from plain EOA keys:
`generate-wallets.mts` calls viem's `generatePrivateKey()`, and the agent reads `BUYER_PRIVATE_KEY`
from the environment. `arc-x402-circle-wallets` is a **one file repository** — a README describing
an agent that pays over x402 from a developer controlled wallet. There is no code in it to read,
and we are not treating a README as a demo.

The measurement that separates both from `StreamPay` is blunt: **neither ships a contract.**
`find . -name '*.sol'` returns nothing in either clone, and neither contains the string
`pragma solidity`. So nothing in either design can put the paying or performing agent's own capital
at stake, because there is no contract to hold it. That is the gap `AgentBond` fills, and it is the
one claim here that needs no interpretation of anybody's source: a slashable deposit is either
present in a design or it is not.

Scope of that measurement, stated: both clones are shallow and see `master`. `arc-x402-circle-wallets`
has only that branch; `arc-nanopayments` also carries nine dependabot branches, which are package
version bumps and were not cloned separately.

## What we are not claiming

We read `RefundProtocol.sol` to place our own work, not to audit it. Nothing here is a security
claim about Circle's code, and the few lines quoted above are the ones that define its trust model,
not an exhaustive review. Star and fork counts are from the GitHub API on 2026-10-13 and will
drift. Every claim here was re-checked against independent clones by a second reader before
publication.
