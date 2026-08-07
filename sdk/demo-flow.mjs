// End to end demo of the whole Bondwire trust loop on the LIVE Arc testnet contracts:
//   passport check -> arbiter opt-in -> verifier bonds -> staker escrows -> verdict PASS ->
//   finalize -> passport again.
// One funded wallet plays every role that signs: staker, verifier and beneficiary. The arbiter is
// the one role it cannot also play — CommitStakeV2 requires a distinct, verifier-approved address
// there — so the demo names an existing arbiter and never calls it. A clean pass never escalates,
// so that address needs no key and no balance here. Override with ARBITER_ADDRESS if you want your
// own; it must not equal the wallet running this script.
//
//   AGENT_PRIVATE_KEY=0x... node demo-flow.mjs
//
// Needs an Arc TESTNET burner with a few USDC (USDC is the gas token; faucet: faucet.circle.com).
// Never use a mainnet key. Read only steps run even without a key (they just skip the writes).
import { ethers } from "ethers";
import { Bondwire, BONDWIRE } from "./bondwire.js";

const log = (s) => console.log(s);
const tx = (h) => `${BONDWIRE.explorer}/tx/${h}`;

const pk = process.env.AGENT_PRIVATE_KEY;
if (!pk) {
  log("AGENT_PRIVATE_KEY not set — running the read only half of the demo.\n");
  const ro = Bondwire.readOnly();
  const s = await ro.stats();
  log(`Live stack: ${s.obligations} obligations, ${s.streams} streams, ${s.commitments} commitments.`);
  const p = await ro.passport("0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a");
  log(`Passport of the seeded demo agent: score ${p.score} (${p.tier}), bond ${p.bond.usdc} USDC, slashed ${p.obligations.slashed}x.`);
  log("\nSet AGENT_PRIVATE_KEY (Arc testnet burner) to run the full hire flow.");
  process.exit(0);
}

const wallet = new ethers.Wallet(pk, Bondwire.provider());
const me = wallet.address;
const bw = new Bondwire(wallet);
log(`Wallet ${me} on Arc testnet (chain ${BONDWIRE.chainId}).`);
log(`USDC balance: ${(await bw.usdcBalanceOf(me)).usdc}\n`);

// 1) Passport BEFORE trusting: what is this agent's word worth right now?
let pass = await bw.passport(me);
log(`1) Passport before: score ${pass.score} (${pass.tier}), bond ${pass.bond.usdc} USDC, done ${pass.obligations.done}, slashed ${pass.obligations.slashed}.`);

// 2) The verifier posts a bond and lets the escrow slash it. Skin in the game.
log(`2) Bonding 2 USDC + granting CommitStakeV2 a slash allowance…`);
await bw.bond("2");
await bw.setSlashAllowance(BONDWIRE.contracts.CommitStakeV2, "1000");
log(`   free bond now: ${(await bw.freeBondOf(me)).usdc} USDC`);

// 3) Name the escalation path, and accept it as the verifier.
// CommitStakeV2 requires a real arbiter that is none of staker / verifier / beneficiary, and that
// the verifier has opted into (contract lines 371-381). One wallet cannot play this fourth role,
// so the demo names the arbiter that already sits on commitments #1-#4 on chain. It is never
// called on a clean pass — it is the address a challenge would escalate to — so it needs no funds.
const ARBITER = process.env.ARBITER_ADDRESS || "0x7AD10237032263216b87A65dabe7c676dC7B45fB";
log(`3) Accepting arbiter ${ARBITER} as the escalation path…`);
if (await bw.isArbiterApproved(me, ARBITER)) {
  log(`   already approved, skipping the tx.`);
} else {
  const ra = await bw.approveArbiter(ARBITER, true);
  log(`   approved -> ${tx(ra.hash)}`);
}

// 4) The staker escrows USDC that only releases on a verified PASS.
// The verifier's slice is deliberately NOT hardcoded here. CommitStakeV2 enforces a strict
// slice > amount + feeDeposit + arbiterFee (SLICE_TOO_SMALL), so any fixed number in this file
// would be one parameter change away from reverting. Asking the contract for its own
// recommendedSlice() is the only version that cannot go stale.
const slice = await bw.recommendedSlice("1");
log(`4) Escrowing 1 USDC behind a verified outcome (verifier slice ${slice} — sized by the contract)…`);
const { id, receipt } = await bw.commit({
  verifier: me, beneficiary: me, arbiter: ARBITER, amount: "1",
  challengeWindow: 30, goal: "demo: prove the loop end to end",
});
log(`   commitment #${id} created -> ${tx(receipt.hash)}`);

// 5) The verifier posts the verdict its own bond stands behind.
log(`5) Resolving PASS…`);
const r1 = await bw.resolveCommitment(id, true);
log(`   verdict on chain -> ${tx(r1.hash)}`);

// 6) After the challenge window, anyone can settle. The money routes on proof, not promise.
log(`6) Waiting out the 30s challenge window…`);
await new Promise((r) => setTimeout(r, 35_000));
const r2 = await bw.finalizeCommitment(id);
const c = await bw.commitment(id);
log(`   finalized: ${c.status} / ${c.outcome} -> ${tx(r2.hash)}`);

// 7) The passport moved: one more completed obligation in the money backed track record.
pass = await bw.passport(me);
log(`7) Passport after: score ${pass.score} (${pass.tier}), done ${pass.obligations.done}.`);
log(`\nThe whole loop settled in USDC on the live contracts. Verify every hash on arcscan.`);
