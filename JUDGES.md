# For judges: check it yourself in two minutes

Everything here is something you can click or run. I am not asking you to trust a screenshot or a "deployed, promise."

## If you have 30 seconds, look at four things

1. **The burn is real.** Click the first transaction below. You will see a USDC `Transfer` of 1.45 USDC straight to `0x…dEaD`. That is the surplus burn on an **overturned** verdict: whatever is left of the slashed slice is destroyed, so there is nothing for a colluding pair to split. It actually happened on chain. It is an overturn-branch device, not a general anti-collusion guarantee — on an *uphold* nothing burns, and THREAT_MODEL §11 states the path where that matters.
2. **The code is verified.** `CommitStakeV2` at [`0xf3457ABf…af1474`](https://testnet.arcscan.app/address/0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474) is Blockscout exact-match verified. The source in this repo is the deployed bytecode, byte for byte.
3. **An agent can drive it without a UI.** [`mcp/`](./mcp/) is an MCP server: an LLM agent checks a
   counterparty's Agent Passport and opens a bonded escrow from its own tool loop. Every
   value-moving tool is quote-before-execute, so nothing signs without an explicit confirmation.
4. **The tests pass.** One copy-paste command runs 125 tests (unit, adversarial, cold-audit, edge-mutation, exploit-audit, fuzz, and 10k-run invariants). They pass on your machine, not just mine.

The honest version of what we found in our own code, including what is still open, is in
[AUDIT_SUMMARY.md](./AUDIT_SUMMARY.md).

---

## 1. See the mechanism fire: two on-chain burns (~30s)

I wanted to watch the overturn burn work, not claim it works. When a verifier's verdict gets overturned, the harmed party is paid exactly its `damage`, and whatever is left of the slashed slice (`slice − damage`) goes to `0x…dEaD`. A challenger can never be over-rewarded, and on that branch a colluding arbiter can never claw the slice back. Two transactions show it:

| What | Burned | Transaction (open it, find the `Transfer` to `…dEaD`) |
|---|---|---|
| Overturn burn (surplus left after `damage` is paid) | 1.45 USDC | [`0xf46f062d…3e9d1d`](https://testnet.arcscan.app/tx/0xf46f062d8ff0be20cccc35bee1faf321f8418be7b7f02045efeac2fb0f3e9d1d) |
| Liveness burn (the whole slice, when a dispute deadlocks) | 1.50 USDC | [`0xae25f951…b5a364`](https://testnet.arcscan.app/tx/0xae25f95183bd6af798cf1f6a82222aeca35eae73553575449a403c8b03b5a364) |

Open either one and look for the USDC `Transfer` (the 6-decimal ERC-20 at `0x3600…0000`) with recipient `0x000000000000000000000000000000000000dEaD`. Nobody owns that address. The profit is just gone, by construction, not sitting in some treasury.

---

## 2. Bring capital in from another chain: CCTP V2 + Bridge Kit (~30s)

An agent does not have to start its life on Arc. I took 1 USDC on Base Sepolia, bridged it to Arc with Circle's Bridge Kit (CCTP V2 underneath), and deposited it straight into AgentBond. Arc is already in Bridge Kit's chain list (`ArcTestnet`, CCTP domain 26), so the cross-chain part is one `kit.bridge()` call. Three transactions, all `status 1`:

| Step | Chain | Transaction |
|---|---|---|
| `depositForBurn` | Base Sepolia | [`0x6232b1…25d8`](https://sepolia.basescan.org/tx/0x6232b181d8f3234162f8d617ba5a5215b62eb9c902e5f70b0f6312cb0e8725d8) |
| `receiveMessage` (the mint) | Arc | [`0xcae264…26d2b`](https://testnet.arcscan.app/tx/0xcae2649abaee2544144a7cedc73b38915ef62d2fce545b566168f30735326d2b) |
| `AgentBond.deposit` | Arc | [`0x0eb3f7…1b3c`](https://testnet.arcscan.app/tx/0x0eb3f7e0fa6e52c0df47610de7e3155a250e7ac6ab41b6f4c2b5c93042b11b3c) |

The two bridge legs above are from the original run and are unaffected by the 2026-07-31 redeploy (they are Base Sepolia and CCTP transactions, not Bondwire ones). The `AgentBond.deposit` leg was re-executed against the redeployed AgentBond so every Bondwire link on this page points at a live contract.


After it landed, the agent's bond went from 3 to 4 USDC. Open the `AgentBond.deposit` transaction above and read its `Deposited` event: 1 USDC in, 4 USDC of bond out. The original run moved 36 to 37, but that was on the pre-redeploy AgentBond, and this leg was re-executed against the live one so the link and the number agree. A dollar that started on a different chain is now slashable collateral on Arc. You can run the whole thing yourself: `cd cctp-demo && npm run onboard`. Every hash is in [`cctp-demo/SAMPLE_RUN.md`](./cctp-demo/SAMPLE_RUN.md). I also left a raw CCTP version next to it (`run.sh`, no SDK) in case you want to see what Bridge Kit does under the hood.

---

## 3. Real on-chain identity: ERC-8004 (~30s)

Both demo agents have an identity NFT in Arc's ERC-8004 `IdentityRegistry` ([`0x8004A818…BD9e`](https://testnet.arcscan.app/address/0x8004A818BFB912233c491871b3d84c89A494BD9e)):

| Agent | tokenId | `register` transaction |
|---|---|---|
| Aiden, the research agent | 471762 | [`0x8afedd…8cfa2`](https://testnet.arcscan.app/tx/0x8afedd30f718a82752811f6daab1c41d81e215eb0020e4eca76db0379888cfa2) |
| The bonded verifier | 471763 | [`0xe2eb9b…cdae`](https://testnet.arcscan.app/tx/0xe2eb9b94cd1d4afe292f1bf9d4b859b122c96d6ca8f4a49a8d88c78bf86bcdae) |

I did not stop at `register`. A different wallet left actual feedback for Aiden through `ReputationRegistry.giveFeedback`, a 5, tagged `research-quality` and `on-time-delivery`: [`0x775a67…5884`](https://testnet.arcscan.app/tx/0x775a67b9d30017d3c60c43c2b82b5a491ae9a45222c8a6de3fe23c6f195f5884). And `setAgentWallet` binds a separate execution wallet to Aiden, signed by that wallet over EIP-712: [`0x2910b8…4344`](https://testnet.arcscan.app/tx/0x2910b8d8eaee2cd5c6270a5348d1b7e7e79499d03c752d4f8554d0ba53084344). So the key that owns the identity and the key that does the work are not the same key.

On where this sits: ERC-8004 answers who an agent is and what job it took on. It does not say what happens to the money when the agent lies. That is the gap I filled. I am not rebuilding ERC-8004, I am bolting an economic layer onto it.

---

## 4. Run the 125-test suite (~2 min)

This is exactly what CI runs ([the green run is here](https://github.com/Mnorbert87/bondwire/actions/workflows/test.yml)). You need [Foundry](https://getfoundry.sh) and nothing else.

```bash
git clone https://github.com/Mnorbert87/bondwire
cd bondwire/contracts/commit-stake-v2
git clone --depth 1 --branch v1.16.1 https://github.com/foundry-rs/forge-std lib/forge-std
forge test -vv
```

The last line should read:

```
Ran 9 test suites: 125 tests passed, 0 failed, 0 skipped (125 total tests)
```

The suite compiles the real `agent-bond` and `stream-pay` from source, not vendored copies, so there is no drift between what is tested and what is deployed. Each of those two has its own green suite (51 and 25 tests). Run `forge test` in their folders the same way if you want them too.

---

## 5. Deployments on Arc Testnet (chain `5042002`)

| Contract | Address (opens the explorer) | Verified |
|---|---|---|
| CommitStakeV2, the mechanism | [`0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474`](https://testnet.arcscan.app/address/0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474) | exact-match ✅ |
| AgentBond, the trust layer | [`0x4383Ea48837eF7e60fC22BD67945BCBf0551702c`](https://testnet.arcscan.app/address/0x4383Ea48837eF7e60fC22BD67945BCBf0551702c) | exact-match ✅ |
| StreamPay, the settlement layer | [`0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262`](https://testnet.arcscan.app/address/0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262) | exact-match ✅ |

\* All three contracts are **fully verified on the explorer and exact-match**: recompile this repo and the deployed runtime matches byte for byte, including the metadata trailer, with only the constructor-set immutable addresses differing. This is the redeploy of 2026-07-31; the earlier deployment had AgentBond and StreamPay served as partial matches out of Blockscout's bytecode database, which is exactly what the redeploy fixed.

- RPC: `https://rpc.testnet.arc.network`. Explorer: `https://testnet.arcscan.app`.
- USDC is the native gas token on Arc. Value transfers use the 6-decimal ERC-20 at `0x3600…0000`.
- The live frontend (browse it, no wallet needed) is at https://bondwire.dev/.

---

## 6. Three claims, each with something you can re-run

1. The verifier has its own money on the line. It posts an `AgentBond` and grants CommitStakeV2 a revocable slash allowance, so trusting its verdict comes down to trusting a party that gets slashed if it is wrong. The source and the full flow are in [VERIFIER_ECONOMICS.md](./VERIFIER_ECONOMICS.md).
2. I broke my own contract, then fixed it by counting it through. A cold adversarial audit (the 4th gate) found that an uncapped `arbiterFee` could push `damage` all the way up to the slice, which zeroes out the surplus burn. The fix folds `arbiterFee` into the slice-sizing rule, so `surplus = slice − damage` stays strictly positive no matter the inputs. The whole find-and-fix is written up in [TEST_AUDIT.md](./contracts/commit-stake-v2/TEST_AUDIT.md).
3. The hard properties are proven, not just tested. Halmos proves solvency, surplus-positivity on both slash branches, split conservation, and the fee-residue bound for all inputs. The two burns in section 1 are the same properties firing on chain. See [HALMOS_VERIFICATION.md](./contracts/commit-stake-v2/HALMOS_VERIFICATION.md).

## The audit trail, all in this repo

| Layer | Document | What it covers |
|---|---|---|
| Symbolic | [HALMOS_VERIFICATION.md](./contracts/commit-stake-v2/HALMOS_VERIFICATION.md) | solvency, surplus-positivity, split conservation, fee residue, for all inputs |
| Static | [STATIC_ANALYSIS.md](./contracts/commit-stake-v2/STATIC_ANALYSIS.md) | zero new vulnerabilities, every flag triaged, by-design items suppressed in a triage DB |
| Mutation | [MUTATION_TESTING.md](./contracts/commit-stake-v2/MUTATION_TESTING.md) | 100% of the revert-class mutants killed, survivors triaged |
| Gas | [GAS_PROFILE.md](./contracts/commit-stake-v2/GAS_PROFILE.md) | the full slash-and-burn path costs about 0.008 USDC over a plain finalize |

If you want the long version with the design reasoning, that is in [README.md](./README.md). This file is the fast path.
