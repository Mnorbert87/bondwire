# Deploy provenance

**What this file is for.** The README says the three live contracts are "fully verified on the
explorer and exact-match". That is the explorer's claim, not ours. An explorer checkmark is a
third party's assertion; it is not a proof you can re-run. This file states, contract by contract,
**what we can prove locally and what we cannot** — because one of the three has a real local proof
and two do not, and the repo did not previously say so.

Everything below was measured on **2026-09-30** at `HEAD = faef469`, offline, with no network
access and no private key. Nothing here is a claim about the state of the chain today.

Tooling used for every measurement: `forge 1.7.1` (`4072e48`), `solc 0.8.24+commit.e11b9ed9`,
optimizer on, `runs = 200` (from each project's `foundry.toml`).

---

## Summary

| Contract | Address | Local deploy record | Proof strength |
|---|---|---|---|
| CommitStakeV2 | `0x548532aa4B59598188D49b3e74Fdf27aaE127bb6` | yes, a Foundry broadcast record | **byte-exact**: the deploy transaction's init code equals this source's compiled creation code plus the three constructor arguments |
| AgentBond | `0x4383Ea48837eF7e60fC22BD67945BCBf0551702c` | **none** | **explorer verification only.** No local artifact ties this address to this source |
| StreamPay | `0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262` | **none** | **explorer verification only.** No local artifact ties this address to this source |
| CommitStake (legacy) | `0xc307d9287707Ba04c03Dd653b4457E949129A9a2` | not in this repo; a record exists in a separate unpublished working tree | executable code matches this source; see below |

And one thing that applies to all four: **`broadcast/` is in `.gitignore`.** A third party who
clones this repository receives **zero** deploy records, including the good one. The CommitStakeV2
proof described below currently exists only on the maintainer's machine. That is why the essential
evidence — transaction hash, block, constructor arguments, code hashes — is transcribed into this
file, so the document itself is checkable by someone who only has the public repo and a node.

---

## Method

Two different things get confused with each other, so both are named explicitly here.

**Runtime code comparison** (what an explorer does) is awkward for these contracts: all four have
constructor-set `immutable` values, which solc patches into the runtime code at deploy time. A
freshly compiled `deployedBytecode` therefore carries zeroed placeholders where the deployed copy
carries real addresses (`AgentBond` and `StreamPay` have 5 such slots, `CommitStakeV2` has 27).
Comparing runtime code naively will always fail, and comparing it immutable-aware requires
trusting whoever did the patching.

**Creation code comparison** avoids all of that. A `CREATE` transaction's `input` is exactly
`creation_code || abi.encode(constructor args)`. Both halves are reproducible offline:

1. `forge build --offline` in the project directory.
2. Read `bytecode.object` from `out/<Name>.sol/<Name>.json` — this is the creation code.
3. Read the `CREATE` transaction's `input` from the broadcast record.
4. Assert `input.startswith(creation_code)`.
5. Decode the remainder as 32-byte ABI words — these are the constructor arguments, and they must
   be the addresses the repo documents.

Step 4 either holds byte for byte or it does not. There is no partial credit.

### A note on the metadata trailer

solc appends a CBOR trailer to the code: the IPFS hash of the source *metadata*, plus the compiler
version. In all four projects this trailer is 51 bytes of CBOR plus a 2-byte length, so 53 bytes.
The trailer changes when the source *text* changes — a comment, whitespace, an import path — even
when the compiled instructions are identical. So two hashes are published below for each contract:

- **`keccak256(executable)`** — the creation code with the 53-byte trailer removed. This is the
  code that actually runs. It is metadata-independent.
- **`keccak256(init)`** — the full creation code plus constructor arguments, i.e. exactly what the
  deploy transaction's `input` should be. This is trailer-sensitive.

---

## CommitStakeV2 — proven locally

Address `0x548532aa4B59598188D49b3e74Fdf27aaE127bb6`.

Broadcast record: `contracts/commit-stake-v2/broadcast/Deploy.s.sol/5042002/run-latest.json`
(present in the working tree, **not committed** — see the `.gitignore` note above).

```
chain id            5042002
deploy tx           0x2d96424db15aabf2ff68a0d8cbdbecdfe2be2a61f737b8a74cc59c820f0df27f
block               56240096  (0x35a27e0)
receipt status      0x1
broadcast timestamp 1786345642418  ->  2026-08-10 07:07:22 UTC
script run at commit 3122e86
```

Measurement, re-run today on this source:

```
deploy tx input            15612 bytes
local creation code        15516 bytes
prefix match               EXACT
remainder                  96 bytes = 3 ABI words:
    usdc       0x3600000000000000000000000000000000000000   (Arc USDC predeploy)
    agentBond  0x4383Ea48837eF7e60fC22BD67945BCBf0551702c
    streamPay  0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262

keccak256(deploy tx input)        0x6b496b23c11452eacd011a7cbaa35f23e96628851d968bc1677ccd1e577907f7
keccak256(local creation || args) 0x6b496b23c11452eacd011a7cbaa35f23e96628851d968bc1677ccd1e577907f7
```

The two hashes are equal. This is the strongest provenance statement in the project and it does
not rest on anyone's checkmark: the source in this repository compiles to the code that was
deployed, and the three addresses it was wired to are the three addresses documented in the README.

Reference hashes for this source:

```
keccak256(executable)  0x07ff555a02f00e659c0be04f0723021d51a5e8d6f360123415338c459257fcfc   (15463 bytes)
keccak256(init)        0x6b496b23c11452eacd011a7cbaa35f23e96628851d968bc1677ccd1e577907f7   (15612 bytes)
```

---

## AgentBond — no local proof

Address `0x4383Ea48837eF7e60fC22BD67945BCBf0551702c`. Per `CHANGELOG.md` this is the 2026-07-31
redeploy.

**There is no deploy record for this address.** Not in this repository, not in the separate
unpublished working tree, not in the offsite backup of that tree. This was checked by sweeping
every Foundry `broadcast/` directory on the machine for a `CREATE` transaction naming this
address; there are none. What exists for this contract is the explorer's verification, and an
explorer's verification is not a proof we can re-run.

What *can* be stated, measured today from this source:

```
solc 0.8.24+commit.e11b9ed9, optimizer runs=200
creation code             6268 bytes
executable (pre-metadata) 6215 bytes
init with 1 ctor arg      6300 bytes   (usdc = 0x3600000000000000000000000000000000000000)

keccak256(executable)  0x118793c6729f54de86f2973920021659900930170c7357e1e5dd20e2f33eee05
keccak256(init)        0xe5eea3ac7e51320aca5797c793ed922d804bcadb04ea8eb5c1a9affd218c8c5a
```

Anyone with a node or an archive-capable explorer can settle this in one step: fetch the `input`
of the transaction that created `0x4383Ea…702c` and hash it. If it equals
`0xe5eea3ac7e51320aca5797c793ed922d804bcadb04ea8eb5c1a9affd218c8c5a`, the deployed instance came
from this exact source text. If only the metadata trailer differs, compare
`keccak256(executable)` instead — that settles whether the same instructions were deployed from a
textually different but semantically identical source. **We have not run that check**, because it
needs network access.

### The nearest local anchor, and why it is not the proof

The unpublished tree does hold one AgentBond record, for a **different, superseded instance**:

```
address    0xa2dddb0aE8b14269C7b908327124bEAd9eaC7216
deployed   2026-07-01
tx         0x675090b2df6f737572b3c6bfe99fe56b35fabbd7374a4588f837d2e8a69e1ca1
commit     22e974a   (a commit of the unpublished tree; not resolvable in this repository)
```

Measured against this source today:

```
executable region (6215 bytes)   BYTE-IDENTICAL
53-byte metadata trailer          differs, in the IPFS source hash only
    local   ...697066735822 1220 eaf418a4bf...   solc marker 0.8.24
    onchain ...697066735822 1220 3cc61e14b5...   solc marker 0.8.24  (identical)
constructor argument              identical: usdc = 0x3600...0000
```

So the instructions this source produces were, at some point, deployed to Arc — just to
`0xa2dd…7216`, not to the live address. This is a genuine anchor for the *source lineage* and it
is worth having on the record. It is **not** a provenance proof for `0x4383Ea…702c`, and this file
does not present it as one.

---

## StreamPay — no local proof

Address `0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262`. Per `CHANGELOG.md`, also the 2026-07-31
redeploy.

**There is no deploy record for this address**, by the same exhaustive sweep described above.
Explorer verification only.

Measured from this source today:

```
solc 0.8.24+commit.e11b9ed9, optimizer runs=200
creation code             5149 bytes
executable (pre-metadata) 5096 bytes
init with 1 ctor arg      5181 bytes   (usdc = 0x3600000000000000000000000000000000000000)

keccak256(executable)  0x33e9f3656027449eaa5e6657544665de91b24019791efad4db11218b71a0f4e4
keccak256(init)        0x7114239439edcab8e9a885be3cedab2c4ae485e780262e8211ffe63dc2fe5022
```

Same one-step check applies: hash the `input` of the creation transaction for `0x6C2Ae6…B262` and
compare. Not run here — no network.

### The nearest local anchor

```
address    0x505739d33D85AD85D0f9eeE64856309782382450
deployed   2026-06-09
tx         0xce67f7d7ef03c2899db810e60a3e18ff239811f8b8f655e418573b102a7770d0
```

`scripts/verify-claims.sh:44` labels this address "StreamPay before 2026-07-31", so it is the live
contract's direct predecessor. Measured against this source today:

```
executable region (5096 bytes)   BYTE-IDENTICAL
53-byte metadata trailer          differs, IPFS source hash only; solc marker identical
constructor argument              identical: usdc = 0x3600...0000
```

Again: an anchor for the source lineage, not a proof for the live address.

---

## CommitStake (legacy) — record exists, but not in this repo

Address `0xc307d9287707Ba04c03Dd653b4457E949129A9a2`, described in `CHANGELOG.md` as the earlier,
simpler contract kept on chain for reference.

A broadcast record for exactly this address exists in the separate unpublished working tree
(deployed 2026-06-08, tx `0x023e348b94d1ca0685ada33c885e958132c5816cc5ba435f8d0b9ec38a6351ab`).
It is not part of this repository. Measured against this source today:

```
creation code                     4722 bytes
executable region (4669 bytes)   BYTE-IDENTICAL
53-byte metadata trailer          differs, IPFS source hash only; solc marker identical
constructor argument              identical: usdc = 0x3600...0000
init with 1 ctor arg              4754 bytes

keccak256(executable)  0xe57520e714adcc762291e6bcfc5fb77d54a6d78f038edb31cb7b709b69f91131
keccak256(init)        0xf55590e2baad1abe1eb8cf96447139fd79ae8561e1ca8db1cf69ead239a24140
```

This is the strongest of the three trailer-only cases, because here the anchor *is* the documented
live legacy address rather than a superseded sibling. What it proves: the same instructions now in
this repository were deployed to `0xc307…a9a2`. What it does not prove: byte-for-byte source-text
identity, since the metadata hash differs.

---

## Scope note on the README

`README.md` currently says of all three live contracts: "recompile this repo and the deployed
runtime matches byte for byte, including the metadata trailer, with only the constructor-set
immutable addresses differing."

For **CommitStakeV2** that statement is backed by the measurement above. For **AgentBond** and
**StreamPay** it is a restatement of what the explorer reports, and nothing in this repository lets
a reader confirm it independently. The sentence should be scoped accordingly. Until it is, treat
this file as the narrower and more accurate statement.

---

## What would close the gap

1. **Commit the broadcast records.** `broadcast/` is gitignored, so the one real proof never ships.
   A committed `broadcast/Deploy.s.sol/5042002/run-latest.json` for CommitStakeV2 would let anyone
   re-run step 4 of the method above with no network at all.
2. **Fetch and record the two missing creation transactions.** For `0x4383Ea…702c` and
   `0x6C2Ae6…B262`, retrieve the creation transaction's `input` from an archive node, compare it to
   the hashes published above, and commit the result — including the case where it does not match.
   This requires network access and was deliberately not done in this pass.
3. **Never deploy without `--broadcast` again**, or the same hole reopens on the next redeploy.

## Reproducing the measurements in this file

```bash
# per project: agent-bond, stream-pay, commit-stake, commit-stake-v2
cd contracts/<project> && forge build --offline
```

```python
import json
from Crypto.Hash import keccak

def kec(hexstr):
    h = keccak.new(digest_bits=256); h.update(bytes.fromhex(hexstr)); return "0x" + h.hexdigest()

art = json.load(open("out/CommitStakeV2.sol/CommitStakeV2.json"))
creation = art["bytecode"]["object"][2:].lower()
runtime  = art["deployedBytecode"]["object"][2:].lower()

# strip the CBOR metadata trailer: last 2 bytes of the runtime code hold its length
trailer_hex = (int(runtime[-4:], 16) + 2) * 2
print("keccak256(executable)", kec(creation[: len(creation) - trailer_hex]))

# and, where a broadcast record exists, compare against the real deploy transaction
rec = json.load(open("broadcast/Deploy.s.sol/5042002/run-latest.json"))
tx  = next(t for t in rec["transactions"] if t["transactionType"] == "CREATE")
onchain = tx["transaction"]["input"][2:].lower()
print("prefix match:", onchain.startswith(creation))
print("ctor args   :", [onchain[i:i+64] for i in range(len(creation), len(onchain), 64)])
```

---

*Measured 2026-09-30, offline, at `HEAD = faef469`. No network, no key, no transaction. Every
"identical" above is a byte comparison that was actually executed; every "unknown" above is
unknown because settling it needs a node, and no node was contacted.*
