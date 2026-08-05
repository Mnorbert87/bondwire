// ABI drift guard for the hand-written SDK ABIs.
//
// WHY THIS EXISTS: the SDK declares its own human-readable ABI fragments instead of importing
// the compiled artifacts. That copy silently rots. On 2026-07-29 the AgentBond `Obligation`
// struct gained an `allowanceEpoch` field BEFORE `status`; the Solidity-side interface copy in
// CommitStakeV2 was updated, the SDK copy was not, so `getObligation(...).status` decoded the
// epoch number instead of the status — a live locked obligation reads back as "Released", and
// the passport's slash counters read from that same field.
//
// This test compares every SDK fragment against the compiled artifact and fails on any drift.
// It needs no chain and no key: it only reads out/*.json and compares type signatures.
//
// Run: node sdk/test.abi-conformance.mjs
import { ethers } from "ethers";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { AGENT_BOND_ABI, STREAM_PAY_ABI, COMMIT_STAKE_ABI } from "./bondwire.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");

const ARTIFACTS = {
  AgentBond: "contracts/agent-bond/out/AgentBond.sol/AgentBond.json",
  StreamPay: "contracts/stream-pay/out/StreamPay.sol/StreamPay.json",
  CommitStakeV2: "contracts/commit-stake-v2/out/CommitStakeV2.sol/CommitStakeV2.json",
};

let failed = 0;
const ok = (c, msg, detail = "") => {
  console.log(`${c ? "  ✓" : "  ✗ FAIL"} ${msg}${detail ? "  " + detail : ""}`);
  if (!c) failed++;
};

/** Canonical "name(types)->(types)" form, so ordering and naming differences do not matter. */
function canonical(fragment) {
  const inputs = fragment.inputs.map((i) => i.format("sighash")).join(",");
  const outputs = (fragment.outputs ?? []).map((o) => o.format("sighash")).join(",");
  return `${fragment.name}(${inputs})->(${outputs})`;
}

function compare(label, sdkAbi, artifactPath) {
  console.log(`\n[${label}]`);
  // The artifact only exists after `forge build` has run in that project. Without this the
  // whole point of the test inverts: a reviewer who has not built yet gets a raw ENOENT stack
  // trace and no idea whether the ABIs drifted or the setup did.
  let artifact;
  try {
    artifact = JSON.parse(readFileSync(join(ROOT, artifactPath), "utf8"));
  } catch (e) {
    if (e.code === "ENOENT") {
      console.error(`\n  ✗ missing compiled artifact: ${artifactPath}`);
      console.error(`    Build it first:  cd ${artifactPath.split("/out/")[0]} && forge build`);
      process.exit(2);
    }
    throw e;
  }
  const real = new ethers.Interface(artifact.abi);
  const sdk = new ethers.Interface(sdkAbi);

  for (const frag of sdk.fragments) {
    if (frag.type !== "function") continue;
    let realFrag;
    try {
      realFrag = real.getFunction(frag.selector);
    } catch {
      realFrag = null;
    }
    if (!realFrag) {
      ok(false, `${frag.name}: not present on the compiled contract (selector ${frag.selector})`);
      continue;
    }
    const a = canonical(frag);
    const b = canonical(realFrag);
    ok(a === b, `${frag.name}`, a === b ? "" : `\n      SDK      ${a}\n      contract ${b}`);
  }
}

compare("AgentBond", AGENT_BOND_ABI, ARTIFACTS.AgentBond);
compare("StreamPay", STREAM_PAY_ABI, ARTIFACTS.StreamPay);
compare("CommitStakeV2", COMMIT_STAKE_ABI, ARTIFACTS.CommitStakeV2);

console.log(
  `\n${failed === 0 ? "✅ PASS" : "❌ " + failed + " ABI DRIFT(S)"} — SDK fragments vs compiled artifacts`
);
process.exit(failed === 0 ? 0 : 1);
