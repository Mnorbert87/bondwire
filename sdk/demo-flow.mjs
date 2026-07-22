// End to end demo of the whole Bondwire trust loop on the LIVE Arc testnet contracts:
//   passport check -> verifier bonds -> staker escrows -> verdict PASS -> finalize -> passport again.
// One wallet plays every role so a single funded testnet key is enough.
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

// 3) The staker escrows USDC that only releases on a verified PASS.
log(`3) Escrowing 1 USDC behind a verified outcome (verifier slice 0.5)…`);
const { id, receipt } = await bw.commit({
  verifier: me, beneficiary: me, amount: "1", verifierSlice: "0.5",
  challengeWindow: 30, goal: "demo: prove the loop end to end",
});
log(`   commitment #${id} created -> ${tx(receipt.hash)}`);

// 4) The verifier posts the verdict its own bond stands behind.
log(`4) Resolving PASS…`);
const r1 = await bw.resolveCommitment(id, true);
log(`   verdict on chain -> ${tx(r1.hash)}`);

// 5) After the challenge window, anyone can settle. The money routes on proof, not promise.
log(`5) Waiting out the 30s challenge window…`);
await new Promise((r) => setTimeout(r, 35_000));
const r2 = await bw.finalizeCommitment(id);
const c = await bw.commitment(id);
log(`   finalized: ${c.status} / ${c.outcome} -> ${tx(r2.hash)}`);

// 6) The passport moved: one more completed obligation in the money backed track record.
pass = await bw.passport(me);
log(`6) Passport after: score ${pass.score} (${pass.tier}), done ${pass.obligations.done}.`);
log(`\nThe whole loop settled in USDC on the live contracts. Verify every hash on arcscan.`);
