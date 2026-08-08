// MCP surface smoke test — starts the real server over stdio and drives it as a client.
//
// WHY THIS EXISTS: the MCP server is the Track 4 surface — "these are tools in the agent's
// own loop" — and until 2026-08-08 it had zero automated coverage. That is the finding; the
// BigInt bug was only its symptom. `bondwire_commitment` returned "Do not know how to
// serialize a BigInt" for EVERY id, so the tool was not wrong, it was unusable, and it
// shipped that way because nothing ever called it outside a human's terminal.
//
// So this test does what a client does: spawns `node server.mjs`, speaks JSON-RPC over
// stdio, lists the tools, and CALLS the five that need no key. It asserts the payload
// parses as JSON, because that is exactly what the BigInt bug broke — a tool can return a
// plausible looking error string and still be dead.
//
// No key, no writes: AGENT_PRIVATE_KEY is deliberately unset, and the value-moving tools are
// only checked for a clean refusal, never executed. It does read the live Arc testnet RPC,
// because a mock cannot reproduce the bigints that broke serialization in the first place.
//
// Run: node mcp/test.smoke.mjs
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = join(HERE, "server.mjs");

const READ_ONLY = [
  "bondwire_stats",
  "bondwire_passport",
  "bondwire_bond_status",
  "bondwire_commitment",
  "bondwire_commit_quote",   // quotes and previews; signs nothing, needs no key
];
const VALUE_MOVING = [
  "bondwire_commit_execute",
  "bondwire_resolve",
  "bondwire_finalize",
];

// A known bonded agent on Arc testnet. Any address works for the read path; this one has a
// real bond and history, so an empty answer means the RPC lied rather than "nothing to show".
const AIDEN = "0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a";
const ARBITER = "0x7AD10237032263216b87A65dabe7c676dC7B45fB";

let failed = 0;
const ok = (c, msg, detail = "") => {
  console.log(`${c ? "  ✓" : "  ✗ FAIL"} ${msg}${detail ? "  " + detail : ""}`);
  if (!c) failed++;
};

// ── a minimal MCP client over stdio ──────────────────────────────────────────
const env = { ...process.env };
delete env.AGENT_PRIVATE_KEY;          // prove the read path needs no key

const proc = spawn(process.execPath, [SERVER], {
  env, stdio: ["pipe", "pipe", "pipe"],
});
let stderr = "";
proc.stderr.on("data", (d) => { stderr += d.toString(); });

let nextId = 1;
const pending = new Map();
let buf = "";
proc.stdout.on("data", (chunk) => {
  buf += chunk.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    const p = pending.get(msg.id);
    if (p) { pending.delete(msg.id); p(msg); }
  }
});

function rpc(method, params, timeoutMs = 45000) {
  const id = nextId++;
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
  });
}
const notify = (method, params) =>
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");

function payloadOf(res) {
  const c = res?.result?.content;
  return Array.isArray(c) ? c.map((x) => x.text ?? "").join("\n") : "";
}

async function main() {
  console.log("\n[handshake]");
  const init = await rpc("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "bondwire-smoke", version: "1.0.0" },
  });
  ok(!!init.result, "server answered initialize", init.error ? JSON.stringify(init.error) : "");
  ok(init.result?.serverInfo?.name === "bondwire-mcp",
    "identifies itself as bondwire-mcp", init.result?.serverInfo?.name ?? "(none)");
  notify("notifications/initialized", {});

  console.log("\n[tools/list]");
  const listed = await rpc("tools/list", {});
  const tools = listed.result?.tools ?? [];
  const names = tools.map((t) => t.name).sort();
  const expected = [...READ_ONLY, ...VALUE_MOVING].sort();
  ok(names.length === expected.length,
    `exposes ${expected.length} tools`, `got ${names.length}: ${names.join(", ")}`);
  for (const want of expected) ok(names.includes(want), want);
  // A tool an LLM cannot understand is not exposed, it is just present.
  for (const t of tools) {
    ok(!!t.description && t.description.length > 30,
      `${t.name} carries a usable description`);
    ok(!!t.inputSchema, `${t.name} declares an input schema`);
  }

  console.log("\n[read only tools — no AGENT_PRIVATE_KEY set]");
  const args = {
    bondwire_stats: {},
    bondwire_passport: { agent: AIDEN },
    bondwire_bond_status: { agent: AIDEN },
    bondwire_commitment: { id: 1 },
    bondwire_commit_quote: {
      verifier: AIDEN, beneficiary: AIDEN, arbiter: ARBITER, amountUsdc: "1",
    },
  };
  for (const name of READ_ONLY) {
    let res;
    try {
      res = await rpc("tools/call", { name, arguments: args[name] });
    } catch (e) {
      ok(false, `${name} answered`, e.message);
      continue;
    }
    const body = payloadOf(res);
    ok(!res.result?.isError, `${name} returned without an error`, res.result?.isError ? body.slice(0, 160) : "");
    ok(body.length > 0, `${name} returned a non empty payload`);
    // The exact shape the BigInt bug destroyed: the tool "answered", but with a
    // serializer error instead of data. Parsing is the only check that catches it.
    if (name !== "bondwire_commit_quote") {
      let parsed = null;
      try { parsed = JSON.parse(body); } catch { /* stays null */ }
      ok(parsed !== null, `${name} payload parses as JSON`, parsed === null ? body.slice(0, 160) : "");
    }
    ok(!/serialize a BigInt/i.test(body), `${name} did not hit the BigInt serializer`);
  }

  console.log("\n[value moving tools — the confirm gate]");
  // Schema-VALID arguments with confirmed:false. The first version of this test passed
  // garbage, every tool bounced off zod's type check, and the run went green without the
  // guard ever executing — a refusal for the wrong reason reads exactly like the right one.
  const gated = {
    bondwire_commit_execute: { previewId: "bw_deadbeef", confirmed: false },
    bondwire_resolve: { id: 1, passed: true, confirmed: false },
    bondwire_finalize: { id: 1, confirmed: false },
  };
  for (const name of VALUE_MOVING) {
    const res = await rpc("tools/call", { name, arguments: gated[name] });
    const body = payloadOf(res);
    ok(!!res.result, `${name} answered instead of killing the server`);
    ok(res.result?.isError === true, `${name} refused`, body.slice(0, 120));
    ok(/confirmed=true|Unknown previewId/i.test(body),
      `${name} refused for the right reason (confirm gate, not a type error)`, body.slice(0, 120));
  }

  console.log("\n[value moving tools — no key, no signature]");
  // Now past the confirm gate, so the ONLY thing left between this call and a signature is
  // the missing key. Safe because AGENT_PRIVATE_KEY was stripped from the child's env above:
  // a wallet cannot be constructed, so nothing can sign whatever the caller's shell holds.
  const quoted = await rpc("tools/call", {
    name: "bondwire_commit_quote", arguments: args.bondwire_commit_quote,
  });
  let previewId = null;
  try { previewId = JSON.parse(payloadOf(quoted)).previewId; } catch { /* stays null */ }
  ok(!!previewId, "quote handed back a previewId to spend");

  const signing = {
    bondwire_commit_execute: { previewId: previewId ?? "bw_none", confirmed: true },
    bondwire_resolve: { id: 1, passed: true, confirmed: true },
    bondwire_finalize: { id: 1, confirmed: true },
  };
  for (const name of VALUE_MOVING) {
    const res = await rpc("tools/call", { name, arguments: signing[name] });
    const body = payloadOf(res);
    ok(res.result?.isError === true, `${name} stopped at the missing key`, body.slice(0, 120));
    ok(/AGENT_PRIVATE_KEY/.test(body),
      `${name} says which key is missing`, body.slice(0, 160));
  }

  console.log("\n[server is still alive after all of that]");
  const again = await rpc("tools/list", {});
  ok((again.result?.tools ?? []).length === expected.length,
    "tools/list still answers after the refusals");
}

main()
  .catch((e) => { ok(false, "smoke run threw", e.message); })
  .finally(() => {
    proc.kill();
    if (failed && stderr.trim()) console.log("\n[server stderr]\n" + stderr.trim().slice(0, 2000));
    console.log(`\n${failed === 0 ? "✅ PASS" : "❌ " + failed + " FAILURE(S)"} — MCP server surface (8 tools, 5 called without a key)`);
    process.exit(failed === 0 ? 0 : 1);
  });
