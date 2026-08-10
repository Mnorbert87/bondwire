# Changelog

## CommitStake

The current, active CommitStake contract on Arc Testnet is:

- **CommitStakeV2**, `0x548532aa4B59598188D49b3e74Fdf27aaE127bb6`
  ([arcscan](https://testnet.arcscan.app/address/0x548532aa4B59598188D49b3e74Fdf27aaE127bb6))
  Deployed 2026-08-10, wired to the same AgentBond
  (`0x4383Ea48837eF7e60fC22BD67945BCBf0551702c`) and StreamPay
  (`0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262`) as before: those two sources did
  not change, so they were not redeployed and they keep their transaction
  history. This is the deployment every document, demo and dApp in this repo
  points at.

  It carries one fix the 2026-07-31 deployment did not have. `arbiterFee` is
  never escrowed, yet it sat in the denominator of the sizing rule and of
  `MAX_SLICE_LEVERAGE`, whose job is to stop a dust stake from locking a
  verifier's whole bond. Combined with a `deadline` bounded only by "not in the
  past" and a permissionless `slashVerifierExpired`, a 1 USDC stake could burn a
  verifier's entire bond for the price of gas. Two new bounds close it:
  `MIN_RESOLVE_WINDOW` (1 hour floor on the resolve deadline) and
  `MAX_ARBITER_FEE_LEVERAGE` (10, applied to the value actually escrowed). The
  amplification is now bounded at 33x the escrowed value, and a test asserts
  both that 33x holds and that one micro-USDC past it reverts.

  **The demo video was recorded against the 2026-07-31 deployment.** It shows
  `0xf3457ABf…af1474` and that deployment's transaction hashes, and it says 229
  tests. Those numbers were true when it was cut and the contract is still on
  chain and still verified. This repo, the dApp and the seed run below have
  moved on to the address above and to 234 tests. Nothing was relabelled: the
  seed was re-run and re-earned on the new contract.

### Superseded

- **CommitStakeV2 (2026-07-31 to 2026-08-10)**, `0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474`
  The deployment the demo video was recorded against. Replaced on 2026-08-10 by
  the address above, which bounds the arbiter fee and floors the resolve window.
  Still on chain, still exact-match verified.
- **CommitStakeV2 (pre-redeploy)**, `0x1f1CA31bC36a95a3909628F1bA97970E20698CA9`
  The deployment this file used to call "current". Replaced on 2026-07-31 by
  the address above, which carries the three hardening fixes (per-commitment
  arbiter opt-in, time-parameter ceilings with a leverage cap, and AgentBond
  allowance epochs). Still on chain, still verified, but nothing in this repo
  targets it any more.
- **CommitStake (legacy)**, `0xc307d9287707Ba04c03Dd653b4457E949129A9a2`
  The earlier, simpler contract. Kept on-chain for historical reference and
  still covered by its own test suite in `contracts/commit-stake`, but the
  bonded-verifier slash path with §7a routing (damage to the harmed party,
  surplus burned) exists only in V2. Not referenced by the landing page or the
  demos.

## Landing page

- ~~Headline stats now ship with a static on-chain snapshot baked into the HTML
  and animate to live values on load; if the RPC is cold or rate-limited the
  snapshot stays visible (no empty `, ` placeholders).~~
  **Superseded, and the entry above was left standing after the behaviour was
  reversed.** `index.html` no longer bakes a snapshot. Every figure is either
  read from the chain on that load or replaced with a dash plus a note saying
  the RPC did not answer, because a stale number under a live indicator cannot
  be told apart from a fresh one. Read `rpcFailed()` in `index.html`.
- Removed the legacy CommitStake contract from the landing page and address
  bar (recorded here instead).
- StreamPay copy clarified: the stream solves the *shape* of payment; trust in
  the work is backstopped by AgentBond's slashable bond.
- Nanopayments moved from "Circle products used" to a Future work note (not
  integrated in this testnet demo).
