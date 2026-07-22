# bondwire-sdk

A tiny [ethers v6](https://docs.ethers.org/v6/) wrapper over the **Bondwire** stack:
[`AgentBond`](https://mnorbert87.github.io/bondwire/agent-bond/) (reputation backed
trust), [`StreamPay`](https://mnorbert87.github.io/bondwire/stream-pay/)
(continuous USDC settlement) and [`CommitStakeV2`](https://mnorbert87.github.io/bondwire/bonded-verifier/)
(bonded verifier escrow, pay only on verified PASS), deployed on **Arc testnet**
(chain `5042002`). Includes the Agent Passport reputation score as a single call.

Addresses, chain id, and USDC's 6 decimals are baked in. You pass human USDC amounts
(`"10"` = 10 USDC); the SDK handles micro-USDC conversion and approvals.

```bash
npm i ethers
# then copy sdk/bondwire.js from this repo next to your code
git clone https://github.com/Mnorbert87/bondwire.git
cp bondwire/sdk/bondwire.js .
```

> Not on npm (yet), the SDK is a single zero dependency ESM file; vendoring it is the supported install.

## 10-line integration

An agent posts a bond, then gets streamed paid by the second:

```js
import { ethers } from "ethers";
import { Bondwire } from "./bondwire.js";

const agent  = new ethers.Wallet(process.env.AGENT_KEY, Bondwire.provider());
const arc    = new Bondwire(agent);

await arc.bond("5");                                  // post 5 USDC of skin-in-the-game
const { id } = await arc.createStream(CLIENT_ADDR, "2", { durationSeconds: 3600, memo: "api work" });
console.log("free bond:", (await arc.freeBondOf(agent.address)).usdc);
console.log("stream", id, (await arc.getStream(id)).streamedPct + "% streamed");
```

That's the whole "is there an SDK?" answer: **yes**, bond + stream in a few lines.

## API

Construct with a **Signer** (to send transactions) or a **Provider** (read only views):

```js
const arc = new Bondwire(signerOrProvider);   // writes need a Signer
const ro  = Bondwire.readOnly();              // read straight off the public RPC
```

### AgentBond, trust layer

| Method | What it does |
|---|---|
| `bond(amount)` | Post / top up your bond (approves USDC for you USDC). |
| `unbond(amount)` | Withdraw free (unlocked) bond. |
| `setSlashAllowance(enforcer, amount)` | Let an enforcer contract lock/slash up to `amount` of your bond. |
| `lock(agent, creditor, amount, deadline?)` | *(enforcer)* Lock bond behind an obligation → `{ id, receipt }`. |
| `release(id)` | Obligation performed, bond unlocks, capacity returns. |
| `slash(id)` | Agent defaulted, bond pays the creditor. |
| `freeBondOf(agent)` · `bondOf(agent)` | Read the public "credit score" / full breakdown. |
| `slashAllowanceOf(agent, enforcer)` · `getObligation(id)` | Allowance + decoded obligation. |

### StreamPay, settlement layer

| Method | What it does |
|---|---|
| `createStream(recipient, amount, { durationSeconds \| stop, start?, memo? })` | Open a USDC stream → `{ id, receipt }` (approves USDC for you). |
| `withdraw(id, amount?)` | Recipient pulls streamed funds (default `"all"`). |
| `cancel(id)` | Either party cancels; recipient keeps streamed, sender reclaims the rest. |
| `recipientBalance(id)` · `senderBalance(id)` · `getStream(id)` | Live balances + decoded record with `streamedPct`. |

### CommitStakeV2, bonded verifier escrow

Pay only on verified PASS: the staker escrows USDC, an AgentBond bonded verifier posts
the verdict with its own money locked behind it, a challenge window plus optional
arbiter keep everyone honest. Try it live: [bonded verifier dApp](https://mnorbert87.github.io/bondwire/bonded-verifier/).

| Method | What it does |
|---|---|
| `commit({ verifier, beneficiary, amount, ... })` | Escrow USDC behind a verified outcome → `{ id, receipt }` (approves USDC for you, safe defaults for window/bond/deadline). |
| `resolveCommitment(id, passed)` | *(verifier)* Post the verdict. |
| `challengeCommitment(id)` | Dispute a verdict inside the window (escrows the challenge bond). |
| `arbitrateCommitment(id, overturn)` | *(arbiter)* Uphold or overturn a challenged verdict. |
| `finalizeCommitment(id)` | Settle after the window; routes stake, slice and bonds. |
| `commitment(id)` | Decoded state: status, outcome, amounts, windows. |

### Agent Passport, portable reputation

```js
const pass = await arc.passport("0xAgent...");
// { score: 55, tier: "Established", bond: { usdc: "37.0" }, reliability: 0.8,
//   obligations: { taken: 6, done: 4, slashed: 1, active: 1 }, slashedTotal: {...} }
```

Money backed reputation recomputed live from AgentBond in one Multicall3 round trip.
Same math as the hosted [Agent Passport](https://mnorbert87.github.io/bondwire/agent-passport/):
reliability (0 to 55) + bond depth (0 to 30) + track record (0 to 15); a slash flags the agent.

### Helpers

`Bondwire.provider()` · `Bondwire.readOnly()` · `arc.usdcBalanceOf(addr)` ·
`arc.approveUsdc(spender, amount)` · `arc.stats()` · `arc.explorerTx(hash)` · `BONDWIRE` (network constants).

Every amount view returns `{ raw, usdc }`, `raw` is the raw six decimal USDC bigint, `usdc` is the
formatted string. You never touch decimals.

## Network

```
RPC       https://rpc.testnet.arc.network
Chain id  5042002
Explorer  https://testnet.arcscan.app
USDC      0x3600000000000000000000000000000000000000  (native gas token + 6-dec ERC-20)
AgentBond      0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0
StreamPay      0x505739d33D85AD85D0f9eeE64856309782382450
CommitStakeV2  0x1f1CA31bC36a95a3909628F1bA97970E20698CA9
```

> Testnet only. Not audited for production; do not point this at mainnet funds.

MIT.
