// Read-only smoke tests against the LIVE Arc testnet deployment. No key, no tx.
// Run: node test.js  (needs ethers installed next to the SDK)
import assert from "node:assert/strict";
import test from "node:test";
import { Bondwire, BONDWIRE } from "./bondwire.js";

const arc = Bondwire.readOnly();
const DEMO = "0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a";

test("stats: all three primitives answer with sane counters", async () => {
  const s = await arc.stats();
  assert.ok(Number.isInteger(s.obligations) && s.obligations >= 16, "obligations counter");
  assert.ok(Number.isInteger(s.streams) && s.streams >= 213, "streams counter");
  assert.ok(Number.isInteger(s.commitments) && s.commitments >= 4, "commitments counter");
});

test("commitment(1): decodes to a terminal, known outcome", async () => {
  const c = await arc.commitment(1);
  assert.equal(c.status, "Finalized");
  assert.equal(c.outcome, "CleanPass");
  assert.equal(c.amount.usdc, "1.0");
  assert.match(c.verifier, /^0x[0-9a-fA-F]{40}$/);
});

test("passport: demo agent scores with the documented math", async () => {
  const p = await arc.passport(DEMO);
  assert.equal(p.agent, DEMO);
  assert.ok(p.score >= 0 && p.score <= 100, "score in range");
  assert.ok(["Trusted", "Established", "New", "Flagged"].includes(p.tier), "known tier");
  assert.ok(p.obligations.taken >= p.obligations.done + p.obligations.slashed, "tally consistent");
  assert.equal(typeof p.bond.usdc, "string");
  // recompute the score from the returned components — the SDK must agree with itself
  const settled = p.obligations.done + p.obligations.slashed;
  const rel = settled > 0 ? p.obligations.done / settled : null;
  const bu = Number(p.bond.raw) / 1e6;
  const expected = Math.round((rel === null ? 0 : rel * 55) + Math.min(bu / 500, 1) * 30 + Math.min(p.obligations.taken / 10, 1) * 15);
  assert.equal(p.score, expected, "score matches its own components");
});

test("units: human to micro USDC round trip", () => {
  assert.equal(arc.toUnits("10"), 10_000_000n);
  assert.equal(arc.fromUnits(1_500_000n), "1.5");
  assert.equal(BONDWIRE.usdcDecimals, 6);
});
