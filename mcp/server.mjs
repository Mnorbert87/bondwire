#!/usr/bin/env node
// bondwire-mcp — the trust focused MCP server for the agent economy on Arc testnet.
//
// Where other agent tooling moves value (swap, bridge, send), this server answers the
// question that comes BEFORE the payment: can you trust the agent you are about to pay?
// Tools: Agent Passport (money backed reputation), bond management, and bonded verifier
// escrows on the live CommitStakeV2 (pay only on verified PASS).
//
// Safety model (quote before execute): every value moving tool is split into a quote
// tool (returns a previewId + human summary, signs nothing) and an execute tool that
// requires { confirmed: true, previewId } and signs EXACTLY the previewed params.
//
// Config: read only tools need nothing. Writes need AGENT_PRIVATE_KEY in the env
// (a dedicated burner for Arc TESTNET — never a mainnet key).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { ethers } from "ethers";
import { Bondwire, BONDWIRE } from "./lib/bondwire.js";

const ro = Bondwire.readOnly();
let signerBw = null;
function needSigner() {
  if (signerBw) return signerBw;
  const pk = process.env.AGENT_PRIVATE_KEY;
  if (!pk) throw new Error("AGENT_PRIVATE_KEY is not set. Read only tools work without it; value moving tools need a dedicated Arc TESTNET burner key in the environment.");
  // NonceManager: the MCP server can have several value-moving tool calls in flight at once
  // (quote/execute pairs, concurrent agents). Without it they'd read the same "pending" nonce
  // from the RPC and one tx would drop as "replacement underpriced" — the failure mode the
  // comments already flagged. NonceManager assigns nonces locally and sequentially instead.
  const wallet = new ethers.NonceManager(new ethers.Wallet(pk, Bondwire.provider()));
  signerBw = new Bondwire(wallet);
  return signerBw;
}

const previews = new Map();   // previewId -> { kind, params, summary, createdAt }
const PREVIEW_TTL_MS = 10 * 60 * 1000;
function storePreview(kind, params, summary) {
  const id = "bw_" + Math.random().toString(16).slice(2, 10);
  previews.set(id, { kind, params, summary, createdAt: Date.now() });
  return id;
}
function takePreview(id, kind) {
  const p = previews.get(id);
  if (!p) throw new Error("Unknown previewId. Quote again first.");
  if (p.kind !== kind) throw new Error("This previewId belongs to a different tool.");
  if (Date.now() - p.createdAt > PREVIEW_TTL_MS) { previews.delete(id); throw new Error("Preview expired (10 min). Quote again."); }
  previews.delete(id);
  return p;
}

const text = (s) => ({ content: [{ type: "text", text: typeof s === "string" ? s : JSON.stringify(s, null, 2) }] });
const err = (e) => ({ content: [{ type: "text", text: "Error: " + (e.shortMessage || e.message || String(e)) }], isError: true });

const server = new McpServer({ name: "bondwire-mcp", version: "0.1.0" });

// ── READ ONLY ────────────────────────────────────────────────────────────────

server.tool(
  "bondwire_stats",
  "Live counters of the Bondwire trust stack on Arc testnet: obligations, streams, commitments opened, and total USDC escrowed.",
  {},
  async () => {
    try {
      const s = await ro.stats();
      const esc = await ro.commitStake.totalEscrowed();
      return text({ ...s, totalEscrowedUsdc: ro.fromUnits(esc), chainId: BONDWIRE.chainId, explorer: BONDWIRE.explorer });
    } catch (e) { return err(e); }
  }
);

server.tool(
  "bondwire_passport",
  "Agent Passport: portable, money backed reputation for any agent address, recomputed live from the AgentBond contract. Returns score (0..100), tier (Trusted / Established / New / Flagged), bond depth, reliability and slash history. Call this BEFORE hiring or paying an agent.",
  { agent: z.string().describe("0x agent address to look up") },
  async ({ agent }) => {
    try {
      const p = await ro.passport(agent);
      return text({ ...p, bond: p.bond.usdc + " USDC", slashedTotal: p.slashedTotal.usdc + " USDC", verify: `${BONDWIRE.explorer}/address/${p.agent}` });
    } catch (e) { return err(e); }
  }
);

server.tool(
  "bondwire_bond_status",
  "Bond breakdown for an address on AgentBond: total, locked behind open obligations, free (withdrawable), and the slash allowance granted to the CommitStakeV2 escrow.",
  { agent: z.string().describe("0x address (defaults to the configured signer)") },
  async ({ agent }) => {
    try {
      const a = agent || (await needSigner().runner.getAddress?.()) || agent;
      const total = await ro.agentBond.bond(a);
      const locked = await ro.agentBond.locked(a);
      const free = await ro.agentBond.freeBondOf(a);
      const allow = await ro.agentBond.slashAllowance(a, BONDWIRE.contracts.CommitStakeV2);
      return text({ agent: a, totalUsdc: ro.fromUnits(total), lockedUsdc: ro.fromUnits(locked), freeUsdc: ro.fromUnits(free), escrowSlashAllowanceUsdc: ro.fromUnits(allow) });
    } catch (e) { return err(e); }
  }
);

server.tool(
  "bondwire_commitment",
  "Decoded state of one bonded verifier commitment on CommitStakeV2: parties, amounts, status (Open / Resolved / Challenged / Finalized), outcome and verdict timing.",
  { id: z.number().int().positive().describe("commitment id") },
  async ({ id }) => {
    try { return text(await ro.commitment(id)); } catch (e) { return err(e); }
  }
);

// ── VALUE MOVING (quote before execute) ──────────────────────────────────────

server.tool(
  "bondwire_commit_quote",
  "QUOTE a bonded verifier escrow: you escrow USDC that pays out only on a verified PASS; the verifier's own bond slice is locked behind its verdict. Returns a previewId and a human summary INCLUDING a live passport check on the verifier. Signs nothing. Follow with bondwire_commit_execute after the user confirms.",
  {
    verifier: z.string().describe("0x address of the bonded verifier (must have an AgentBond bond + slash allowance for CommitStakeV2)"),
    beneficiary: z.string().describe("0x address paid if the work FAILS (refund target)"),
    arbiter: z.string().describe("0x address that decides a challenge. Required by CommitStakeV2, and it must differ from you, the verifier and the beneficiary. The VERIFIER must have accepted it via approveArbiter — this quote checks that for you."),
    amountUsdc: z.string().describe("stake amount in human USDC, e.g. \"5\""),
    verifierSliceUsdc: z.string().default("").describe("how much of the verifier's bond is locked behind the verdict. Leave empty to use the contract's own recommendedSlice(), which is the only value guaranteed to clear the strict slice > amount + fees rule."),
    goal: z.string().default("").describe("one line description of the deliverable"),
  },
  async ({ verifier, beneficiary, arbiter, amountUsdc, verifierSliceUsdc, goal }) => {
    try {
      if (!ethers.isAddress(verifier) || !ethers.isAddress(beneficiary)) throw new Error("verifier and beneficiary must be valid 0x addresses");
      if (!ethers.isAddress(arbiter)) throw new Error("arbiter must be a valid 0x address — CommitStakeV2 reverts with ARBITER_ZERO without one");
      let pp = null; try { pp = await ro.passport(verifier); } catch { }

      // Everything below would otherwise revert at execute time. A quote that cannot say
      // "this will fail, and why" is not a quote — it is a delayed error.
      const slice = verifierSliceUsdc || await ro.recommendedSlice(amountUsdc);
      const blockers = [];
      const eq = (a, b) => a.toLowerCase() === b.toLowerCase();
      if (eq(arbiter, verifier)) blockers.push("arbiter equals the verifier (ARBITER_IS_VERIFIER)");
      if (eq(arbiter, beneficiary)) blockers.push("arbiter equals the beneficiary (ARBITER_IS_BENEFICIARY)");
      let approved = null;
      try { approved = await ro.isArbiterApproved(verifier, arbiter); } catch { }
      if (approved === false) {
        blockers.push(
          `the verifier has not accepted this arbiter (ARBITER_NOT_APPROVED). Only the verifier ` +
          `can fix this, by calling approveArbiter(${arbiter}, true) on CommitStakeV2 — you cannot ` +
          `do it on its behalf.`);
      }

      const params = { verifier, beneficiary, arbiter, amount: amountUsdc, verifierSlice: slice, goal };
      const summary =
        `You escrow ${amountUsdc} USDC on the live CommitStakeV2 (Arc testnet).\n` +
        `Verifier ${verifier} — passport: ${pp ? `${pp.tier}, score ${pp.score}, bond ${pp.bond.usdc} USDC, slashed ${pp.obligations.slashed} time(s)` : "unavailable"}.\n` +
        `The verifier locks ${slice} USDC of its own bond behind the verdict${verifierSliceUsdc ? "" : " (sized by the contract)"}.\n` +
        `A challenge escalates to arbiter ${arbiter}${approved === null ? " (approval status unknown — RPC did not answer)" : approved ? " — accepted by the verifier" : ""}.\n` +
        `On verified PASS the stake returns to you; on FAIL it pays ${beneficiary}.\n` +
        `Goal: ${goal || "(none)"}\n` +
        (blockers.length
          ? `\nWILL REVERT — do not execute until these are fixed:\n  - ${blockers.join("\n  - ")}\n`
          : ``) +
        `Nothing is signed yet. To proceed, call bondwire_commit_execute with confirmed=true and this previewId.`;
      const previewId = storePreview("commit", params, summary);
      return text({
        previewId, summary, blockers,
        willRevert: blockers.length > 0,
        arbiterApproved: approved,
        verifierSlice: slice,
        verifierPassport: pp ? { tier: pp.tier, score: pp.score, slashed: pp.obligations.slashed } : null,
      });
    } catch (e) { return err(e); }
  }
);

server.tool(
  "bondwire_commit_execute",
  "EXECUTE a previously quoted bonded verifier escrow. Requires confirmed=true and the previewId from bondwire_commit_quote; signs exactly the previewed params (USDC approve + create). Needs AGENT_PRIVATE_KEY.",
  {
    previewId: z.string(),
    confirmed: z.boolean().describe("must be true — set only after the user approved the quoted summary"),
    confirmationText: z.string().default("").describe("the user's confirmation phrase, echoed into the log"),
  },
  async ({ previewId, confirmed }) => {
    try {
      if (!confirmed) throw new Error("Set confirmed=true only after the user approved the preview.");
      const p = takePreview(previewId, "commit");
      const bw = needSigner();
      const { id, receipt } = await bw.commit({
        verifier: p.params.verifier, beneficiary: p.params.beneficiary,
        arbiter: p.params.arbiter,
        amount: p.params.amount, verifierSlice: p.params.verifierSlice, goal: p.params.goal,
      });
      return text({ ok: true, commitmentId: id?.toString?.() ?? String(id), tx: receipt.hash, explorer: `${BONDWIRE.explorer}/tx/${receipt.hash}` });
    } catch (e) { return err(e); }
  }
);

server.tool(
  "bondwire_resolve",
  "Verifier side: post the verdict on a commitment (true = work passed). This is what the verifier's bond slice stands behind — a false verdict can be challenged and slashed. Requires confirmed=true. Needs AGENT_PRIVATE_KEY (the verifier's).",
  { id: z.number().int().positive(), passed: z.boolean(), confirmed: z.boolean() },
  async ({ id, passed, confirmed }) => {
    try {
      if (!confirmed) throw new Error("Set confirmed=true only after the user approved posting this verdict.");
      const rc = await needSigner().resolveCommitment(id, passed);
      return text({ ok: true, verdict: passed ? "PASS" : "FAIL", tx: rc.hash, explorer: `${BONDWIRE.explorer}/tx/${rc.hash}` });
    } catch (e) { return err(e); }
  }
);

server.tool(
  "bondwire_finalize",
  "Anyone: settle a commitment whose challenge window or deadline has passed — routes the stake, the verifier slice and any challenge bond. Requires confirmed=true. Needs AGENT_PRIVATE_KEY.",
  { id: z.number().int().positive(), confirmed: z.boolean() },
  async ({ id, confirmed }) => {
    try {
      if (!confirmed) throw new Error("Set confirmed=true only after the user approved finalizing.");
      const rc = await needSigner().finalizeCommitment(id);
      const c = await ro.commitment(id);
      return text({ ok: true, outcome: c.outcome, tx: rc.hash, explorer: `${BONDWIRE.explorer}/tx/${rc.hash}` });
    } catch (e) { return err(e); }
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
