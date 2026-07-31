# Agent, Circle Wallets signing Arc transactions

Aiden is the autonomous agent in this stack. It can run the full lifecycle two ways:

| Script | Signer | What it proves |
|---|---|---|
| `demo-agent.js`    | local burner key (`PRIVATE_KEY`)        | the contracts work end-to-end in USDC on Arc |
| `circle-execute.js`| **Circle Developer-Controlled Wallet**   | the agent signs Arc txs with **no private key on disk** |

The Circle path is the interesting one: Circle custodies the key, and the agent authorizes
each contract call with a registered **Entity Secret**. This is the missing primitive between
"smart contract" and "autonomous agent", a key the agent can spend from without anyone holding
raw key material.

## Verified live run (Arc Testnet)

Signed by Circle wallet `0xdFDaDEb7440f1CE4Cc2f62Aa21BCCe3374bDF46b` (provisioned on `BONDWIRE-TESTNET`):

| Step | Call | Tx |
|---|---|---|
| Approve | `USDC.approve(StreamPay)` | [`0x7ec0f1…0a28`](https://testnet.arcscan.app/tx/0x7ec0f1bcaa668eed2eb9ab5ed058130dc0a18c058a2ec489563bdd60cebc0a28) |
| Approve | `USDC.approve(AgentBond)` | [`0xba3472…2b34`](https://testnet.arcscan.app/tx/0xba3472a541bf5f728dc7a1665baae677242dee9dfbac5670bbfbbcae845f2b34) |
| Bond | `AgentBond.deposit(2.5 USDC)` | [`0xbac7c1…4a01`](https://testnet.arcscan.app/tx/0xbac7c17559b7150a94dfbb8405120de78ac91066e10fc71895859762ae134a01) |
| Stream | `StreamPay.createStream(1 USDC / 120s)` | [`0x6bc4b0…68ac`](https://testnet.arcscan.app/tx/0x6bc4b021aed338dbabb96f1157243b3a39473f101dc395f0b83b338d330368ac) |

Circle's `estimateContractExecutionFee` and `createContractExecutionTransaction` worked against
Arc's USDC-as-gas model with no special-casing beyond the `BONDWIRE-TESTNET` chain id.

## Run it

```bash
npm install
export CIRCLE_API_KEY=TEST_API_KEY:<id>:<secret>

# 1) one-time: provision an Entity Secret + a wallet on BONDWIRE-TESTNET (writes ./.secrets/.env)
node circle-provision.js

# 2) fund the printed wallet address with testnet USDC (USDC is gas on Arc):
#    https://faucet.circle.com , or send USDC to it from any funded Arc wallet.

# 3) sign a real lifecycle through the Circle wallet
STEPS=approve,approveBond,deposit,stream node circle-execute.js
```

## Security

- `circle-provision.js` writes the Entity Secret and wallet ids to `./.secrets/.env` (mode 600,
  **gitignored**). The `recovery_file_*.dat` is the only way to rotate the Entity Secret, keep it
  safe, never commit it.
- `CIRCLE_API_KEY` is read from the environment (or `../commit-stake/.env`); it is never logged or
  committed.
- No raw private key is used or stored for the Circle path, Circle holds the key.
