#!/usr/bin/env node
/**
 * x402 pay-per-inference server — settled on Arc with StreamPay.
 *
 * A single endpoint, `GET /inference`, is gated behind HTTP 402 Payment Required.
 * Payment is NOT a one-shot charge: the client opens a StreamPay micro-stream to this
 * server's address, and the server PULLS the seconds that have vested each time it
 * serves a call. That is pay-per-second-of-use — the agentic-economy billing model —
 * with the on-chain settlement riding our StreamPay primitive as the rail.
 *
 * Flow:
 *   1. GET /inference?prompt=...            -> 402 + machine-readable payment terms (x402 body).
 *   2. (client opens a StreamPay stream to PAY_TO off this response.)
 *   3. GET /inference?prompt=...&stream=ID  -> server reads the stream on-chain:
 *        - must be Active, recipient must be this server, and have vested-unwithdrawn >= MIN.
 *        - server withdraw()s the vested amount (real Arc tx) and returns 200 + the result
 *          + the settlement tx hash. No payment vested -> 402 again.
 *
 * The "model" here is a deterministic stub: this demo proves the PAYMENT RAIL and the
 * 402->200 gate, not a language model. Swap `runInference` for any real engine.
 *
 * Env:
 *   SERVER_PRIVATE_KEY  key whose address receives + withdraws the stream   [required]
 *   RPC_URL             Arc Testnet RPC                                      [default below]
 *   STREAM_PAY          StreamPay address                                    [default = live USDC deploy]
 *   PORT                listen port                                          [default 4021]
 *   MIN_CALL_USDC       min vested USDC required to serve a call             [default 0.01]
 */
import http from "node:http";
import { ethers } from "ethers";

const RPC = process.env.RPC_URL || "https://rpc.testnet.arc.network";
const CHAIN_ID = 5042002;
const EXPLORER = "https://testnet.arcscan.app";
const STREAM_PAY = process.env.STREAM_PAY || "0x505739d33D85AD85D0f9eeE64856309782382450";
const PORT = Number(process.env.PORT || 4021);
const U = 1_000_000n; // 1 USDC (6 decimals)
const MIN_CALL = BigInt(Math.round(Number(process.env.MIN_CALL_USDC || 0.01) * 1e6)); // micro-USDC

const SP_ABI = [
  "function get(uint256) view returns (tuple(address sender,address recipient,uint256 deposit,uint256 withdrawn,uint64 start,uint64 stop,uint8 status))",
  "function recipientBalance(uint256) view returns (uint256)",
  "function withdraw(uint256,uint256)",
  "event Withdrawn(uint256 indexed id, address indexed recipient, uint256 amount)",
];
const SIG_MAX_AGE_S = Number(process.env.SIG_MAX_AGE_S || 120);

const usd = (v) => (Number(v) / 1e6).toFixed(6);

const pk = process.env.SERVER_PRIVATE_KEY;
if (!pk) { console.error("Set SERVER_PRIVATE_KEY (the server's testnet key)."); process.exit(1); }

const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID);
const wallet = new ethers.Wallet(pk, provider);
const SERVER_ADDR = wallet.address;
const sp = new ethers.Contract(STREAM_PAY, SP_ABI, wallet);

// --- the "inference" stub. Deterministic, obviously not a real model. ---
function runInference(prompt) {
  const p = (prompt || "").slice(0, 200);
  const tokens = p.split(/\s+/).filter(Boolean).length;
  const hash = ethers.id(p).slice(0, 10);
  return {
    model: "stub-inference-v0 (demo)",
    prompt: p,
    completion: `Acknowledged "${p}" — ${tokens} tokens. Deterministic stub completion ${hash}.`,
    tokens,
  };
}

// machine-readable 402 payment terms, x402-style
function paymentTerms() {
  return {
    error: "payment_required",
    x402: {
      scheme: "streampay",
      network: "arc-testnet",
      chainId: CHAIN_ID,
      asset: "USDC",
      settlementContract: STREAM_PAY,
      payTo: SERVER_ADDR,
      pricing: `pay-per-second: server pulls vested USDC each call (min ${usd(MIN_CALL)} USDC vested to serve)`,
      suggestedDeposit: "0.30 USDC over 60s",
      instructions:
        `Open a StreamPay stream with recipient=${SERVER_ADDR}, then resend with ` +
        `?stream=<id>&ts=<unix seconds>&sig=<signature>. sig = the stream SENDER's ` +
        `personal_sign over "x402-inference:<chainId>:<settlementContract>:<streamId>:<keccak256(prompt)>:<ts>" ` +
        `(binds the call to the payer; ts must be within ${SIG_MAX_AGE_S}s).`,
    },
  };
}

// The exact message the stream's sender must sign for one call.
function authMessage(streamId, prompt, ts) {
  return `x402-inference:${CHAIN_ID}:${STREAM_PAY}:${streamId}:${ethers.id(prompt || "")}:${ts}`;
}

// Anti-replay: a presented signature is single-use. Entries expire with the freshness window.
const seenSigs = new Map(); // sigLowercase -> expiry epoch seconds
function sigReplayed(sig) {
  const now = Math.floor(Date.now() / 1000);
  for (const [k, exp] of seenSigs) if (exp < now) seenSigs.delete(k);
  const key = sig.toLowerCase();
  if (seenSigs.has(key)) return true;
  seenSigs.set(key, now + SIG_MAX_AGE_S + 60);
  return false;
}

// Per-stream mutex: serializes check→withdraw per stream so concurrent requests
// cannot all pass the vested check before the first withdraw lands (TOCTOU).
const streamLocks = new Map(); // id -> tail promise
function withStreamLock(id, fn) {
  const prev = streamLocks.get(id) || Promise.resolve();
  const run = prev.then(fn, fn);
  const tail = run.catch(() => {});
  streamLocks.set(id, tail);
  tail.finally(() => { if (streamLocks.get(id) === tail) streamLocks.delete(id); });
  return run;
}

function send(res, code, obj, extraHeaders = {}) {
  const body = JSON.stringify(obj, null, 2);
  res.writeHead(code, { "Content-Type": "application/json", ...extraHeaders });
  res.end(body);
}

async function handle(req, res) {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname !== "/inference") return send(res, 404, { error: "not_found" });

  const prompt = url.searchParams.get("prompt") || "";
  const promptLog = prompt.slice(0, 40).replace(/[\r\n]/g, " ");
  const streamId = url.searchParams.get("stream");
  const sig = url.searchParams.get("sig");
  const ts = url.searchParams.get("ts");

  // No payment presented -> 402 with terms.
  if (!streamId) {
    console.log(`402  no stream  prompt="${promptLog}"`);
    return send(res, 402, paymentTerms(), {
      "WWW-Authenticate": `x402 settlementContract="${STREAM_PAY}", payTo="${SERVER_ADDR}", asset="USDC"`,
    });
  }

  // Verify the stream on-chain.
  let st;
  try {
    st = await sp.get(streamId);
  } catch {
    return send(res, 402, { ...paymentTerms(), reason: "stream_not_found" });
  }
  const recipient = st.recipient.toLowerCase();
  const active = Number(st.status) === 1;
  if (!active || recipient !== SERVER_ADDR.toLowerCase()) {
    return send(res, 402, { ...paymentTerms(), reason: "stream_not_active_or_wrong_recipient" });
  }

  // Payer binding: the stream ID is public and sequential — it must not act as a bearer
  // token. Only the stream's SENDER (the payer) may spend its vested balance on calls.
  if (!sig || !ts) {
    return send(res, 402, { ...paymentTerms(), reason: "missing_payer_signature" });
  }
  const now = Math.floor(Date.now() / 1000);
  if (!/^\d+$/.test(ts) || Math.abs(now - Number(ts)) > SIG_MAX_AGE_S) {
    return send(res, 402, { ...paymentTerms(), reason: "signature_expired" });
  }
  let signer;
  try {
    signer = ethers.verifyMessage(authMessage(streamId, prompt, ts), sig);
  } catch {
    return send(res, 402, { ...paymentTerms(), reason: "bad_signature" });
  }
  if (signer.toLowerCase() !== st.sender.toLowerCase()) {
    console.log(`402  stream #${streamId} signer ${signer} is not the stream sender`);
    return send(res, 402, { ...paymentTerms(), reason: "signer_not_stream_sender" });
  }
  if (sigReplayed(sig)) {
    return send(res, 402, { ...paymentTerms(), reason: "signature_replayed" });
  }

  // Check→settle under a per-stream mutex, and gate the 200 on the amount the withdraw
  // ACTUALLY pulled (from the Withdrawn event) — never on the pre-tx read. Concurrent
  // requests on one stream therefore serialize, and each 200 is individually paid for.
  const settled = await withStreamLock(String(streamId), async () => {
    const vested = await sp.recipientBalance(streamId);
    if (vested < MIN_CALL) return { code: 402, reason: "insufficient_vested_balance", vested };

    // Settle: pull everything vested since the last call (pay-per-second). Real Arc tx.
    // On Arc, block.timestamp is non-monotonic, so the amount that has actually vested at
    // mining time can dip below what we just read — making withdraw revert. That is a
    // transient, not a fault: answer 402 and let the agent retry on its next call.
    let rc;
    try {
      const tx = await sp.withdraw(streamId, 0n);
      rc = await tx.wait();
      if (rc.status !== 1) throw new Error("withdraw reverted");
    } catch (e) {
      console.log(`402  stream #${streamId} settle failed (${e.shortMessage || e.message}) — retry next call`);
      return { code: 402, reason: "settlement_reverted_retry" };
    }

    let pulled = 0n;
    for (const l of rc.logs) {
      try {
        const ev = sp.interface.parseLog(l);
        if (ev?.name === "Withdrawn" && BigInt(ev.args.id) === BigInt(streamId)) pulled = ev.args.amount;
      } catch {}
    }
    if (pulled < MIN_CALL) {
      console.log(`402  stream #${streamId} withdraw pulled only $${usd(pulled)} < $${usd(MIN_CALL)} — not serving`);
      return { code: 402, reason: "insufficient_settled_amount", pulled };
    }
    return { code: 200, rc, pulled };
  });

  if (settled.code !== 200) {
    if (settled.reason === "insufficient_vested_balance") {
      console.log(`402  stream #${streamId} underfunded vested=$${usd(settled.vested)} < $${usd(MIN_CALL)}`);
    }
    return send(res, 402, {
      ...paymentTerms(),
      reason: settled.reason,
      ...(settled.vested !== undefined ? { vested: usd(settled.vested), minPerCall: usd(MIN_CALL) } : {}),
    });
  }

  const result = runInference(prompt);
  console.log(`200  stream #${streamId} served, settled $${usd(settled.pulled)}  tx ${settled.rc.hash}`);
  return send(res, 200, {
    ok: true,
    result,
    payment: {
      stream: Number(streamId),
      settledUSDC: usd(settled.pulled),
      settlementTx: settled.rc.hash,
      explorer: `${EXPLORER}/tx/${settled.rc.hash}`,
    },
  });
}

const server = http.createServer((req, res) => {
  // A failed settlement must never take the server down — always answer something.
  handle(req, res).catch((e) => {
    console.error(`500  ${e.shortMessage || e.message}`);
    try { send(res, 500, { error: "server_error" }); } catch {}
  });
});

process.on("unhandledRejection", (e) => console.error("unhandledRejection:", e?.shortMessage || e?.message || e));
process.on("uncaughtException", (e) => console.error("uncaughtException:", e?.shortMessage || e?.message || e));

server.listen(PORT, () => {
  console.log(`x402 inference server on :${PORT}`);
  console.log(`  payTo (server)   ${SERVER_ADDR}`);
  console.log(`  StreamPay        ${STREAM_PAY}`);
  console.log(`  min per call     $${usd(MIN_CALL)} USDC vested`);
});
