// Read-only example — no key required. Reads live Arc testnet state through the SDK.
//   npm i ethers && node example.js
import { Bondwire, BONDWIRE } from "./bondwire.js";

const arc = Bondwire.readOnly();

const stats = await arc.stats();
console.log(`Bondwire — chain ${BONDWIRE.chainId}`);
console.log(`  obligations opened: ${stats.obligations}`);
console.log(`  streams opened:     ${stats.streams}`);

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
