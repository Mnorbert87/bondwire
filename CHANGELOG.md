# Changelog

## CommitStake

The current, active CommitStake contract on Arc Testnet is:

- **CommitStakeV2**, `0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474`
  ([arcscan](https://testnet.arcscan.app/address/0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474))
  Deployed 2026-07-31 together with the redeployed AgentBond
  (`0x4383Ea48837eF7e60fC22BD67945BCBf0551702c`) and StreamPay
  (`0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262`). This is the deployment every
  document, demo and dApp in this repo points at.

### Superseded

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

- Headline stats now ship with a static on-chain snapshot baked into the HTML
  and animate to live values on load; if the RPC is cold or rate-limited the
  snapshot stays visible (no empty `, ` placeholders).
- Removed the legacy CommitStake contract from the landing page and address
  bar (recorded here instead).
- StreamPay copy clarified: the stream solves the *shape* of payment; trust in
  the work is backstopped by AgentBond's slashable bond.
- Nanopayments moved from "Circle products used" to a Future work note (not
  integrated in this testnet demo).
