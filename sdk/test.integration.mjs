// Anvil integration test for the Bondwire SDK write path.
//
// WHY THIS EXISTS: 162 contract tests cover the Solidity, but no test ever exercised the
// SDK's commit -> resolve -> finalize write path. That let the SDK's happy-path bugs
// (absolute-vs-duration arbiterDeadline, a 6-field Created ABI that never matched the 7-field
// emit, hardcoded defaults that tripped the §7a band) ship green. This deploys the real
// contracts to a local anvil and drives them through the actual SDK, asserting each step.
//
// Run: anvil --silent &   then   node sdk/test.integration.mjs
import { ethers } from "ethers";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Bondwire } from "./bondwire.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const RPC = process.env.ANVIL_RPC || "http://127.0.0.1:8545";

// Deterministic anvil accounts (mnemonic "test test … junk").
const KEYS = {
  deployer: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  staker: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  verifier: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  beneficiary: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  arbiter: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
};

const ART = {
  MockERC20: "contracts/stream-pay/out/MockERC20.sol/MockERC20.json",
  AgentBond: "contracts/agent-bond/out/AgentBond.sol/AgentBond.json",
  StreamPay: "contracts/stream-pay/out/StreamPay.sol/StreamPay.json",
  CommitStakeV2: "contracts/commit-stake-v2/out/CommitStakeV2.sol/CommitStakeV2.json",
};
function artifact(name) {
  const j = JSON.parse(readFileSync(join(ROOT, ART[name]), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
async function deploy(name, signer, ...args) {
  const { abi, bytecode } = artifact(name);
  const f = new ethers.ContractFactory(abi, bytecode, signer);
  const c = await f.deploy(...args);
  await c.waitForDeployment();
  return c.getAddress();
}

const U = (n) => BigInt(Math.round(Number(n) * 1e6)); // human USDC -> micro
let failed = 0;
function check(label, cond, detail = "") {
  console.log(`${cond ? "  ✓" : "  ✗ FAIL"} ${label}${detail ? "  " + detail : ""}`);
  if (!cond) failed++;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true, batchMaxCount: 1 });
  await provider.getBlockNumber().catch(() => { throw new Error(`anvil not reachable at ${RPC} — start it with: anvil --silent &`); });
  // NonceManager on every actor: each sends several txs in a row (deploys, approve+create,
  // bond+allowance+resolve). Without it ethers v6 reuses a stale pending nonce → "nonce too
  // low". This is the same wrapper the MCP signer now uses.
  const w = {}, addr = {};
  for (const [k, pk] of Object.entries(KEYS)) {
    const raw = new ethers.Wallet(pk, provider);
    addr[k] = raw.address;                       // NonceManager has no sync .address
    w[k] = new ethers.NonceManager(raw);
  }

  console.log("[1] deploy contracts to anvil");
  const usdc = await deploy("MockERC20", w.deployer);
  const agentBond = await deploy("AgentBond", w.deployer, usdc);
  const streamPay = await deploy("StreamPay", w.deployer, usdc);
  const commitStake = await deploy("CommitStakeV2", w.deployer, usdc, agentBond, streamPay);
  console.log(`    USDC ${usdc.slice(0, 10)} · AgentBond ${agentBond.slice(0, 10)} · StreamPay ${streamPay.slice(0, 10)} · CommitStakeV2 ${commitStake.slice(0, 10)}`);
  const overrides = { USDC: usdc, AgentBond: agentBond, StreamPay: streamPay, CommitStakeV2: commitStake };

  // Fund staker + verifier with USDC (MockERC20.mint is permissionless).
  const mock = new ethers.Contract(usdc, artifact("MockERC20").abi, w.deployer);
  await (await mock.mint(addr.staker, U(1000))).wait();
  await (await mock.mint(addr.verifier, U(1000))).wait();

  // SDK handles, one per actor.
  const staker = new Bondwire(w.staker, overrides);
  const verifier = new Bondwire(w.verifier, overrides);

  console.log("[2] verifier posts an AgentBond bond + grants CommitStakeV2 a slash allowance");
  await verifier.bond("300");                              // bond 300 USDC (> the ~150 slice)
  await verifier.setSlashAllowance(commitStake, "300");     // enforcer = CommitStakeV2

  // Third leg of verifier setup, and the one this test used to skip: create() checks
  // arbiterApproved[verifier][arbiter] (CommitStakeV2.sol:381) and only the VERIFIER can set it.
  // Without it step [3] reverted with ARBITER_NOT_APPROVED even though an arbiter was passed.
  await verifier.approveArbiter(addr.arbiter, true);
  check("verifier accepted the arbiter (create() checks this)",
        await verifier.isArbiterApproved(addr.verifier, addr.arbiter));

  console.log("[3] staker commits via the SDK (defaults derived from the contract)");
  const { id, receipt } = await staker.commit({
    verifier: addr.verifier,
    beneficiary: addr.beneficiary,
    arbiter: addr.arbiter,     // mandatory — the old ZeroAddress default reverted
    amount: "100",
    // verifierSlice / challengeBond / arbiterDeadline all defaulted from the contract
  });
  check("commit() returns a real id (Created ABI matches the emit)", id !== undefined && id !== null, `id=${id}`);
  check("commit() id is a bigint > 0", typeof id === "bigint" && id > 0n, `id=${id}`);
  check("commit receipt succeeded", receipt?.status === 1);

  const c1 = await staker.commitStake.get(id);
  check("commitment status == Active (1)", Number(c1.status) === 1, `status=${c1.status}`);
  check("verifierSlice defaulted > amount (recommendedSlice)", c1.verifierSlice > U(100), `slice=${ethers.formatUnits(c1.verifierSlice, 6)}`);
  const AD = Number(c1.arbiterDeadline);
  check("arbiterDeadline stored as a DURATION, not an absolute ts", AD > 0 && AD < 100 * 24 * 3600, `arbiterDeadline=${AD}s (${(AD / 3600).toFixed(0)}h)`);

  console.log("[4] verifier resolves PASS");
  await verifier.resolveCommitment(id, true);
  const c2 = await staker.commitStake.get(id);
  check("status == Resolved (2)", Number(c2.status) === 2, `status=${c2.status}`);

  console.log("[5] warp past the challenge window, then finalize");
  await provider.send("evm_increaseTime", [700]);
  await provider.send("evm_mine", []);
  await staker.finalizeCommitment(id);
  const c3 = await staker.commitStake.get(id);
  check("status == Finalized (4)", Number(c3.status) === 4, `status=${c3.status}`);
  check("terminal outcome recorded (outcome != None)", Number(c3.outcome) !== 0, `outcome=${c3.outcome}`);

  console.log(`\n${failed === 0 ? "✅ PASS" : "❌ " + failed + " CHECK(S) FAILED"} — full commit→resolve→finalize SDK path`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error("integration test error:", e.message); process.exit(1); });
