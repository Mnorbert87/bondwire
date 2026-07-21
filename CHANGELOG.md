# Changelog

## CommitStake

The current, active CommitStake contract on Arc Testnet is:

- **CommitStake**, `0x1f1CA31bC36a95a3909628F1bA97970E20698CA9`
  ([arcscan](https://testnet.arcscan.app/address/0x1f1CA31bC36a95a3909628F1bA97970E20698CA9))

### Superseded

- **CommitStake (legacy)**, `0xc307d9287707Ba04c03Dd653b4457E949129A9a2`
  Earlier deployment, kept on-chain for historical reference only. Replaced by
  the active contract above, which adds the bonded-verifier slash path with
  §7a routing (damage to the harmed party, surplus burned). Not referenced by
  the landing page or the demos.

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
