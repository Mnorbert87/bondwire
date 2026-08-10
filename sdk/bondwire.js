// Bondwire SDK — one small wrapper over AgentBond + StreamPay on Arc.
//
// ethers v6 is a peer dependency. In Node: `npm i ethers`. In the browser, map the
// bare "ethers" specifier with an import map or import this file from a bundler.
//
//   import { ethers } from "ethers";
//   import { Bondwire } from "bondwire-sdk";
//
//   const signer = new ethers.Wallet(PRIVATE_KEY, Bondwire.provider());
//   const arc = new Bondwire(signer);
//
// Every amount argument is a human USDC string/number ("10" = 10 USDC); the SDK
// converts to micro-USDC (6 decimals) for you. Views return both `.raw` (bigint
// micro-USDC) and `.usdc` (formatted string) so you never juggle decimals.
import { ethers } from "ethers";

// The public endpoint is the default, not a requirement. A reviewer behind a corporate proxy,
// on a locked-down network, or hitting an outage should be able to point this at their own Arc
// endpoint instead of concluding the SDK is broken. Guarded for the browser, where there is no
// `process`.
const ENV_RPC =
  typeof process !== "undefined" && process.env && process.env.ARC_RPC
    ? process.env.ARC_RPC
    : null;

/** Arc testnet network + deployed addresses, baked in. */
export const BONDWIRE = Object.freeze({
  chainId: 5042002,
  rpcUrl: ENV_RPC || "https://rpc.testnet.arc.network",
  wsUrl: "wss://rpc.testnet.arc.network",
  explorer: "https://testnet.arcscan.app",
  usdcDecimals: 6,
  contracts: Object.freeze({
    AgentBond: "0x4383Ea48837eF7e60fC22BD67945BCBf0551702c",
    StreamPay: "0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262",
    CommitStakeV2: "0x548532aa4B59598188D49b3e74Fdf27aaE127bb6",
    USDC: "0x3600000000000000000000000000000000000000",
    Multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
  }),
});

export const AGENT_BOND_ABI = [
  "function deposit(uint256 amount)",
  "function withdraw(uint256 amount)",
  "function setSlashAllowance(address enforcer, uint256 amount)",
  "function lock(address agent, address creditor, uint256 amount, uint64 deadline) returns (uint256 id)",
  "function release(uint256 id)",
  "function slash(uint256 id)",
  "function bond(address) view returns (uint256)",
  "function locked(address) view returns (uint256)",
  "function freeBondOf(address) view returns (uint256)",
  "function slashAllowance(address agent, address enforcer) view returns (uint256)",
  "function nextObligationId() view returns (uint256)",
  // NOTE: 7 fields. `allowanceEpoch` (grant generation) sits BEFORE `status` in AgentBond as of
  // the revoke-hardening change on this branch. Omitting it does NOT revert — ABI decoding of a
  // static tuple is positional, so `status` would silently read back the epoch number. This ABI
  // therefore tracks THIS BRANCH's contracts; the deployed AgentBond is still the 6-field build,
  // and main's SDK stays 6-field until the redeploy lands.
  "function getObligation(uint256 id) view returns (tuple(address agent, address enforcer, address creditor, uint256 amount, uint64 deadline, uint64 allowanceEpoch, uint8 status))",
  "function usdc() view returns (address)",
  "event Locked(uint256 indexed id, address indexed agent, address indexed enforcer, address creditor, uint256 amount, uint64 deadline)",
];

export const STREAM_PAY_ABI = [
  "function createStream(address recipient, uint256 deposit, uint64 start, uint64 stop, string memo) returns (uint256 id)",
  "function withdraw(uint256 id, uint256 amount)",
  "function cancel(uint256 id)",
  "function streamedTotal(uint256 id) view returns (uint256)",
  "function recipientBalance(uint256 id) view returns (uint256)",
  "function senderBalance(uint256 id) view returns (uint256)",
  "function nextId() view returns (uint256)",
  "function get(uint256 id) view returns (tuple(address sender, address recipient, uint256 deposit, uint256 withdrawn, uint64 start, uint64 stop, uint8 status))",
  "function usdc() view returns (address)",
  "event Created(uint256 indexed id, address indexed sender, address indexed recipient, uint256 deposit, uint64 start, uint64 stop, string memo)",
];

export const COMMIT_STAKE_ABI = [
  "function create((address verifier,address beneficiary,address arbiter,uint256 amount,uint256 verifierSlice,uint64 deadline,uint64 challengeWindow,uint256 challengeBond,uint64 arbiterDeadline,uint256 arbiterFee,uint256 feeDeposit,uint64 feeStart,uint64 feeStop,string goal) p) returns (uint256)",
  "function resolve(uint256 id, bool passed)",
  "function challenge(uint256 id)",
  "function arbitrate(uint256 id, bool overturn)",
  "function finalize(uint256 id)",
  // Arbiter opt-in (CommitStakeV2.sol:497). create() requires arbiterApproved[verifier][arbiter],
  // so a verifier can never be dragged in front of an arbiter it did not accept. Without these two
  // in the ABI the SDK could demand an arbiter but offered no way to make one usable.
  "function approveArbiter(address arbiter, bool ok)",
  "function arbiterApproved(address verifier, address arbiter) view returns (bool)",
  "function nextId() view returns (uint256)",
  "function totalEscrowed() view returns (uint256)",
  "function get(uint256 id) view returns (tuple(address staker,address verifier,address beneficiary,address arbiter,uint256 amount,uint256 verifierSlice,uint256 bondObligationId,uint256 challengeBond,uint256 challengeBondPaid,uint256 arbiterFee,uint256 feeStreamId,uint64 deadline,uint64 challengeWindow,uint64 arbiterDeadline,uint64 resolvedAt,uint64 challengedAt,bool resolvedPass,uint8 status,uint8 outcome))",
  // Contract-derived sizing helpers (public pure) — the SDK uses these for safe defaults
  // instead of hardcoded values, so commit()'s happy path can never revert on the §7a band.
  "function recommendedSlice(uint256 amount, uint256 feeDeposit, uint256 arbiterFee) pure returns (uint256)",
  "function challengeBondFloor(uint256 verifierSlice, uint256 arbiterFee) pure returns (uint256)",
  "function challengeBondCap(uint256 verifierSlice, uint256 arbiterFee) pure returns (uint256)",
  // Bounds added by the 2026-08-10 deploy. Read, never hardcoded, so a later change to the
  // policy constants cannot leave this package rejecting values the contract accepts.
  "function MIN_RESOLVE_WINDOW() view returns (uint64)",
  "function MAX_ARBITER_FEE_LEVERAGE() view returns (uint256)",
  // Must match the contract emit exactly (CommitStakeV2.sol:270-278): 7 fields, not 6.
  // The previous 6-field ABI (…beneficiary,amount,deadline) never matched, so parseLog threw
  // and commit() silently returned id=undefined.
  "event Created(uint256 indexed id, address indexed staker, address indexed verifier, uint256 amount, uint256 verifierSlice, uint256 bondObligationId, string goal)",
];

const MULTICALL3_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) view returns (tuple(bool success, bytes returnData)[])",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

const OBLIGATION_STATUS = ["None", "Active", "Released", "Slashed"];
const STREAM_STATUS = ["None", "Active", "Ended"];
// Must mirror CommitStakeV2.sol enum Status exactly (None,Active,Resolved,Challenged,Finalized,Expired).
// The old ["None","Open","Resolved","Challenged","Finalized"] mislabelled index 1 (Active, not Open)
// and dropped index 5 (Expired = liveness slash), so status reads were wrong past a slash.
const COMMITMENT_STATUS = ["None", "Active", "Resolved", "Challenged", "Finalized", "Expired"];
const COMMITMENT_OUTCOME = [
  "None", "CleanPass", "CleanFail", "UpheldPass", "UpheldFail",
  "OverturnedToPass", "OverturnedToFail", "SilencePass", "SilenceFail", "LivenessSlash",
];

/**
 * A read-only JsonRpcProvider pinned to Arc testnet. batchMaxCount 1 because the
 * public Arc RPC rejects batched (array) JSON-RPC requests, which ethers v6 sends
 * by default when calls land in the same tick; staticNetwork skips chainId probes.
 *
 * Resilience (the load-balanced public RPC times out / 429s under load, which used to
 * fail a whole read or write): each request gets a 20s timeout and up to 4 attempts with
 * exponential backoff (0.5s, 1s, 2s) on transient network / 429 / 5xx responses. Reads are
 * idempotent so retrying is free; a write's retry only re-sends if nothing was broadcast
 * (ethers only invokes retryFunc when it has no successful response).
 */
function arcProvider() {
  const req = new ethers.FetchRequest(BONDWIRE.rpcUrl);
  req.timeout = 20000; // ms per attempt
  req.retryFunc = async (_req, resp, attempt) => {
    if (attempt >= 4) return false;
    const transient = resp == null || resp.statusCode === 429 || resp.statusCode >= 500;
    if (!transient) return false;
    await new Promise((r) => setTimeout(r, 500 * 2 ** (attempt - 1))); // 0.5s,1s,2s backoff
    return true;
  };
  return new ethers.JsonRpcProvider(req, BONDWIRE.chainId, {
    staticNetwork: true,
    batchMaxCount: 1,
  });
}

/** Wrap a bigint micro-USDC amount with a formatted view. */
function usdcAmount(raw) {
  return { raw, usdc: ethers.formatUnits(raw, BONDWIRE.usdcDecimals) };
}

export class Bondwire {
  /**
   * @param {ethers.Signer|ethers.Provider} runner a Signer (to send tx) or a
   *        Provider (read-only). Views work with either; writes need a Signer.
   * @param {object} [overrides] optional { AgentBond, StreamPay, USDC } address overrides.
   */
  constructor(runner, overrides = {}) {
    if (!runner) throw new Error("Bondwire: pass an ethers Signer or Provider");
    this.runner = runner;
    this.addresses = { ...BONDWIRE.contracts, ...overrides };
    this.agentBond = new ethers.Contract(this.addresses.AgentBond, AGENT_BOND_ABI, runner);
    this.streamPay = new ethers.Contract(this.addresses.StreamPay, STREAM_PAY_ABI, runner);
    this.commitStake = new ethers.Contract(this.addresses.CommitStakeV2, COMMIT_STAKE_ABI, runner);
    this.usdc = new ethers.Contract(this.addresses.USDC, ERC20_ABI, runner);
    this.multicall = new ethers.Contract(this.addresses.Multicall3, MULTICALL3_ABI, runner);
  }

  /** A read-only Arc provider — handy for `new ethers.Wallet(key, Bondwire.provider())`. */
  static provider() {
    return arcProvider();
  }

  /** Read-only instance straight off the public RPC (no key needed). */
  static readOnly(overrides = {}) {
    return new Bondwire(arcProvider(), overrides);
  }

  /** micro-USDC bigint from a human amount ("10" -> 10000000n). */
  toUnits(amount) {
    return ethers.parseUnits(String(amount), BONDWIRE.usdcDecimals);
  }

  /** human USDC string from a micro-USDC bigint. */
  fromUnits(units) {
    return ethers.formatUnits(units, BONDWIRE.usdcDecimals);
  }

  async _address() {
    if (typeof this.runner.getAddress === "function") return this.runner.getAddress();
    throw new Error("This call needs a Signer (got a read-only Provider)");
  }

  // --- USDC helpers ----------------------------------------------------------

  /** Approve a stack contract to pull `amount` USDC. Pass "max" for unlimited. */
  async approveUsdc(spender, amount) {
    const value = amount === "max" ? ethers.MaxUint256 : this.toUnits(amount);
    const tx = await this.usdc.approve(spender, value);
    return tx.wait();
  }

  async usdcBalanceOf(address) {
    return usdcAmount(await this.usdc.balanceOf(address));
  }

  // --- AgentBond: trust layer ------------------------------------------------

  /**
   * Post (top up) the caller's bond. Approves USDC first unless you pass
   * { approve:false } (e.g. you already granted allowance).
   */
  async bond(amount, { approve = true } = {}) {
    if (approve) await this.approveUsdc(this.addresses.AgentBond, amount);
    const tx = await this.agentBond.deposit(this.toUnits(amount));
    return tx.wait();
  }

  /** Withdraw free (unlocked) bond back to the caller. */
  async unbond(amount) {
    const tx = await this.agentBond.withdraw(this.toUnits(amount));
    return tx.wait();
  }

  /** Grant (or revoke with 0) an enforcer the right to lock/slash up to `amount` of your bond. */
  async setSlashAllowance(enforcer, amount) {
    const tx = await this.agentBond.setSlashAllowance(enforcer, this.toUnits(amount));
    return tx.wait();
  }

  /**
   * Verifier-side: accept (or drop) `arbiter` as an escalation path for commitments
   * where you are the verifier. `create()` reverts with ARBITER_NOT_APPROVED without it
   * (CommitStakeV2.sol:381), so this is a prerequisite of commit(), not an option.
   * Idempotent, and it is the *verifier* who must send it, not the staker.
   */
  async approveArbiter(arbiter, ok = true) {
    const tx = await this.commitStake.approveArbiter(arbiter, ok);
    return tx.wait();
  }

  /** Has `verifier` accepted `arbiter`? Read-only mirror of the mapping above. */
  async isArbiterApproved(verifier, arbiter) {
    return this.commitStake.arbiterApproved(verifier, arbiter);
  }

  /**
   * The smallest verifier slice CommitStakeV2 will accept for `amount` (plus optional fee legs),
   * in human USDC. commit() already applies this when `verifierSlice` is omitted; this exposes it
   * so callers can *show* the number instead of hardcoding one that a param change would break.
   */
  async recommendedSlice(amount, feeDeposit = "0", arbiterFee = "0") {
    const s = await this.commitStake.recommendedSlice(
      this.toUnits(amount), this.toUnits(feeDeposit), this.toUnits(arbiterFee));
    return this.fromUnits(s);
  }

  /**
   * Enforcer-side: lock `amount` of `agent`'s bond behind a new obligation.
   * Returns { id, receipt }. `deadline` is unix seconds (0 = no expiry).
   */
  async lock(agent, creditor, amount, deadline = 0) {
    const tx = await this.agentBond.lock(agent, creditor, this.toUnits(amount), BigInt(deadline));
    const receipt = await tx.wait();
    const id = this._eventId(receipt, this.agentBond, "Locked");
    return { id, receipt };
  }

  /** Resolve an obligation as performed — bond unlocks, capacity returns. */
  async release(id) {
    const tx = await this.agentBond.release(id);
    return tx.wait();
  }

  /** Resolve an obligation as defaulted — bond pays the creditor. */
  async slash(id) {
    const tx = await this.agentBond.slash(id);
    return tx.wait();
  }

  /** Free (unlocked) bond — the number a counterparty reads to size its trust. */
  async freeBondOf(agent) {
    return usdcAmount(await this.agentBond.freeBondOf(agent));
  }

  /** Full bond breakdown for an agent. */
  async bondOf(agent) {
    const [total, locked] = await Promise.all([
      this.agentBond.bond(agent),
      this.agentBond.locked(agent),
    ]);
    return { total: usdcAmount(total), locked: usdcAmount(locked), free: usdcAmount(total - locked) };
  }

  async slashAllowanceOf(agent, enforcer) {
    return usdcAmount(await this.agentBond.slashAllowance(agent, enforcer));
  }

  /** Decoded obligation record. */
  async getObligation(id) {
    const o = await this.agentBond.getObligation(id);
    return {
      agent: o.agent,
      enforcer: o.enforcer,
      creditor: o.creditor,
      amount: usdcAmount(o.amount),
      deadline: Number(o.deadline),
      status: OBLIGATION_STATUS[Number(o.status)] ?? "Unknown",
    };
  }

  // --- StreamPay: settlement layer -------------------------------------------

  /**
   * Open a USDC payment stream to `recipient` accruing linearly from `start` to
   * `stop` (unix seconds; omit start to begin now). Approves USDC unless
   * { approve:false }. Returns { id, receipt }.
   */
  async createStream(recipient, amount, { start, stop, durationSeconds, memo = "", approve = true } = {}) {
    const now = Math.floor(Date.now() / 1000);
    const s = start ?? now;
    const e = stop ?? (durationSeconds ? s + durationSeconds : undefined);
    if (!e) throw new Error("createStream: provide stop or durationSeconds");
    if (approve) await this.approveUsdc(this.addresses.StreamPay, amount);
    const tx = await this.streamPay.createStream(recipient, this.toUnits(amount), BigInt(s), BigInt(e), memo);
    const receipt = await tx.wait();
    const id = this._eventId(receipt, this.streamPay, "Created");
    return { id, receipt };
  }

  /** Recipient withdraws streamed-so-far funds. Pass amount or "all". */
  async withdraw(id, amount = "all") {
    const value = amount === "all" ? 0n : this.toUnits(amount);
    const tx = await this.streamPay.withdraw(id, value);
    return tx.wait();
  }

  /** Either party cancels: recipient keeps the streamed part, sender reclaims the rest. */
  async cancel(id) {
    const tx = await this.streamPay.cancel(id);
    return tx.wait();
  }

  /** micro-USDC currently withdrawable by the recipient. */
  async recipientBalance(id) {
    return usdcAmount(await this.streamPay.recipientBalance(id));
  }

  /** micro-USDC the sender would reclaim on an immediate cancel. */
  async senderBalance(id) {
    return usdcAmount(await this.streamPay.senderBalance(id));
  }

  /** Decoded stream record + a live progress snapshot. */
  async getStream(id) {
    const [s, recip, sender] = await Promise.all([
      this.streamPay.get(id),
      this.streamPay.recipientBalance(id),
      this.streamPay.senderBalance(id),
    ]);
    const pct = s.deposit > 0n ? Number((s.withdrawn + recip) * 10000n / s.deposit) / 100 : 0;
    return {
      sender: s.sender,
      recipient: s.recipient,
      deposit: usdcAmount(s.deposit),
      withdrawn: usdcAmount(s.withdrawn),
      start: Number(s.start),
      stop: Number(s.stop),
      status: STREAM_STATUS[Number(s.status)] ?? "Unknown",
      withdrawable: usdcAmount(recip),
      reclaimable: usdcAmount(sender),
      streamedPct: pct,
    };
  }

  // --- CommitStakeV2: bonded-verifier escrow (pay only on verified PASS) ------

  /**
   * Open a staked commitment: the caller escrows `amount` USDC that only releases
   * to `beneficiary` on a verified PASS. The verifier must hold an AgentBond bond
   * and have granted CommitStakeV2 a slash allowance — its `verifierSlice` gets
   * locked behind the verdict, so a lying verifier loses real money.
   *
   * Required: { verifier, beneficiary, amount, arbiter }. `arbiter` is mandatory —
   * CommitStakeV2 reverts with ARBITER_ZERO on a zero arbiter (contract line 332).
   *
   * Defaults are DERIVED FROM THE CONTRACT (public-pure helpers), not hardcoded, so the
   * happy path can never trip the §7a bond band or the slice inequality:
   *   verifierSlice  -> recommendedSlice(amount, feeDeposit, arbiterFee)  (> amount+fee+arbiterFee)
   *   challengeBond  -> challengeBondFloor(verifierSlice, arbiterFee)      (band lower bound)
   *   arbiterFee ("0"), feeDeposit ("0", opens a fee stream when > 0), goal ("").
   *
   * TIME CONVENTIONS (this pair is what hid the old bug):
   *   deadline        = ABSOLUTE unix seconds (resolve-by wall-clock; default now+24h).
   *   challengeWindow = DURATION in seconds after resolve (default 600).
   *   arbiterDeadline = DURATION in seconds after a challenge (contract line 198; default 48h).
   * Returns { id, receipt }.
   */
  async commit(p, { approve = true } = {}) {
    const now = Math.floor(Date.now() / 1000);
    if (!p.arbiter || p.arbiter === ethers.ZeroAddress) {
      throw new Error("commit: 'arbiter' is required — CommitStakeV2 reverts (ARBITER_ZERO) on a zero arbiter");
    }
    const amount = this.toUnits(p.amount);
    const arbiterFee = this.toUnits(p.arbiterFee ?? "0");
    const feeDeposit = this.toUnits(p.feeDeposit ?? "0");
    // recommendedSlice takes both fee legs separately and guarantees
    // slice > amount + feeDeposit + arbiterFee, the contract's strict SLICE inequality.
    const verifierSlice = p.verifierSlice != null
      ? this.toUnits(p.verifierSlice)
      : await this.commitStake.recommendedSlice(amount, feeDeposit, arbiterFee);
    // Default the challenge bond to the exact §7a floor the contract enforces.
    const challengeBond = p.challengeBond != null
      ? this.toUnits(p.challengeBond)
      : await this.commitStake.challengeBondFloor(verifierSlice, arbiterFee);
    // The 2026-08-10 deploy floors the resolve window and caps the arbiter fee against the value
    // actually escrowed. Both are checked here so the caller gets the allowed number rather than
    // only the name of the rule it broke. The revert strings themselves do come back from eth_call
    // (measured 2026-08-10), but DEADLINE_TOO_SOON does not tell you the floor is 3600 seconds.
    if (p.deadline != null) {
      const floor = await this.commitStake.MIN_RESOLVE_WINDOW();
      if (BigInt(p.deadline) < BigInt(now) + floor) {
        throw new Error(
          `commit: 'deadline' must be at least ${floor} seconds from now (MIN_RESOLVE_WINDOW). ` +
          `Got ${Number(p.deadline) - now}s. The liveness branch burns the verifier's slice, so the ` +
          `contract will not accept a window no verifier could meet.`);
      }
    }
    if (arbiterFee > 0n) {
      const lev = await this.commitStake.MAX_ARBITER_FEE_LEVERAGE();
      const cap = lev * (amount + feeDeposit);
      if (arbiterFee > cap) {
        throw new Error(
          `commit: 'arbiterFee' ${this.fromUnits(arbiterFee)} is above the cap of ` +
          `${this.fromUnits(cap)} (ARBITER_FEE_TOO_LARGE): ${lev}x the escrowed value. The fee is ` +
          `never escrowed at create, so it is bounded by what is.`);
      }
    }
    const params = {
      verifier: p.verifier,
      beneficiary: p.beneficiary,
      arbiter: p.arbiter,
      amount,
      verifierSlice,
      deadline: BigInt(p.deadline ?? now + 24 * 3600),      // absolute unix seconds
      challengeWindow: BigInt(p.challengeWindow ?? 600),    // duration (s)
      challengeBond,
      arbiterDeadline: BigInt(p.arbiterDeadline ?? 48 * 3600), // duration (s), NOT absolute
      arbiterFee,
      feeDeposit,
      feeStart: BigInt(p.feeStart ?? (feeDeposit > 0n ? now : 0)),
      feeStop: BigInt(p.feeStop ?? (feeDeposit > 0n ? now + 24 * 3600 : 0)),
      goal: p.goal ?? "",
    };
    // The contract pulls amount + feeDeposit from the staker, so approve both.
    if (approve) await this.approveUsdc(this.addresses.CommitStakeV2, this.fromUnits(amount + feeDeposit));
    const tx = await this.commitStake.create(params);
    const receipt = await tx.wait();
    const id = this._eventId(receipt, this.commitStake, "Created");
    return { id, receipt };
  }

  /** Verifier-side: post the verdict (true = work passed, stake to staker path). */
  async resolveCommitment(id, passed) {
    const tx = await this.commitStake.resolve(id, passed);
    return tx.wait();
  }

  /** Dispute a verdict inside the challenge window. Escrows the challenge bond (approves first by default). */
  async challengeCommitment(id, { approve = true } = {}) {
    if (approve) {
      const c = await this.commitStake.get(id);
      await this.approveUsdc(this.addresses.CommitStakeV2, this.fromUnits(c.challengeBond));
    }
    const tx = await this.commitStake.challenge(id);
    return tx.wait();
  }

  /** Arbiter-side: uphold (false) or overturn (true) a challenged verdict. */
  async arbitrateCommitment(id, overturn) {
    const tx = await this.commitStake.arbitrate(id, overturn);
    return tx.wait();
  }

  /** Anyone: settle a commitment whose window/deadline has passed. Routes the money. */
  async finalizeCommitment(id) {
    const tx = await this.commitStake.finalize(id);
    return tx.wait();
  }

  /** Full formatted state of one commitment. */
  async commitment(id) {
    const c = await this.commitStake.get(id);
    return {
      id: Number(id),
      staker: c.staker, verifier: c.verifier, beneficiary: c.beneficiary, arbiter: c.arbiter,
      amount: usdcAmount(c.amount),
      verifierSlice: usdcAmount(c.verifierSlice),
      challengeBond: usdcAmount(c.challengeBond),
      deadline: Number(c.deadline),
      challengeWindow: Number(c.challengeWindow),
      resolvedAt: Number(c.resolvedAt),
      challengedAt: Number(c.challengedAt),
      resolvedPass: c.resolvedPass,
      status: COMMITMENT_STATUS[Number(c.status)] ?? "Unknown",
      outcome: COMMITMENT_OUTCOME[Number(c.outcome)] ?? "Unknown",
    };
  }

  // --- Agent Passport: portable, money-backed reputation ----------------------

  /**
   * Portable reputation for any agent address, recomputed live from AgentBond.
   * One Multicall3 round trip enumerates every obligation (the Arc RPC caps
   * eth_getLogs at 10k blocks and rejects concurrent calls — this avoids both).
   * Score: reliability 0..55 (done/(done+slashed)) + bond depth 0..30 (cap 500
   * USDC) + track record 0..15 (cap 10 obligations). Tiers: Trusted / Established
   * / New / Flagged. Same math as the hosted Agent Passport dApp.
   */
  async passport(agent) {
    const a = ethers.getAddress(agent);
    const bondRaw = await this.agentBond.bond(a);
    const next = Number(await this.agentBond.nextObligationId());
    let taken = 0, done = 0, slashed = 0, active = 0, slashedAmt = 0n;
    const iface = this.agentBond.interface;
    const CHUNK = 400;
    for (let start = 1; start < next; start += CHUNK) {
      const calls = [];
      for (let i = start; i < Math.min(start + CHUNK, next); i++)
        calls.push({ target: this.addresses.AgentBond, allowFailure: true, callData: iface.encodeFunctionData("getObligation", [i]) });
      const res = await this.multicall.aggregate3(calls);
      for (const r of res) {
        if (!r.success) continue;
        const o = iface.decodeFunctionResult("getObligation", r.returnData)[0];
        if (o.agent.toLowerCase() !== a.toLowerCase()) continue;
        taken++;
        const st = Number(o.status);
        if (st === 2) done++;
        else if (st === 3) { slashed++; slashedAmt += o.amount; }
        else if (st === 1) active++;
      }
    }
    const settled = done + slashed;
    const reliability = settled > 0 ? done / settled : null;
    const bondUsdc = Number(bondRaw) / 10 ** BONDWIRE.usdcDecimals;
    const score = Math.round(
      (reliability === null ? 0 : reliability * 55) +
      Math.min(bondUsdc / 500, 1) * 30 +
      Math.min(taken / 10, 1) * 15
    );
    let tier;
    if (slashed > 0 && (reliability === null || reliability < 0.75)) tier = "Flagged";
    else if (score >= 80 && slashed === 0) tier = "Trusted";
    else if (score >= 55) tier = "Established";
    else tier = "New";
    return {
      agent: a, score, tier,
      bond: usdcAmount(bondRaw),
      reliability,
      obligations: { taken, done, slashed, active },
      slashedTotal: usdcAmount(slashedAmt),
    };
  }

  // --- misc ------------------------------------------------------------------

  /** Totals for the hub: obligations opened + streams opened + commitments opened. */
  async stats() {
    // Sequential on purpose: the public Arc RPC rejects concurrent requests.
    const nextObl = await this.agentBond.nextObligationId();
    const nextStream = await this.streamPay.nextId();
    const nextCommit = await this.commitStake.nextId();
    return { obligations: Number(nextObl) - 1, streams: Number(nextStream) - 1, commitments: Number(nextCommit) - 1 };
  }

  explorerTx(hash) {
    return `${BONDWIRE.explorer}/tx/${hash}`;
  }

  /** Pull an id from the first matching event in a receipt.
   *  The inner try/catch is required: a receipt carries foreign logs (USDC Transfer,
   *  AgentBond events, …) that this contract's interface cannot parse — those we skip.
   *  But if NO matching event is found, we THROW rather than return undefined: a silent
   *  undefined id (the old behaviour) let a write path "succeed" with no usable id when
   *  the event ABI drifted from the contract emit. */
  _eventId(receipt, contract, eventName) {
    for (const log of receipt.logs) {
      try {
        const parsed = contract.interface.parseLog(log);
        if (parsed && parsed.name === eventName) return parsed.args.id;
      } catch {
        /* foreign log — not decodable by this contract's interface; skip it */
      }
    }
    throw new Error(
      `${eventName} event not found in receipt (tx ${receipt?.hash}). ` +
      `The event ABI may not match the contract emit.`
    );
  }
}

export default Bondwire;
