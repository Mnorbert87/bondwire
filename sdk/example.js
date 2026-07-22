// Read-only example — no key required. Reads live Arc testnet state through the SDK.
//   npm i ethers && node example.js
import { Bondwire, BONDWIRE } from "./bondwire.js";

const arc = Bondwire.readOnly();

const stats = await arc.stats();
console.log(`Bondwire — chain ${BONDWIRE.chainId}`);
console.log(`  obligations opened: ${stats.obligations}`);
console.log(`  streams opened:     ${stats.streams}`);
console.log(`  commitments opened: ${stats.commitments}`);

// Portable, money backed reputation for any agent address (Agent Passport math).
const demo = "0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a";
const pass = await arc.passport(demo);
console.log(`\npassport ${demo.slice(0, 10)}: score ${pass.score} (${pass.tier})`);
console.log(`  bond ${pass.bond.usdc} USDC · reliability ${pass.reliability === null ? "n/a" : Math.round(pass.reliability * 100) + "%"} · done ${pass.obligations.done} · slashed ${pass.obligations.slashed}`);

// Inspect a bonded verifier commitment (pay only on verified PASS).
if (stats.commitments > 0) {
  const c = await arc.commitment(1);
  console.log(`\ncommitment #1: ${c.status} / ${c.outcome} · ${c.amount.usdc} USDC escrowed`);
}

// Inspect the most recent stream.
if (stats.streams > 0) {
  const s = await arc.getStream(stats.streams);
  console.log(`\nstream #${stats.streams}: ${s.status}`);
  console.log(`  deposit ${s.deposit.usdc} USDC · ${s.streamedPct}% streamed · ${s.withdrawable.usdc} withdrawable`);
}

// To send transactions, construct with a Signer instead:
//   import { ethers } from "ethers";
//   const wallet = new ethers.Wallet(process.env.AGENT_KEY, Bondwire.provider());
//   const arc = new Bondwire(wallet);
//   await arc.bond("5");
//   const { id } = await arc.createStream(CLIENT, "2", { durationSeconds: 3600, memo: "work" });
