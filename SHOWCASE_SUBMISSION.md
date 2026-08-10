# Arc OSS Showcase submission draft (arc-canteen submit-showcase)

Prepared 2026-07-22, install line corrected 2026-08-09 after measuring it. The showcase is OPEN
(rolling) on arc-oss.thecanteenapp.com, and there are two ways in: the Google form linked from the
hackathon site, or the CLI. The CLI is a Python tool from
[the-canteen-dev/ARC-cli](https://github.com/the-canteen-dev/ARC-cli/), so it installs with `uv`,
not npm:

```
uv tool install arc-canteen
arc-canteen login            # interactive, GitHub handle
arc-canteen submit-showcase  # re-runnable, a later entry supersedes an earlier one
```

This file said `npm i -g arc-canteen` until 2026-08-09. There is no such npm package: the registry
returns 404, which is why nobody could have followed that line. `uv` is already installed here
(0.11.11). Answers below map to what the flow asks for.

## Main repo

https://github.com/Mnorbert87/bondwire

## Live site

https://bondwire.dev/

## One line

Trust and settlement primitives for autonomous agents, settled in USDC on Arc.

## What primitives are you exposing that other builders could find useful?

Three ownerless, source-verified contracts on Arc testnet (CommitStakeV2 is
exact-match verified — recompile the repo and compare byte for byte), each a
building block on its own and composable together:

1. **AgentBond** (0x4383Ea48837eF7e60fC22BD67945BCBf0551702c) — slashable trust
   bonds. An agent deposits USDC as skin in the game; any enforcer contract the
   agent approves can lock a slice behind an obligation and slash it on default.
   The public views double as a money backed reputation feed: bond depth, locked,
   free capacity, per obligation history. Invariant, fuzz and adversarial tested.
2. **StreamPay** (0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262) — continuous USDC
   settlement. Open a stream, funds accrue per second, the recipient withdraws
   any time, either side cancels with a fair split. The x402 demo in the repo
   gates an HTTP API on a live stream.
3. **CommitStakeV2** (0x548532aa4B59598188D49b3e74Fdf27aaE127bb6) — bonded
   verifier escrow: pay only on verified PASS. The stake escrows, a bonded
   verifier posts the verdict with its own AgentBond slice locked behind it, a
   challenge window plus optional arbiter give recourse, and a lying verifier
   burns real money. Ten terminal outcomes, all invariant tested.

On top of the contracts, pickup paths for builders:

- **bondwire-sdk** — single file ethers v6 wrapper, human USDC amounts, the whole
  bonded verifier flow plus an `Agent Passport` reputation score in one call.
- **bondwire-mcp** — MCP server so any AI agent can check a passport, post a
  bond and open a bonded escrow from inside its tool loop, with quote before
  execute safety on every value moving call.
- **Live dApps, zero build** — Bondwire App (passport, hire, bond), Agent
  Passport, bonded verifier flow, all static pages over the public RPC.
- **demo-flow.mjs** — the whole loop in one command: passport, bond, escrow,
  verified PASS, finalize, passport moved.

## How does a builder get going without reading every line?

The README walks the three primitives with addresses, ABIs and a ten line SDK
integration; every contract ships its full Foundry test suite (invariant, fuzz,
adversarial) as executable documentation; SECURITY_AUDIT.md, THREAT_MODEL.md and
VERIFIER_ECONOMICS.md cover the sharp edges; and the Arc RPC quirks that bite
every newcomer (getLogs 10k cap, no concurrent or batched JSON RPC) are handled
inside the SDK and documented.

## Standalone forkable repo

The main repo is the standalone: no backend, no build step for the dApps, one
`npm i` at the root for the SDK and the demos, one more inside `mcp/` for the
MCP server. The SDK installs either way: `npm i bondwire-sdk` resolves to 0.3.0,
published 2026-08-09 and matching this repo, or you vendor the single file from
`sdk/bondwire.js`. The older 0.2.0 carries the superseded addresses and is
deprecated on the registry. Fork, point at the baked in testnet addresses, go.

## What is disclosed and not fixed

Two findings are disclosed and not shipped. THREAT_MODEL section 12 has the first
in full: `arbiterFee` is never escrowed at create, yet it sits in the denominator
of both the sizing rule and the leverage cap, so a dust stake can still lock a
verifier's entire bond and an unmeetable deadline burns it. I reproduced it
against the deployed source rather than taking the finding on trust; the test runs
green today. On this liveness path the attacker gains nothing, the whole slice
burns, so it is griefing at the cost of gas. The same parameter also carries a
theft vector, the sockpuppet arbiter profit leg in section 8, whose reimbursement
out of the slice is tracked open, with no fix on the branch; the branch fix bounds
the amplification to 33x rather than removing that leg.

The fix is written and tested on `fix/commitstake-grief-bounds`. It is deliberately
not merged: touching the source would break the exact match verification of the
deployed bytecode that this submission asks you to check. It ships after judging,
with a fresh deployment and a fresh verification.

Until then, section 8 and two natspec lines still assert a bound that section 12
refutes. I would rather you read both than only the flattering one.

## Open source commitment

MIT, open now and going forward.

## Notes for the submitter

- Everything is pushed; `main` and `origin/main` are level, so the MCP server and the
  demo flow are already public when a reviewer clicks.
- The arc-canteen login is interactive — Főnök or Kocka runs it.
- Zero hyphen check done on this copy.
