# For Judges — verify this in 2 minutes

Everything below is checkable yourself. No screenshots to trust, no "deployed, promise."

## If you have 30 seconds, look at these three things

1. **The burn is real.** Click the first tx link below. You'll see a USDC `Transfer` of **1.45 USDC** straight to `0x…dEaD` — the surplus-burn that makes verifier-collusion unprofitable, *actually happening on-chain*.
2. **The code is verified.** `CommitStakeV2` at [`0x1f1CA31b…698CA9`](https://testnet.arcscan.app/address/0x1f1CA31bC36a95a3909628F1bA97970E20698CA9) is **Blockscout exact-match verified** — the source in this repo *is* the deployed bytecode.
3. **The suite is green.** One copy-paste command below runs **79 tests** (unit + adversarial + cold-audit + fuzz + 10k-run invariants + symbolic spec). All green, on your machine.

---

## 1. See the mechanism work — two on-chain burns (~30s)

The core anti-collusion device: when a verifier's verdict is overturned, the harmed party is paid exactly its `damage`, and the **surplus (`slice − damage`) is burned to `0x…dEaD`** — so no challenger is ever over-rewarded and a colluding arbiter can never recapture the slice. Two live artifacts prove it fired:

| What | Burned | Transaction (click → find the `Transfer` to `…dEaD`) |
|---|---|---|
| **Overturn burn** (surplus after `damage` paid) | **1.45 USDC** | [`0x97f31e7a…c45435`](https://testnet.arcscan.app/tx/0x97f31e7a590af4ecc2f88c8f34943fe95be41391c9c3a4e3895d9a3d13c45435) |
| **Liveness burn** (whole slice, deadlock fail-closed) | **1.50 USDC** | [`0x7bf59845…4aa6bd`](https://testnet.arcscan.app/tx/0x7bf59845abadf3847061b5997e96e303a959d722c8a7283b160b3c82b14aa6bd) |

**What to look for:** in each tx, the USDC token (`0x3600…0000`, the 6-decimal ERC-20) `Transfer` event with **recipient `0x000000000000000000000000000000000000dEaD`**. That address is owned by no one — the value is gone, by construction, not parked in a treasury.

---

## 2. Cross-chain capital onboarding — CCTP V2 + Bridge Kit (~30s)

An agent funded on another chain still posts its bond on Arc. With Circle's **Bridge Kit** (the App Kit suite, CCTP V2 — Arc is a *native* Bridge-Kit chain, `ArcTestnet`, domain `26`), `1 USDC` is bridged **Base Sepolia → Arc** and deposited straight into AgentBond. All confirmed (`status 1`):

| Step | Chain | Tx |
|---|---|---|
| `depositForBurn` | Base Sepolia | [`0x6232b1…25d8`](https://sepolia.basescan.org/tx/0x6232b181d8f3234162f8d617ba5a5215b62eb9c902e5f70b0f6312cb0e8725d8) |
| `receiveMessage` (mint) | Arc | [`0xcae264…26d2b`](https://testnet.arcscan.app/tx/0xcae2649abaee2544144a7cedc73b38915ef62d2fce545b566168f30735326d2b) |
| `AgentBond.deposit` | Arc | [`0xf17ca3…96bc`](https://testnet.arcscan.app/tx/0xf17ca3a4004b8b969cdb633d1d7f42703a7618f34a56092fc1e9b82eba5f96bc) |

Effect: AgentBond bond `36 → 37 USDC` — the bridged dollar is now slashable collateral. Runnable: [`cctp-demo/`](./cctp-demo/) (`npm run onboard`), full transcript [`cctp-demo/SAMPLE_RUN.md`](./cctp-demo/SAMPLE_RUN.md). One `kit.bridge({ from:'Base_Sepolia', to:'Arc_Testnet', config:{ transferSpeed:'FAST' } })` call; a raw-CCTP-V2 (no-SDK) reference flow ships alongside.

---

## 3. On-chain agent identity — ERC-8004 (~30s)

Both demo agents hold a real identity NFT in Arc's official ERC-8004 `IdentityRegistry` ([`0x8004A818…BD9e`](https://testnet.arcscan.app/address/0x8004A818BFB912233c491871b3d84c89A494BD9e)):

| Agent | tokenId | `register` tx |
|---|---|---|
| **Aiden** (AI research agent) | `471762` | [`0x8afedd…8cfa2`](https://testnet.arcscan.app/tx/0x8afedd30f718a82752811f6daab1c41d81e215eb0020e4eca76db0379888cfa2) |
| **Arc Stack Verifier** (bonded verifier) | `471763` | [`0xe2eb9b…cdae`](https://testnet.arcscan.app/tx/0xe2eb9b94cd1d4afe292f1bf9d4b859b122c96d6ca8f4a49a8d88c78bf86bcdae) |

Full surface, not just `register`:
- **Reputation:** a *distinct* counterparty left a real `ReputationRegistry.giveFeedback` for Aiden (value `5`, tags `research-quality` / `on-time-delivery`): [`0x775a67…5884`](https://testnet.arcscan.app/tx/0x775a67b9d30017d3c60c43c2b82b5a491ae9a45222c8a6de3fe23c6f195f5884).
- **Operational wallet:** `IdentityRegistry.setAgentWallet` binds a separate execution wallet to Aiden via EIP-712 (signed by that wallet, owner submits): [`0x2910b8…4344`](https://testnet.arcscan.app/tx/0x2910b8d8eaee2cd5c6270a5348d1b7e7e79499d03c752d4f8554d0ba53084344) — custody (NFT owner) and execution (agent wallet) cleanly separated.

**Positioning:** ERC-8004 is the *identity / job* layer; this stack adds the missing *economic-assurance* layer — a bonded, slashable verifier, §7a slash routing, streaming pay. We **complement** ERC-8004, we don't duplicate it.

---

## 4. Reproduce the 79-test suite (~2 min)

Exactly what CI runs ([green run](https://github.com/Mnorbert87/arc-agentic-stack/actions/workflows/test.yml)). Needs [Foundry](https://getfoundry.sh) installed — nothing else.

```bash
git clone https://github.com/Mnorbert87/arc-agentic-stack
cd arc-agentic-stack/contracts/commit-stake-v2
git clone --depth 1 --branch v1.16.1 https://github.com/foundry-rs/forge-std lib/forge-std
forge test -vv
```

Expected last line:

```
Ran 6 test suites: 79 tests passed, 0 failed, 0 skipped (79 total tests)
```

The suite compiles the **real** sibling primitives (`agent-bond`, `stream-pay`) from source — no vendored copies, no drift. The two siblings each have their own green suite (32 + 25 tests); run `forge test` in their folders the same way if you want them too.

---

## 5. Deployments — Arc Testnet (chain `5042002`)

| Contract | Address (→ explorer) | Verified |
|---|---|---|
| **CommitStakeV2** — the mechanism | [`0x1f1CA31bC36a95a3909628F1bA97970E20698CA9`](https://testnet.arcscan.app/address/0x1f1CA31bC36a95a3909628F1bA97970E20698CA9) | exact-match ✅ |
| AgentBond — trust layer | [`0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0`](https://testnet.arcscan.app/address/0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0) | ✅ |
| StreamPay — settlement layer | [`0x505739d33D85AD85D0f9eeE64856309782382450`](https://testnet.arcscan.app/address/0x505739d33D85AD85D0f9eeE64856309782382450) | ✅ |

- **RPC:** `https://rpc.testnet.arc.network` · **Explorer:** `https://testnet.arcscan.app`
- **USDC** is native gas on Arc; value transfers use the 6-decimal ERC-20 at `0x3600…0000`.
- **Live frontend (no wallet needed to browse):** https://mnorbert87.github.io/arc-agentic-stack/

---

## 6. Three claims, each backed by something re-runnable

1. **Bonded verifier, recursive trust.** The verifier posts its own `AgentBond` and grants CommitStakeV2 a revocable slash allowance — trusting the result reduces to trusting a party with on-chain skin in the game. *(See `AgentBond` source + the verifier flow in [VERIFIER_ECONOMICS.md](./VERIFIER_ECONOMICS.md).)*
2. **A real HIGH finding, closed by full accounting — not patched over.** A 4th-gate cold adversarial audit found an uncapped `arbiterFee` could feed `damage` until it equalled the slice, zeroing the surplus-burn. The fix folds `arbiterFee` into the slice-sizing rule so `surplus = slice − damage` stays **strictly positive by construction**. Found by counting it through, closed by counting it through. *([TEST_AUDIT.md](./contracts/commit-stake-v2/TEST_AUDIT.md))*
3. **Symbolically verified, proven live.** Halmos proves solvency, surplus-positivity, no-double-pay and the fee-residue bound **for all inputs**; the two burns in §1 show it firing on-chain. *([HALMOS_VERIFICATION.md](./contracts/commit-stake-v2/HALMOS_VERIFICATION.md))*

## Four-layer audit trail (one repo, beside a spec that was already public)

| Layer | Document | What it proves |
|---|---|---|
| Symbolic | [HALMOS_VERIFICATION.md](./contracts/commit-stake-v2/HALMOS_VERIFICATION.md) | solvency / surplus-positivity / no-double-pay, all inputs |
| Static | [STATIC_ANALYSIS.md](./contracts/commit-stake-v2/STATIC_ANALYSIS.md) | zero new vulns; every flag triaged, by-design items annotated in-source |
| Mutation | [MUTATION_TESTING.md](./contracts/commit-stake-v2/MUTATION_TESTING.md) | 100% revert-class kill; survivors triaged equivalent / invariant-caught |
| Gas | [GAS_PROFILE.md](./contracts/commit-stake-v2/GAS_PROFILE.md) | full slash+burn path ~0.008 USDC over a plain finalize |

> Full narrative and design rationale: [README.md](./README.md). This file is the fast path; the README is the depth.
