// referee-bridge — the machine verifier for CommitStakeV2 on Arc testnet.
//
// This is what turns the bonded verifier from a human button into verified delivery:
//   1. reads an OPEN commitment from the live CommitStakeV2,
//   2. runs the Referee verification engine on the deliverable (sandboxed forge
//      compile + optional acceptance tests + adversarial rule gate),
//   3. posts resolve(id, passed) on chain AS the bonded verifier — whose own
//      AgentBond slice is locked behind exactly this verdict.
// A lying bridge loses real money via the challenge + arbiter path. That is the point.
//
//   VERIFIER_PRIVATE_KEY=0x… node referee-bridge.mjs <commitmentId> <deliverable.sol> <spec.txt> [tests.t.sol]
//
// The signer MUST be the commitment's verifier and must have bonded + granted
// CommitStakeV2 a slash allowance (Step 0 of the bonded verifier dApp).
// REFEREE_CLI can override the engine path (defaults to the sibling referee repo).
// Without VERIFIER_PRIVATE_KEY it runs the engine and prints the verdict, sends nothing.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve as rpath } from "node:path";
import { ethers } from "ethers";
import { Bondwire, BONDWIRE } from "./bondwire.js";

const [, , idArg, fileArg, specArg, testsArg] = process.argv;
if (!idArg || !fileArg || !specArg) {
  console.error("usage: node referee-bridge.mjs <commitmentId> <deliverable.sol> <spec.txt> [tests.t.sol]");
  process.exit(1);
}
const id = Number(idArg);

// 1) The commitment must exist and be Open — read the live chain first.
const ro = Bondwire.readOnly();
let c;
for (let i = 0; ; i++) {
  try { c = await ro.commitment(id); break; }
  catch (e) {
    if (i >= 2) throw e;
    console.log(`chain read failed (${(e.shortMessage || e.message).slice(0, 60)}) — retry ${i + 1}/2 in 10s (the public Arc RPC has moods)`);
    await new Promise((r) => setTimeout(r, 10_000));
  }
}
console.log(`commitment #${id}: ${c.status} | ${c.amount.usdc} USDC escrowed | verifier ${c.verifier}`);
if (c.status !== "Open") { console.error(`not Open (${c.status}) — nothing to resolve`); process.exit(1); }

// 2) Run the Referee engine (same CLI the paid ASP wraps — exit 0 = PASS, 2 = FAIL).
const cliDir = process.env.REFEREE_CLI || rpath(import.meta.dirname, "../../referee/verifier-service");
if (!existsSync(rpath(cliDir, "src/cli.js"))) {
  console.error(`referee CLI not found at ${cliDir} (set REFEREE_CLI)`); process.exit(1);
}
console.log("running the Referee engine (sandboxed forge compile + rule gate)…");
const args = ["src/cli.js", "verify", "--file", rpath(fileArg), "--spec", rpath(specArg), "--job", `commit-${id}`];
if (testsArg) args.push("--tests", rpath(testsArg));
const run = spawnSync("node", args, { cwd: cliDir, encoding: "utf8", timeout: 300_000 });
process.stdout.write(run.stdout || "");
if (run.status !== 0 && run.status !== 2) {
  console.error(`engine error (exit ${run.status}): ${run.stderr?.slice(0, 300)}`); process.exit(1);
}
const passed = run.status === 0;
console.log(`\nVERDICT: ${passed ? "PASS" : "FAIL"}`);

// 3) Post the verdict on chain as the bonded verifier.
const pk = process.env.VERIFIER_PRIVATE_KEY;
if (!pk) { console.log("VERIFIER_PRIVATE_KEY not set — verdict NOT posted (dry run)."); process.exit(passed ? 0 : 2); }
const wallet = new ethers.Wallet(pk, Bondwire.provider());
if (wallet.address.toLowerCase() !== c.verifier.toLowerCase()) {
  console.error(`signer ${wallet.address} is not the commitment's verifier ${c.verifier} — refusing to send`); process.exit(1);
}
const bw = new Bondwire(wallet);
const rc = await bw.resolveCommitment(id, passed);
console.log(`resolve(${id}, ${passed}) on chain -> ${BONDWIRE.explorer}/tx/${rc.hash}`);
console.log(`challenge window: ${c.challengeWindow}s — finalize after it to route the money.`);
