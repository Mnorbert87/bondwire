// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStakeV2, IERC20, IAgentBond, IStreamPay} from "../src/CommitStakeV2.sol";
import {AgentBond, IERC20 as AB_IERC20} from "agent-bond/AgentBond.sol";
import {StreamPay, IERC20 as SP_IERC20} from "stream-pay/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives CommitStakeV2 (wired to the REAL AgentBond + StreamPay) through random
///      create/resolve/challenge/arbitrate/finalize/slash/warp sequences, with all five fuzz
///      actors: staker, verifier, beneficiary, arbiter, and an OUTSIDER that pokes every
///      function in every state. A third of the commitments carry a REAL StreamPay fee stream
///      (opened by the escrow itself — the §7 sender-right), so the §7a damage/burn routing is
///      exercised with real accrual.
///
///      The ghost ledger is built from REAL balanceOf deltas measured around each call — never
///      from the contract's own bookkeeping. Dedicated edge ops aim at the exact transition
///      edges (resolve at the deadline second, challenge in the window's last second plus a
///      same-timestamp finalize attempt, arbiter ruling at its deadline second), because
///      challenge-window systems break on the edges, not in the middle.
///
///      ⚠️ WHERE THE STATE-MACHINE TRANSITION PROHIBITION LIVES: this handler's `breach` flag,
///      set by `_noteTransition` (legal-transition whitelist + on-chain status mirror) and by
///      every illegal-success probe, asserted by `invariant_StateMachineExactlyOneTerminal`
///      in the invariant contract below. That pair IS the "fifth invariant" (e).
contract CommitStakeV2Handler is Test {
    CommitStakeV2 public cs;
    AgentBond public agentBond;
    StreamPay public streamPay;
    MockERC20 public usdc;

    address public staker = address(0xA11CE);
    address public verifier = address(0xF1);
    address public beneficiary = address(0xBE1);
    address public arbiter = address(0xAB1);
    address public outsider = address(0xBAD);
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    struct Ghost {
        uint256 stakeIn; // escrow delta at create
        uint256 bondIn; // escrow delta at challenge
        uint256 feeIn; // fee-stream deposit booked by StreamPay at create (0 if none)
        uint256 maxFee; // alias of feeIn: the §4 sizing input
        CommitStakeV2.Status lastStatus; // our mirror, advanced only by observed legal ops
        CommitStakeV2.Outcome outcome; // recorded at the terminal transition
        bool terminal;
        uint256 terminalCount; // must end at exactly 1 for every terminal commitment
        uint256 paidTotal; // Σ party wallet deltas at the terminal call
        uint256 burned; // BURN address delta at the terminal call (§7a surplus)
        uint256 feeReleased; // fee deposit that left StreamPay at the terminal call
        uint256 sliceSlashed; // verifier AgentBond decrease at the terminal call
    }

    uint256[] public ids;
    mapping(uint256 => Ghost) public ghosts;

    /// @dev Set the moment anything illegal is observed; invariants assert it stays false.
    bool public breach;
    string public breachReason;

    struct Snap {
        uint256 staker;
        uint256 verifier;
        uint256 beneficiary;
        uint256 arbiter;
        uint256 burn;
        uint256 streamPayBal;
        uint256 verifierBond;
    }

    constructor(CommitStakeV2 _cs, AgentBond _ab, StreamPay _sp, MockERC20 _usdc) {
        cs = _cs;
        agentBond = _ab;
        streamPay = _sp;
        usdc = _usdc;

        address[5] memory actors = [staker, verifier, beneficiary, arbiter, outsider];
        for (uint256 i; i < actors.length; i++) {
            usdc.mint(actors[i], 100_000_000e6);
            vm.startPrank(actors[i]);
            usdc.approve(address(cs), type(uint256).max);
            usdc.approve(address(streamPay), type(uint256).max);
            usdc.approve(address(agentBond), type(uint256).max);
            vm.stopPrank();
        }
        vm.startPrank(verifier);
        agentBond.deposit(10_000_000e6);
        agentBond.setSlashAllowance(address(cs), type(uint256).max);
        vm.stopPrank();
    }

    // --- ops ---

    function create(uint256 amountSeed, uint256 sliceSeed, uint256 feeSeed, uint256 timeSeed)
        public
    {
        if (ids.length >= 12) return; // keep runs bounded
        uint256 amount = bound(amountSeed, 4, 50_000e6);
        uint64 deadline = uint64(block.timestamp) + uint64(bound(timeSeed, 1 hours, 30 days));
        uint64 window = uint64(bound(timeSeed >> 16, 5 minutes, 1 days));
        uint64 arbDl = uint64(bound(timeSeed >> 32, 5 minutes, 1 days));

        CommitStakeV2.CreateParams memory p = CommitStakeV2.CreateParams({
            verifier: verifier,
            beneficiary: beneficiary,
            arbiter: arbiter,
            amount: amount,
            verifierSlice: 0, // set below
            deadline: deadline,
            challengeWindow: window,
            challengeBond: 0, // set below (band depends on slice + arbiter fee)
            arbiterDeadline: arbDl,
            arbiterFee: 0, // set below
            feeDeposit: 0,
            feeStart: 0,
            feeStop: 0,
            goal: "inv"
        });

        // A third of the commitments carry a real fee stream (§7 composition), opened by the
        // escrow itself inside create.
        if (feeSeed % 3 == 0) {
            p.feeDeposit = bound(feeSeed, 1, amount);
            p.feeStart = deadline + window;
            p.feeStop = p.feeStart + 1 days;
        }

        p.verifierSlice = amount + p.feeDeposit + 1 + bound(sliceSeed, 0, amount);
        if (agentBond.freeBondOf(verifier) < p.verifierSlice) return; // capacity exhausted
        // Fuzz arbiterFee ACROSS the slice, not just up to `amount`: the upper region now drives
        // the gate-4 sizing revert (`slice > amount + feeDeposit + arbiterFee`), exercising the
        // "a hostile (damage >= slice) commitment cannot be created" property inside the run.
        // The revert is try/catch-skipped below so `fail_on_revert = true` is honoured — a
        // rejected create is the CORRECT behaviour, not a handler bug.
        p.arbiterFee = bound(feeSeed >> 8, 0, p.verifierSlice + amount);
        uint256 floor = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        uint256 cap = cs.challengeBondCap(p.verifierSlice, p.arbiterFee);
        p.challengeBond = floor + (bound(sliceSeed >> 8, 0, cap - floor));

        uint256 escrowBefore = usdc.balanceOf(address(cs));
        uint256 spBefore = usdc.balanceOf(address(streamPay));
        vm.prank(staker);
        try cs.create(p) returns (uint256 id) {
            // Created => the sizing rule held => damage < slice is guaranteed for this id.
            Ghost storage g = ghosts[id];
            g.stakeIn = usdc.balanceOf(address(cs)) - escrowBefore; // REAL delta, not p.amount
            g.feeIn = usdc.balanceOf(address(streamPay)) - spBefore; // REAL StreamPay delta
            g.maxFee = g.feeIn;
            g.lastStatus = CommitStakeV2.Status.Active;
            ids.push(id);
        } catch {
            // Hostile / dust input rejected at create (SLICE_TOO_SMALL or the band guard). This
            // is the enforced property, not a failure — skip without recording an id.
        }
    }

    function resolveOp(uint256 idSeed, bool pass, bool atDeadlineEdge) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        CommitStakeV2.Commitment memory c = cs.get(id);
        if (c.status != CommitStakeV2.Status.Active) return;
        if (atDeadlineEdge && block.timestamp < c.deadline) vm.warp(c.deadline); // exact edge
        if (block.timestamp > c.deadline) return; // liveness arm owns it now

        vm.prank(verifier);
        cs.resolve(id, pass);
        _noteTransition(id, CommitStakeV2.Status.Resolved);
    }

    function challengeOp(uint256 idSeed, bool lastSecondEdge) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        CommitStakeV2.Commitment memory c = cs.get(id);
        if (c.status != CommitStakeV2.Status.Resolved) return;
        uint256 windowEnd = uint256(c.resolvedAt) + c.challengeWindow;
        if (lastSecondEdge && block.timestamp < windowEnd) vm.warp(windowEnd); // exact edge
        if (block.timestamp > windowEnd) return;

        address harmed = c.resolvedPass ? beneficiary : staker;
        uint256 escrowBefore = usdc.balanceOf(address(cs));
        vm.prank(harmed);
        cs.challenge(id);
        ghosts[id].bondIn = usdc.balanceOf(address(cs)) - escrowBefore;
        _noteTransition(id, CommitStakeV2.Status.Challenged);

        if (lastSecondEdge) {
            // The spec's canonical edge: last-second challenge + SAME-timestamp finalize.
            // The finalize must lose; if it ever succeeds the state machine is broken.
            try cs.finalize(id) {
                breach = true;
                breachReason = "same-block finalize after last-second challenge";
            } catch {}
        }
    }

    function arbitrateOp(uint256 idSeed, bool overturn, bool lastSecondEdge) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        CommitStakeV2.Commitment memory c = cs.get(id);
        if (c.status != CommitStakeV2.Status.Challenged) return;
        uint256 ruleEnd = uint256(c.challengedAt) + c.arbiterDeadline;
        if (lastSecondEdge && block.timestamp < ruleEnd) vm.warp(ruleEnd); // exact edge
        if (block.timestamp > ruleEnd) return;

        Snap memory s0 = _snap();
        vm.prank(arbiter);
        cs.arbitrate(id, overturn);
        _noteTransition(id, CommitStakeV2.Status.Finalized);
        _recordTerminal(id, s0);
    }

    function finalizeOp(uint256 idSeed) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        CommitStakeV2.Commitment memory c = cs.get(id);

        bool cleanReady = c.status == CommitStakeV2.Status.Resolved
            && block.timestamp > uint256(c.resolvedAt) + c.challengeWindow;
        bool silenceReady = c.status == CommitStakeV2.Status.Challenged
            && block.timestamp > uint256(c.challengedAt) + c.arbiterDeadline;

        if (!cleanReady && !silenceReady) {
            // Probe: finalize must revert in every other situation and change nothing.
            CommitStakeV2.Status before = c.status;
            try cs.finalize(id) {
                breach = true;
                breachReason = "finalize succeeded in non-finalizable state";
            } catch {}
            if (cs.get(id).status != before) {
                breach = true;
                breachReason = "failed finalize mutated state";
            }
            return;
        }

        Snap memory s0 = _snap();
        vm.prank(outsider); // permissionless: the outsider is the legitimate caller here
        cs.finalize(id);
        _noteTransition(id, CommitStakeV2.Status.Finalized);
        _recordTerminal(id, s0);
    }

    function slashExpiredOp(uint256 idSeed) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        CommitStakeV2.Commitment memory c = cs.get(id);
        if (c.status != CommitStakeV2.Status.Active || block.timestamp <= c.deadline) {
            // Probe: must revert outside its exact precondition.
            CommitStakeV2.Status before = c.status;
            try cs.slashVerifierExpired(id) {
                breach = true;
                breachReason = "slashVerifierExpired fired outside its precondition";
            } catch {}
            if (cs.get(id).status != before) {
                breach = true;
                breachReason = "failed slash mutated state";
            }
            return;
        }

        Snap memory s0 = _snap();
        vm.prank(outsider);
        cs.slashVerifierExpired(id);
        _noteTransition(id, CommitStakeV2.Status.Expired);
        _recordTerminal(id, s0);
    }

    /// @dev The fifth actor: an outsider hammers the role-gated functions in whatever state the
    ///      commitment is in. Every call must revert and nothing may change.
    function outsiderProbe(uint256 idSeed, uint256 fnSeed) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        CommitStakeV2.Status before = cs.get(id).status;
        uint256 escrowBefore = usdc.balanceOf(address(cs));

        uint256 fn = fnSeed % 3;
        vm.startPrank(outsider);
        if (fn == 0) {
            try cs.resolve(id, fnSeed % 2 == 0) {
                breach = true;
                breachReason = "outsider resolved";
            } catch {}
        } else if (fn == 1) {
            try cs.challenge(id) {
                breach = true;
                breachReason = "outsider challenged";
            } catch {}
        } else {
            try cs.arbitrate(id, fnSeed % 2 == 0) {
                breach = true;
                breachReason = "outsider arbitrated";
            } catch {}
        }
        vm.stopPrank();

        if (cs.get(id).status != before || usdc.balanceOf(address(cs)) != escrowBefore) {
            breach = true;
            breachReason = "outsider probe mutated state or moved funds";
        }
    }

    /// @dev Role-confusion probe: the WRONG legitimate party calls the role-gated functions
    ///      (verifier challenging, beneficiary arbitrating, non-harmed party challenging...).
    function wrongPartyProbe(uint256 idSeed, uint256 fnSeed) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        CommitStakeV2.Commitment memory c = cs.get(id);
        CommitStakeV2.Status before = c.status;

        if (fnSeed % 2 == 0) {
            // The party NOT harmed by the verdict tries to challenge.
            address notHarmed = c.resolvedPass ? staker : beneficiary;
            vm.prank(notHarmed);
            try cs.challenge(id) {
                breach = true;
                breachReason = "non-harmed party challenged";
            } catch {}
        } else {
            // The verifier tries to rule on its own verdict's dispute.
            vm.prank(verifier);
            try cs.arbitrate(id, true) {
                breach = true;
                breachReason = "verifier arbitrated its own verdict";
            } catch {}
        }
        if (cs.get(id).status != before) {
            breach = true;
            breachReason = "wrong-party probe mutated state";
        }
    }

    /// @dev The verifier (stream recipient) pulls accrued fee mid-life — real money leaves
    ///      StreamPay outside any terminal call, so the fee-escrow-leg invariant is exercised
    ///      against moving per-stream books, not just static deposits. A full post-stop
    ///      withdrawal drives the stream to Ended BEFORE the commitment terminates, covering
    ///      `_settleFeeStream`'s early-Ended branch inside the invariant run.
    function feeWithdrawOp(uint256 idSeed) public {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        uint256 sid = cs.get(id).feeStreamId;
        if (sid == 0) return;
        if (streamPay.get(sid).status != StreamPay.Status.Active) return;
        if (streamPay.recipientBalance(sid) == 0) return;
        vm.prank(verifier);
        streamPay.withdraw(sid, 0); // 0 = withdraw the full available balance
    }

    function warp(uint256 seed) public {
        vm.warp(block.timestamp + bound(seed, 1 minutes, 12 hours));
    }

    // --- ghost bookkeeping ---

    /// @dev THE transition whitelist: any observed transition outside these five edges — or any
    ///      divergence between the mirror and the on-chain status — trips the breach flag. This
    ///      is where the state machine's transition prohibition is enforced; the invariant
    ///      contract's invariant_StateMachineExactlyOneTerminal asserts it.
    function _noteTransition(uint256 id, CommitStakeV2.Status to) internal {
        CommitStakeV2.Status from = ghosts[id].lastStatus;
        bool legal = (from == CommitStakeV2.Status.Active && to == CommitStakeV2.Status.Resolved)
            || (from == CommitStakeV2.Status.Resolved && to == CommitStakeV2.Status.Challenged)
            || (from == CommitStakeV2.Status.Resolved && to == CommitStakeV2.Status.Finalized)
            || (from == CommitStakeV2.Status.Challenged && to == CommitStakeV2.Status.Finalized)
            || (from == CommitStakeV2.Status.Active && to == CommitStakeV2.Status.Expired);
        if (!legal) {
            breach = true;
            breachReason = "illegal state transition";
        }
        if (cs.get(id).status != to) {
            breach = true;
            breachReason = "on-chain status diverged from observed transition";
        }
        ghosts[id].lastStatus = to;
    }

    function _recordTerminal(uint256 id, Snap memory s0) internal {
        Ghost storage g = ghosts[id];
        g.terminalCount += 1;
        if (g.terminal) {
            breach = true;
            breachReason = "second terminal transition on one commitment";
        }
        g.terminal = true;
        g.outcome = cs.get(id).outcome;
        if (g.outcome == CommitStakeV2.Outcome.None) {
            breach = true;
            breachReason = "terminal without recorded outcome";
        }

        // REAL wallet deltas (parties only ever gain at a terminal call).
        uint256 paid = (usdc.balanceOf(staker) - s0.staker)
            + (usdc.balanceOf(verifier) - s0.verifier)
            + (usdc.balanceOf(beneficiary) - s0.beneficiary)
            + (usdc.balanceOf(arbiter) - s0.arbiter);
        g.paidTotal = paid;
        g.burned = usdc.balanceOf(BURN) - s0.burn;
        g.feeReleased = s0.streamPayBal - usdc.balanceOf(address(streamPay));
        g.sliceSlashed = s0.verifierBond - agentBond.bond(verifier);
    }

    function _snap() internal view returns (Snap memory s) {
        s = Snap({
            staker: usdc.balanceOf(staker),
            verifier: usdc.balanceOf(verifier),
            beneficiary: usdc.balanceOf(beneficiary),
            arbiter: usdc.balanceOf(arbiter),
            burn: usdc.balanceOf(BURN),
            streamPayBal: usdc.balanceOf(address(streamPay)),
            verifierBond: agentBond.bond(verifier)
        });
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        if (ids.length == 0) return 0;
        return ids[seed % ids.length];
    }

    // --- enumeration for the invariant contract ---

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function ghostOf(uint256 id) external view returns (Ghost memory) {
        return ghosts[id];
    }
}

/// @dev The five mandated invariants, all checked against the ghost ledger built from real
///      balance deltas:
///      (a) nothing is paid out before a terminal transition,
///      (b) terminal routing conserves value exactly (stake + bond + slashed slice + released
///          fee in == parties paid + §7a burn out),
///      (c) a lie is ALWAYS net-negative for the verifier (slice > stake + max fee, enforced
///          at create and observed on every slashed outcome — under the §7a routing the
///          verifier's loss is unchanged: where the slice GOES does not change what it LOSES),
///      (d) the escrow is solvent: it holds exactly what open commitments are owed (and the
///          contract's own totalEscrowed ledger agrees),
///      (e) the state machine itself: only legal transitions, exactly one terminal outcome per
///          commitment, illegal/unauthorized calls revert without effect — including at the
///          exact window edges. ENFORCED by the handler's breach flag (`_noteTransition` +
///          probes), ASSERTED here by invariant_StateMachineExactlyOneTerminal,
///      (f) the fee-escrow leg (§7): the staker-funded fee deposits are backed 1:1 by
///          StreamPay's real balance for as long as the streams live.
contract CommitStakeV2InvariantTest is Test {
    MockERC20 usdc;
    AgentBond agentBond;
    StreamPay streamPay;
    CommitStakeV2 cs;
    CommitStakeV2Handler handler;

    function setUp() public {
        usdc = new MockERC20();
        agentBond = new AgentBond(AB_IERC20(address(usdc)));
        streamPay = new StreamPay(SP_IERC20(address(usdc)));
        cs = new CommitStakeV2(
            IERC20(address(usdc)),
            IAgentBond(address(agentBond)),
            IStreamPay(address(streamPay))
        );
        handler = new CommitStakeV2Handler(cs, agentBond, streamPay, usdc);
        targetContract(address(handler));
    }

    /// @dev (e) the state machine: no illegal transition, no unauthorized success, no edge
    ///      violation was ever observed; statuses never drift from the observed mirror; every
    ///      terminal commitment terminated exactly once with a recorded, stable outcome.
    function invariant_StateMachineExactlyOneTerminal() public view {
        assertFalse(handler.breach(), handler.breachReason());

        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            uint256 id = handler.ids(i);
            CommitStakeV2Handler.Ghost memory g = handler.ghostOf(id);
            CommitStakeV2.Commitment memory c = cs.get(id);

            assertEq(uint8(c.status), uint8(g.lastStatus), "status drifted without a handler op");
            if (g.terminal) {
                assertEq(g.terminalCount, 1, "exactly one terminal transition");
                assertEq(uint8(c.outcome), uint8(g.outcome), "outcome immutable after terminal");
                assertTrue(
                    c.status == CommitStakeV2.Status.Finalized
                        || c.status == CommitStakeV2.Status.Expired,
                    "terminal status"
                );
            } else {
                assertEq(uint8(c.outcome), uint8(CommitStakeV2.Outcome.None), "no early outcome");
                assertEq(g.paidTotal, 0, "no payout recorded for a live commitment");
            }
        }
    }

    /// @dev (a) + (d): the escrow's REAL token balance equals exactly the sum owed to open
    ///      commitments (their received stake + posted challenge bond) — and the contract's own
    ///      totalEscrowed ledger agrees with the ghost. If anything ever left early the
    ///      equality breaks low; if a payout were short it breaks high.
    function invariant_EscrowHoldsExactlyOpenObligations() public view {
        uint256 owed;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            CommitStakeV2Handler.Ghost memory g = handler.ghostOf(handler.ids(i));
            if (!g.terminal) owed += g.stakeIn + g.bondIn;
        }
        assertEq(usdc.balanceOf(address(cs)), owed, "escrow == open stakes + open bonds");
        assertEq(cs.totalEscrowed(), owed, "contract owed-ledger agrees");
    }

    /// @dev (f) the fee-escrow leg (§7): fee deposits never rest in this escrow — they transit
    ///      to StreamPay inside create (totalEscrowed never books them) and any refund transits
    ///      back out to the staker inside the terminal call. The leg's solvency therefore lives
    ///      in StreamPay's per-stream books (§7 routing: verifier keeps only what accrued, the
    ///      sender reclaims the remainder): its REAL balance equals Σ (deposit − withdrawn)
    ///      over the non-Ended fee streams at all times — accrual, mid-life withdrawals and
    ///      terminal cancels included. Breaks low if fee money ever leaks, high if a cancel
    ///      refund or a withdrawal were short.
    function invariant_FeeEscrowLegFullyBacked() public view {
        uint256 backed;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            uint256 sid = cs.get(handler.ids(i)).feeStreamId;
            if (sid == 0) continue;
            StreamPay.Stream memory s = streamPay.get(sid);
            if (s.status == StreamPay.Status.Ended) continue;
            backed += s.deposit - s.withdrawn;
        }
        assertEq(usdc.balanceOf(address(streamPay)), backed, "fee escrow leg fully backed");
    }

    /// @dev (b): per terminal commitment, what the four parties received PLUS the §7a burn
    ///      equals exactly what that commitment ever took in: stake + challenge bond + slashed
    ///      slice + whatever the fee stream released at the terminal step (accrued to the
    ///      verifier + remainder refunded to the staker by the atomic cancel). Nothing minted,
    ///      nothing lost, no cross-commitment leakage — the burn is a destination, not a leak.
    function invariant_TerminalRoutingConservesValue() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            CommitStakeV2Handler.Ghost memory g = handler.ghostOf(handler.ids(i));
            if (!g.terminal) continue;
            assertEq(
                g.paidTotal + g.burned,
                g.stakeIn + g.bondIn + g.sliceSlashed + g.feeReleased,
                "terminal payout + burn == stake-in + bond-in + slashed slice + released fee"
            );
        }
    }

    /// @dev (c): on every slashed outcome (overturned lie or liveness silence) the verifier's
    ///      measured loss strictly exceeds the stake plus its maximum accruable fee — lying or
    ///      vanishing can never break even, in any branch, fee timing included. The §7a
    ///      re-routing (damage to the harmed party, surplus burned) does not weaken this: the
    ///      verifier loses the slice no matter where it goes. Additionally: a slash always
    ///      burns a strictly-positive surplus. This now holds UNIVERSALLY, not just in the fuzz
    ///      domain: the create-time sizing rule `verifierSlice > amount + feeDeposit + arbiterFee`
    ///      (gate-4 HIGH fix) forces `damage = feeAccrued + min(arbiterFee, bond) <=
    ///      feeDeposit + arbiterFee < slice` on every slash branch, so `surplus = slice - toHarmed`
    ///      is strictly positive by construction. (Before the fix, `arbiterFee` was uncapped and
    ///      this assert passed only because the handler bounded `arbiterFee <= amount` —
    ///      see CommitStakeV2ColdAudit.t.sol.) Clean outcomes never burn.
    function invariant_LieAlwaysNetNegativeForVerifier() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            CommitStakeV2Handler.Ghost memory g = handler.ghostOf(handler.ids(i));
            if (!g.terminal) continue;
            bool slashed = g.outcome == CommitStakeV2.Outcome.OverturnedToPass
                || g.outcome == CommitStakeV2.Outcome.OverturnedToFail
                || g.outcome == CommitStakeV2.Outcome.LivenessSlash;
            if (slashed) {
                assertGt(
                    g.sliceSlashed,
                    g.stakeIn + g.maxFee,
                    "slashed slice strictly exceeds stake + max accruable fee"
                );
                assertGt(g.burned, 0, "a slash always burns the 7a surplus");
                assertLe(g.burned, g.sliceSlashed, "only the slice surplus is ever burned");
            } else {
                assertEq(g.sliceSlashed, 0, "no slash on honest outcomes");
                assertEq(g.burned, 0, "no burn on honest outcomes");
            }
        }
    }
}
