# Arc OSS Showcase submission draft (arc-canteen submit-showcase)

Prepared 2026-07-22. The showcase is OPEN (rolling, guided CLI flow on
arc-oss.thecanteenapp.com). Run after the pending commits are pushed:
`npm i -g arc-canteen && arc-canteen login && arc-canteen submit-showcase`
(login is an interactive step). Answers below map to what the flow asks for.

## Main repo

https://github.com/Mnorbert87/bondwire

## Live site

https://mnorbert87.github.io/bondwire/

## One line

Trust and settlement primitives for autonomous agents, settled in USDC on Arc.

## What primitives are you exposing that other builders could find useful?

Three ownerless, exact match verified contracts on Arc testnet, each a building
block on its own and composable together:

1. **AgentBond** (0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0) — slashable trust
   bonds. An agent deposits USDC as skin in the game; any enforcer contract the
   agent approves can lock a slice behind an obligation and slash it on default.
   The public views double as a money backed reputation feed: bond depth, locked,
   free capacity, per obligation history. Invariant, fuzz and adversarial tested.
2. **StreamPay** (0x505739d33D85AD85D0f9eeE64856309782382450) — continuous USDC
   settlement. Open a stream, funds accrue per second, the recipient withdraws
   any time, either side cancels with a fair split. The x402 demo in the repo
   gates an HTTP API on a live stream.
3. **CommitStakeV2** (0x1f1CA31bC36a95a3909628F1bA97970E20698CA9) — bonded
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
`npm i` for the SDK/MCP. Fork, point at the baked in testnet addresses, go.

## Open source commitment

MIT, open now and going forward.

## Notes for the submitter

- Push the 11 pending commits first (gh auth login), so the MCP + demo-flow are
  public before reviewers click.
- The arc-canteen login is interactive — Főnök or Kocka runs it.
- Zero hyphen check done on this copy.
