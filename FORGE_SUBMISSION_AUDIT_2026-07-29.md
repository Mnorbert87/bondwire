# Bondwire — pre-submission audit (fresh eyes)

**Verdict: LEADHATÓ — zero blocking findings.**

Target: `github.com/Mnorbert87/bondwire`, measured on a **fresh clone of the public repo**, HEAD
`b784bb8`. Every claim below has the command that produced it. Where I could not measure, I say so.

---

## Methodology note the task asked for, and where it could not be met

The brief said *"az evm MCP-vel merd, ne cast-tal"*. **For Arc that is not possible, and I measured
why rather than asserting it:**

```
mcp__evm__get_chain_info(network: "5042002")  -> Error: Unsupported network: 5042002
mcp__evm__get_supported_networks()            -> 80+ networks listed, Arc is not among them
```

So the Arc-side measurements below use the public RPC (`cast`) and the Blockscout explorer API. The
one non-Arc transaction in the docs (the Base Sepolia CCTP burn) **was** measured with the evm MCP,
where it works. This is a limitation of the tool, not a shortcut.

---

## 1. Secret leakage — PASS

Full history, not just the worktree:

| Check | Command | Result |
|---|---|---|
| Burner private key anywhere in history | `git grep <pk> $(git rev-list --all)` | **0 hits** |
| `.env` / `.key` / wallet / keystore ever added | `git log --all --diff-filter=A --name-only` | **0 files** |
| PEM / mnemonic / `ghp_` / `sk-` / `AKIA` patterns | `git grep -IiE … $(git rev-list --all)` | **0 hits** |

---

## 2. Test counts vs. documented claims — PASS

Run on the fresh public clone, four separate `forge test` invocations:

| Project | Measured | README claims | Match |
|---|---|---|---|
| agent-bond | **32** passed, 0 failed, 0 skipped | 32 | ✅ |
| stream-pay | **25** passed, 0 failed, 0 skipped | 25 | ✅ |
| commit-stake | **28** passed, 0 failed, 0 skipped | 28 | ✅ |
| commit-stake-v2 | **102** passed, 0 failed, 0 skipped | 102 | ✅ |
| **total** | **187** | deck: 187 | ✅ |

The fuzz and invariant columns, recounted on the fresh clone by function name (not by file):

| Project | `testFuzz_` fns | README | `invariant_` fns | README |
|---|---|---|---|---|
| agent-bond | 5 | 5 ✅ | 4 | 4 ✅ |
| stream-pay | 5 | 5 ✅ | 3 | 3 ✅ |
| commit-stake | 6 | 6 ✅ | 4 | 4 ✅ |
| commit-stake-v2 | 7 | 7 ✅ | 5 | 5 ✅ |

**The `b784bb8` correction holds.** All eight cells now match measurement.

---

## 3. On-chain verification — PASS

**Deployment table addresses** (`cast code` + `usdc()` getter):

| Contract | Address | Bytecode | `usdc()` |
|---|---|---|---|
| CommitStakeV2 | `0x1f1CA31b…698CA9` | 13,619 B | `0x3600…0000` ✅ |
| StreamPay | `0x505739d3…382450` | 4,912 B | `0x3600…0000` ✅ |
| AgentBond | `0xB9b4d476…dBf8e0` | 5,218 B | `0x3600…0000` ✅ |

All three live, none empty, all wired to Arc's native USDC.

**Transactions referenced in README / JUDGES / SHOWCASE: 13 total, 13 verified.**
- 12 on Arc: `status = 0x1` (four via `cast receipt`, eight via the Blockscout
  `gettxreceiptstatus` endpoint after the RPC started rate-limiting).
- 1 on Base Sepolia (`0x6232b181…25d8`, the CCTP `depositForBurn`): `status: success` via the evm
  MCP. It correctly returns nothing on Arc because it is not an Arc transaction, and the docs label
  it as Base Sepolia.

**A burn amount claim, checked against the log rather than taken on trust:** the docs state a
1.45 USDC overturn burn. Decoding the `Transfer` events of `0x97f31e7a…c45435` shows a transfer of
**1.450000 USDC** to `0x…dEaD`. The claim is exact.

**A methodological note on my own first attempt:** my initial address sweep grepped 40-hex strings
out of the docs and flagged ten "empty" addresses. Those were the first 40 characters of 64-character
transaction hashes — a false alarm I created myself. Re-measured against the deployment table only.

---

## 4. Over-claim hunt — PASS, with the scoping verified by byte-diff

**The "exact match" claim is correctly scoped, and I proved it rather than reading it.** Recompiled
each contract from the fresh clone and diffed against the on-chain runtime:

| Contract | Total diff | Metadata trailer diff | Reading |
|---|---|---|---|
| CommitStakeV2 | 480 | **0** | genuine exact match; the 480 are the three constructor-set immutables |
| AgentBond | 71 | **61** | metadata drift — recompile does not reproduce the trailer |
| StreamPay | 71 | **61** | same |

The README says precisely this: exact match for CommitStakeV2, and for the other two *"their runtime
body is identical to this repo (only the constructor-set immutable addresses differ), but their
metadata hash reflects an earlier compilation state."* **Measured, and the wording is accurate.** The
two remaining generic mentions of "exact-match" I found are both in CommitStakeV2 context.

Other claims checked:

| Claim | Measured | Verdict |
|---|---|---|
| "5 Halmos symbolic proofs" | `grep -c "    function check_"` in `SymbolicSpec.t.sol` → **5** | ✅ |
| deck "187 Solidity tests" | measured total 187 | ✅ |
| "Testnet demo only… not audited for production" disclaimer | present, README line 34 | ✅ honest |
| Live demo URLs (hub, bonded-verifier, use-case) | HTTP **200** each | ✅ |
| Deck files present in the public repo | `deck.html` 23,723 B and `BONDWIRE_DECK.pdf` 600,652 B are committed | ✅ |

---

## 5. Frontend config vs. docs — PASS

Fetched the deployed `bonded-verifier` page and compared to the repo:

| | Live page | Repo | Docs |
|---|---|---|---|
| chainId | `5042002` / `0x4cef52` | `5042002` | `5042002` ✅ |
| CommitStakeV2 | `0x1f1CA31b…698CA9` | same | same ✅ |
| AgentBond | `0xB9b4d476…dBf8e0` | same | same ✅ |
| RPC | `https://rpc.testnet.arc.network` | same | same ✅ |

No stale address, no wrong chainId, no hardcoded secret.

---

## What I did NOT measure (stated, not guessed)

- **The mutation campaign was not re-run.** The docs claim 100% revert-class kill; verifying that
  means re-executing the whole campaign, which I did not do in this pass. The claim is therefore
  unverified-in-this-audit, not disproven.
- **Halmos was not re-executed.** I counted the five `check_` functions; I did not run the solver.
- **The 84.5% mutation score** in `SUBMISSION_DOCUMENT.html` is likewise not re-measured.
- **The PDF's rendered content** was not read page by page; I checked that the file exists and that
  its source `deck.html` states 187.
- **Two accepted-not-fixed threat-model items** (§9 blacklist DoS, §10 unbounded time params) remain
  open by design and are documented as such. I did not re-audit them here; they were audited
  separately earlier today.
- The AgentBond and StreamPay **metadata path-leak** (`/Users/…` in the verified metadata) still
  exists and is not fixable on the same address due to the Blockscout lock. Low-severity
  information disclosure; the submission does not depend on it.

---

## Summary

Zero blocking findings. Every number the submission states that I could measure, I measured, and it
matched. The one place the docs make a narrow claim about verification, the byte-diff confirms both
the claim and its deliberate limits.
