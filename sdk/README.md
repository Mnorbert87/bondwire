# bondwire-sdk

A tiny [ethers v6](https://docs.ethers.org/v6/) wrapper over the **Bondwire** stack:
[`AgentBond`](https://bondwire.dev/agent-bond/) (reputation backed
trust), [`StreamPay`](https://bondwire.dev/stream-pay/)
(continuous USDC settlement) and [`CommitStakeV2`](https://bondwire.dev/bonded-verifier/)
(bonded verifier escrow, pay only on verified PASS), deployed on **Arc testnet**
(chain `5042002`). Includes the Agent Passport reputation score as a single call.

Addresses, chain id, and USDC's 6 decimals are baked in. You pass human USDC amounts
(`"10"` = 10 USDC); the SDK handles six decimal unit conversion and approvals.

```bash
npm i bondwire-sdk ethers
```

Or vendor it, which stays supported either way: the SDK is one dependency free file.

```bash
npm i ethers
git clone https://github.com/Mnorbert87/bondwire.git
cp bondwire/sdk/bondwire.js .
```

> **Use the file in this repo. `bondwire-sdk@0.3.0` on the registry is now behind it.**
> 0.3.0 carries the CommitStakeV2 address that was live between 2026-07-31 and 2026-08-10,
> `0xf3457ABf…af1474`. That contract is still on chain and still verified, but it is the one
> with the unbounded `arbiterFee` leverage described in THREAT_MODEL §12, and it is not what
> this repo points at any more. The version here is 0.4.0: new address, plus `commit()` now
> names `DEADLINE_TOO_SOON` and `ARBITER_FEE_TOO_LARGE` before signing instead of letting Arc
> return a reasonless revert. 0.4.0 is not on the registry yet.
>
> **Not `bondwire-sdk@0.2.0` either.** 0.2.0 was published
> 2026-07-22 and carries the pre-redeploy addresses, superseded on 2026-07-31, plus an
> `AgentBond.getObligation` tuple missing the `allowanceEpoch` field the deployed contract
> returns. That second one does not throw: decoded with the published ABI, obligation 1 reads
> `status = 1` (Active) when the chain says `2` (Released). 0.3.0 was published 2026-08-09 and
> 0.2.0 is deprecated on the registry, so a plain `npm i bondwire-sdk` now resolves to 0.3.0 and
> asking for 0.2.0 prints a warning. Verified the same day against a tarball pulled from the
> registry into an empty npm cache: `getObligation(1)` → `status: 'Released'`, 1.5 USDC.

## 10-line integration

An agent posts a bond, then gets streamed paid by the second:

```js
import { ethers } from "ethers";
import { Bondwire } from "./bondwire.js";

const agent  = new ethers.Wallet(process.env.AGENT_KEY, Bondwire.provider());
const arc    = new Bondwire(agent);

await arc.bond("5");                                  // post 5 USDC of skin in the game
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
| `bond(amount)` | Post / top up your bond (approves USDC for you). |
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
arbiter keep everyone honest. Try it live: [bonded verifier dApp](https://bondwire.dev/bonded-verifier/).

| Method | What it does |
|---|---|
| `commit({ verifier, beneficiary, amount, ... })` | Escrow USDC behind a verified outcome → `{ id, receipt }` (approves USDC for you, safe defaults for window/bond/deadline). |
| `resolveCommitment(id, passed)` | *(verifier)* Post the verdict. |
| `challengeCommitment(id)` | Dispute a verdict inside the window (escrows the challenge bond). |
| `arbitrateCommitment(id, overturn)` | *(arbiter)* Uphold or overturn a challenged verdict. |
| `finalizeCommitment(id)` | Settle after the window; routes stake, slice and bonds. |
| `commitment(id)` | Decoded state: status, outcome, amounts, windows. |

`commit()` sizes the verifier slice for you. Calling `CommitStakeV2` directly, use
`recommendedSlice(amount, feeDeposit, arbiterFee)` — both fee legs are separate arguments and
the result always clears the `slice > amount + feeDeposit + arbiterFee` gate that `create`
enforces. See [VERIFIER_ECONOMICS §4](../VERIFIER_ECONOMICS.md).

`commit()` also derives the time parameters. Calling `create` directly, note that `deadline`,
`challengeWindow` and `arbiterDeadline` are capped by `MAX_DEADLINE_HORIZON` (90 days),
`MAX_CHALLENGE_WINDOW` (30 days) and `MAX_ARBITER_DEADLINE` (30 days): the staker picks them
but the verifier's locked bond pays for them, so they cannot run away.

### Agent Passport, portable reputation

```js
const pass = await arc.passport("0xAgent...");
// { score: 55, tier: "Established", bond: { usdc: "37.0" }, reliability: 0.8,
//   obligations: { taken: 6, done: 4, slashed: 1, active: 1 }, slashedTotal: {...} }
```

Money backed reputation recomputed live from AgentBond in one Multicall3 round trip.
Same math as the hosted [Agent Passport](https://bondwire.dev/agent-passport/):
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
AgentBond      0x4383Ea48837eF7e60fC22BD67945BCBf0551702c
StreamPay      0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262
CommitStakeV2  0x548532aa4B59598188D49b3e74Fdf27aaE127bb6
```

The RPC is a default, not a requirement. Set `ARC_RPC` to use your own Arc endpoint, which is
what to do if you are behind a proxy or the public one is throttling:

```sh
ARC_RPC=https://arc-rpc.example.com node sdk/test.js
```

`sdk/test.js` reads the live chain on purpose, so it needs an endpoint it can reach. Its first
test is a preflight that fails with that diagnosis rather than letting the three chain-reading
tests fail as if the SDK had drifted. The offline test runs on its own with
`node --test-name-pattern units sdk/test.js`.


> Testnet only. Not audited for production; do not point this at mainnet funds.

MIT.
