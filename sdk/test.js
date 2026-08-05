// Read-only smoke tests against the LIVE Arc testnet deployment. No key, no tx.
// Run: node test.js  (needs ethers installed next to the SDK)
import assert from "node:assert/strict";
import test from "node:test";
import { Bondwire, BONDWIRE } from "./bondwire.js";

const arc = Bondwire.readOnly();
const DEMO = "0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a";

// Three of the four tests below read the live chain, by design: the point is that the SDK
// reaches the real deployment, not that its arithmetic compiles. That means a reviewer behind
// a proxy, on a locked-down network, or hitting an RPC outage sees three failures that look
// like the SDK is broken when it is the network. Say which one it is, once, up front.
test("preflight: the Arc testnet RPC is reachable", async () => {
  try {
    await arc.stats();
  } catch (e) {
    assert.fail(
      `Cannot reach the Arc testnet RPC (${BONDWIRE.rpcUrl ?? "default endpoint"}). ` +
      `The three chain-reading tests below will fail for the same reason, and it is not SDK ` +
      `drift. Set ARC_RPC to a reachable endpoint, or run only the offline test with ` +
      `\`node --test-name-pattern units test.js\`. Underlying error: ${e.shortMessage ?? e.message}`
    );
  }
});

// What this test is actually for: the SDK can reach all three contracts and
// decode their counters. It used to assert magnitudes (>= 16 obligations,
// >= 213 streams) copied from whatever the chain happened to hold that day.
// The 2026-07-31 redeploy reset those counters, so the assertions became
// unreachable and the test failed on a fresh clone while the SDK was fine.
// A threshold pinned to a live counter is a test that expires; assert the
// shape instead, which is what the name promises.
test("stats: all three primitives answer with sane counters", async () => {
  const s = await arc.stats();
  assert.ok(Number.isInteger(s.obligations) && s.obligations >= 0, "obligations counter");
  assert.ok(Number.isInteger(s.streams) && s.streams >= 0, "streams counter");
  assert.ok(Number.isInteger(s.commitments) && s.commitments >= 0, "commitments counter");
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
