// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2} from "../src/CommitStakeV2.sol";
import {AgentBond} from "agent-bond/AgentBond.sol";
import {StreamPay} from "stream-pay/StreamPay.sol";

/// @dev Unit tests: every lifecycle branch of CommitStakeV2 with full balance assertions for
///      all four parties + the escrow + the BURN address, every create-time validation, and the
///      §7 fee-stream rules. The real AgentBond / StreamPay are in the loop throughout.
///
///      DISCIPLINE: every terminal-outcome assert below is derived from a ROW of the §7a
///      routing table in VERIFIER_ECONOMICS.md — the test encodes the SPEC, not the code's
///      observed behaviour. Each terminal test names its table row.
contract CommitStakeV2Test is V2TestBase {
    // --- create ---

    function test_Create_EscrowsStakeAndLocksSlice() public {
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 freeBefore = agentBond.freeBondOf(verifier);

        uint256 id = createDefault();

        CommitStakeV2.Commitment memory c = cs.get(id);
        assertEq(c.staker, staker);
        assertEq(c.verifier, verifier);
        assertEq(c.beneficiary, beneficiary);
        assertEq(c.arbiter, arbiter);
        assertEq(c.amount, STAKE);
        assertEq(c.verifierSlice, SLICE);
        assertEq(c.challengeBond, BOND);
        assertEq(c.arbiterFee, ARB_FEE);
        assertEq(uint8(c.status), uint8(CommitStakeV2.Status.Active));
        assertEq(uint8(c.outcome), uint8(CommitStakeV2.Outcome.None));

        // Stake escrowed, nothing else moved; the owed-ledger mirrors it.
        assertEq(usdc.balanceOf(staker), stakerBefore - STAKE);
        assertEq(usdc.balanceOf(address(cs)), STAKE);
        assertEq(cs.totalEscrowed(), STAKE);

        // Slice locked in AgentBond behind an obligation owned by the escrow.
        assertEq(agentBond.freeBondOf(verifier), freeBefore - SLICE);
        AgentBond.Obligation memory o = agentBond.getObligation(c.bondObligationId);
        assertEq(o.agent, verifier);
        assertEq(o.enforcer, address(cs));
        assertEq(o.creditor, address(cs));
        assertEq(o.amount, SLICE);
        assertEq(
            o.deadline,
            c.deadline + WINDOW + ARB_DEADLINE + cs.BOND_DEADLINE_BUFFER(),
            "bond backstop deadline"
        );
    }

    function test_Create_RevertValidation() public {
        CommitStakeV2.CreateParams memory p;

        p = defaultParams();
        p.amount = 0;
        vm.expectRevert(bytes("AMOUNT_ZERO"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.verifier = address(0);
        vm.expectRevert(bytes("VERIFIER_ZERO"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.beneficiary = address(0);
        vm.expectRevert(bytes("BENEFICIARY_ZERO"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.arbiter = address(0);
        vm.expectRevert(bytes("ARBITER_ZERO"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.deadline = uint64(block.timestamp);
        vm.expectRevert(bytes("DEADLINE_PAST"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.challengeWindow = 0;
        vm.expectRevert(bytes("WINDOW_ZERO"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.arbiterDeadline = 0;
        vm.expectRevert(bytes("ARBITER_DEADLINE_ZERO"));
        vm.prank(staker);
        cs.create(p);
    }

    /// @dev Conflict-of-interest: the arbiter must be none of verifier / staker / beneficiary.
    function test_Create_RevertArbiterConflicts() public {
        CommitStakeV2.CreateParams memory p;

        p = defaultParams();
        p.arbiter = verifier;
        vm.expectRevert(bytes("ARBITER_IS_VERIFIER"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.arbiter = staker;
        vm.expectRevert(bytes("ARBITER_IS_STAKER"));
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.arbiter = beneficiary;
        vm.expectRevert(bytes("ARBITER_IS_BENEFICIARY"));
        vm.prank(staker);
        cs.create(p);
    }

    /// @dev §7a post-burn band, lower edge: the bond must cover the arbiter fee plus a 10%-of-
    ///      slice spam margin. Anything below — including a bond that would not even cover the
    ///      arbiter fee — reverts at the floor.
    function test_Create_RevertBondBelowFloor() public {
        // The fixture BOND sits exactly on the floor.
        assertEq(cs.challengeBondFloor(SLICE, ARB_FEE), BOND, "fixture bond == 7a floor");

        CommitStakeV2.CreateParams memory p = defaultParams();
        p.challengeBond = BOND - 1; // 1 micro-USDC below the floor
        vm.expectRevert(bytes("BOND_BELOW_FLOOR"));
        vm.prank(staker);
        cs.create(p);

        // A bond below the arbiter fee alone is below the floor a fortiori.
        p = defaultParams();
        p.challengeBond = ARB_FEE - 1;
        vm.expectRevert(bytes("BOND_BELOW_FLOOR"));
        vm.prank(staker);
        cs.create(p);
    }

    /// @dev §7a band, upper edge: spamMargin <= 25% × slice. An over-sized bond would price the
    ///      (non-consenting) beneficiary out of challenging a false pass — capped at create.
    function test_Create_RevertBondAboveCap() public {
        uint256 cap = cs.challengeBondCap(SLICE, ARB_FEE);
        assertEq(cap, ARB_FEE + (SLICE * 2_500) / 10_000, "cap = fee + 25% slice");

        CommitStakeV2.CreateParams memory p = defaultParams();
        p.challengeBond = cap; // at the cap: fine
        vm.prank(staker);
        cs.create(p);

        p = defaultParams();
        p.challengeBond = cap + 1;
        vm.expectRevert(bytes("BOND_ABOVE_CAP"));
        vm.prank(staker);
        cs.create(p);
    }

    /// @dev The central formula: slice must STRICTLY exceed stake (+ max fee). At equality a
    ///      verifier+beneficiary collusion is net-zero — must revert.
    function test_Create_RevertSliceAtOrBelowStake() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.verifierSlice = STAKE; // equality, no fee stream
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        vm.expectRevert(bytes("SLICE_TOO_SMALL"));
        vm.prank(staker);
        cs.create(p);

        // Stake + arbiterFee is now the floor (gate-4 HIGH fix: slice must clear
        // amount + feeDeposit + arbiterFee). STAKE + 1 alone no longer passes.
        p.verifierSlice = STAKE + p.arbiterFee; // > stake but not > stake + arbiterFee -> reverts
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        vm.expectRevert(bytes("SLICE_TOO_SMALL"));
        vm.prank(staker);
        cs.create(p);

        p.verifierSlice = STAKE + p.arbiterFee + 1; // minimal strict surplus passes
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        vm.prank(staker);
        cs.create(p);
    }

    /// @dev AgentBond enforces capacity: a verifier cannot back commitments beyond its free bond.
    ///      Amount is raised so the bond-exceeding slice still sits within the leverage cap
    ///      (`slice <= 3 × (amount + fee + arbiterFee)`), isolating the INSUFFICIENT_BOND path.
    function test_Create_RevertInsufficientVerifierBond() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = 4_000e6; // cap = 3 × (4_000e6 + ARB_FEE) ≈ 12_015e6 > VERIFIER_BOND
        p.verifierSlice = VERIFIER_BOND + 1; // > free bond, but within the leverage cap
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        vm.expectRevert(bytes("INSUFFICIENT_BOND"));
        vm.prank(staker);
        cs.create(p);
    }

    function test_Create_RevertNoSlashAllowance() public {
        vm.prank(verifier);
        agentBond.setSlashAllowance(address(cs), 0);
        vm.expectRevert(bytes("ALLOWANCE"));
        vm.prank(staker);
        cs.create(defaultParams());
    }

    // --- fee stream (§7): opened BY the escrow, sender-right held for the atomic cancel ---

    function test_Create_WithFee_EscrowOpensStreamAsSender() public {
        uint256 fee = 30e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 days);
        uint256 stakerBefore = usdc.balanceOf(staker);

        vm.prank(staker);
        uint256 id = cs.create(p);

        uint256 sid = cs.get(id).feeStreamId;
        assertTrue(sid != 0, "stream registered");
        StreamPay.Stream memory s = streamPay.get(sid);
        // The escrow is the stream SENDER — that right is what makes the §7 atomic cancel and
        // the on-chain accrued read possible. Funded by the staker, paying the verifier.
        assertEq(s.sender, address(cs), "escrow holds the sender (cancel) right");
        assertEq(s.recipient, verifier);
        assertEq(s.deposit, fee);
        assertEq(s.start, p.feeStart);
        assertEq(usdc.balanceOf(staker), stakerBefore - STAKE - fee, "staker funded stake + fee");
        assertEq(usdc.balanceOf(address(cs)), STAKE, "fee forwarded to StreamPay, not held");
        assertEq(usdc.balanceOf(address(streamPay)), fee);
    }

    function test_Create_WithFee_SizingIncludesFee() public {
        uint256 fee = 30e6;
        // slice == stake + fee must fail (strict inequality).
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 days);
        p.verifierSlice = STAKE + fee;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        vm.expectRevert(bytes("SLICE_TOO_SMALL"));
        vm.prank(staker);
        cs.create(p);

        // The 150% default covers this fee budget: 150e6 > 100e6 + 30e6.
        p = paramsWithFee(fee, 1 days);
        assertEq(p.verifierSlice, SLICE);
        vm.prank(staker);
        cs.create(p);
    }

    /// @dev §7 timing gate: the stream may not start accruing before the latest possible
    ///      unchallenged finalize (deadline + challengeWindow).
    function test_Create_RevertFeeStreamStartsBeforeWindowClose() public {
        CommitStakeV2.CreateParams memory p = paramsWithFee(10e6, 1 days);
        p.feeStart = p.deadline + p.challengeWindow - 1;
        vm.expectRevert(bytes("FEE_STREAM_STARTS_EARLY"));
        vm.prank(staker);
        cs.create(p);
    }

    // --- resolve ---

    function test_Resolve_OpensWindowMovesNoMoney() public {
        uint256 id = createDefault();
        uint256 escrowBefore = usdc.balanceOf(address(cs));
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);

        vm.prank(verifier);
        cs.resolve(id, false); // even a FAIL verdict moves nothing before finalize

        assertStatus(id, CommitStakeV2.Status.Resolved);
        CommitStakeV2.Commitment memory c = cs.get(id);
        assertEq(c.resolvedPass, false);
        assertEq(c.resolvedAt, uint64(block.timestamp));
        assertEq(usdc.balanceOf(address(cs)), escrowBefore, "escrow unchanged");
        assertEq(usdc.balanceOf(staker), stakerBefore, "staker unchanged");
        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore, "beneficiary unchanged");
    }

    function test_Resolve_ExactlyAtDeadlineAllowed() public {
        uint256 id = createDefault();
        vm.warp(cs.get(id).deadline); // last allowed second
        vm.prank(verifier);
        cs.resolve(id, true);
        assertStatus(id, CommitStakeV2.Status.Resolved);
    }

    function test_Resolve_Reverts() public {
        uint256 id = createDefault();

        vm.expectRevert(bytes("NOT_VERIFIER"));
        vm.prank(staker);
        cs.resolve(id, true);

        vm.warp(cs.get(id).deadline + 1);
        vm.expectRevert(bytes("DEADLINE_PASSED"));
        vm.prank(verifier);
        cs.resolve(id, true);

        vm.expectRevert(bytes("NOT_ACTIVE"));
        vm.prank(verifier);
        cs.resolve(999, true); // never created
    }

    // --- clean paths (§7a rows 1-2: no challenge) ---

    function test_CleanPass_StakeToStakerSliceReleased() public {
        uint256 id = createResolved(true);
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 freeBefore = agentBond.freeBondOf(verifier);

        warpPastWindow(id);
        vm.prank(outsider); // finalize is permissionless
        cs.finalize(id);

        // §7a row "Clean pass": stake -> staker (claim), slice released to verifier, no burn.
        assertStatus(id, CommitStakeV2.Status.Finalized);
        assertOutcome(id, CommitStakeV2.Outcome.CleanPass);
        assertEq(usdc.balanceOf(staker), stakerBefore + STAKE, "stake back to staker");
        assertEq(agentBond.freeBondOf(verifier), freeBefore + SLICE, "slice released");
        assertEq(usdc.balanceOf(BURN), 0, "nothing burned on a clean outcome");
        assertEq(usdc.balanceOf(address(cs)), 0, "escrow empty");
    }

    function test_CleanFail_StakeToBeneficiary() public {
        uint256 id = createResolved(false);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 freeBefore = agentBond.freeBondOf(verifier);

        warpPastWindow(id);
        cs.finalize(id);

        // §7a row "Clean fail": stake -> beneficiary, slice released to verifier, no burn.
        assertOutcome(id, CommitStakeV2.Outcome.CleanFail);
        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore + STAKE);
        assertEq(agentBond.freeBondOf(verifier), freeBefore + SLICE, "honest verifier keeps slice");
        assertEq(usdc.balanceOf(BURN), 0);
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    function test_Finalize_RevertWhileWindowOpen() public {
        uint256 id = createResolved(true);
        CommitStakeV2.Commitment memory c = cs.get(id);
        vm.warp(uint256(c.resolvedAt) + c.challengeWindow); // last second: window still open
        vm.expectRevert(bytes("WINDOW_OPEN"));
        cs.finalize(id);
    }

    function test_Finalize_RevertNonFinalizableStates() public {
        uint256 id = createDefault();
        vm.expectRevert(bytes("NOT_FINALIZABLE"));
        cs.finalize(id); // Active

        vm.expectRevert(bytes("NOT_FINALIZABLE"));
        cs.finalize(999); // None

        uint256 done = createResolved(true);
        warpPastWindow(done);
        cs.finalize(done);
        vm.expectRevert(bytes("NOT_FINALIZABLE"));
        cs.finalize(done); // already terminal — no double payout
    }

    // --- liveness branch (§7a row 3: the v1 bug fix, with the surplus burn) ---

    function test_Liveness_StakeReturnedDamageZeroSliceBurned() public {
        uint256 id = createDefault(); // no fee stream -> feeAccrued = 0 -> damage = 0
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 bondBefore = agentBond.bond(verifier);

        vm.warp(cs.get(id).deadline + 1);
        vm.prank(outsider); // anyone can trigger
        cs.slashVerifierExpired(id);

        // §7a row "Liveness": stake returned to staker; staker gets damage = fee accrued to the
        // no-show verifier (zero here — no fee stream) + zero arbiter cost; surplus -> BURN.
        assertStatus(id, CommitStakeV2.Status.Expired);
        assertOutcome(id, CommitStakeV2.Outcome.LivenessSlash);
        assertEq(usdc.balanceOf(staker), stakerBefore + STAKE, "stake returned, damage = 0");
        assertEq(usdc.balanceOf(BURN), SLICE, "entire slice burned (damage was zero)");
        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore, "beneficiary gets NOTHING");
        assertEq(agentBond.bond(verifier), bondBefore - SLICE, "slice slashed from bond");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    /// @dev §7a liveness row with a REAL accrued fee: the slash lands after the stream started,
    ///      so the no-show verifier has pulled real fee. damage = that accrued amount (read from
    ///      StreamPay state, not a parameter), surplus burned, remainder of the fee deposit
    ///      auto-refunded to the staker by the ATOMIC cancel inside slashVerifierExpired.
    function test_Liveness_WithAccruedFee_DamageToStakerSurplusBurned() public {
        uint256 fee = 20e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 days);
        vm.prank(staker);
        uint256 id = cs.create(p);
        uint256 sid = cs.get(id).feeStreamId;

        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 verifierBefore = usdc.balanceOf(verifier);

        // Nobody resolves; the slash only lands HALFWAY through the fee stream.
        vm.warp(uint256(p.feeStart) + 12 hours);
        uint256 accrued = streamPay.streamedTotal(sid);
        assertEq(accrued, fee / 2, "half the fee accrued to the no-show verifier");

        cs.slashVerifierExpired(id);

        // Atomic cancel: verifier keeps only the accrued half; the unstreamed half refunds to
        // the staker in the SAME transaction (the contract does not rely on the staker).
        assertEq(usdc.balanceOf(verifier), verifierBefore + accrued, "verifier: accrued only");
        assertEq(uint8(streamPay.get(sid).status), uint8(StreamPay.Status.Ended), "stream dead");
        // §7a: staker gets stake back + damage (= accrued fee; arbiter cost zero) + fee refund.
        assertEq(
            usdc.balanceOf(staker),
            stakerBefore + STAKE + accrued + (fee - accrued),
            "staker: stake + damage + unstreamed fee refund"
        );
        // Surplus burned: slice - damage.
        assertEq(usdc.balanceOf(BURN), p.verifierSlice - accrued, "surplus -> BURN");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    function test_Liveness_RevertBeforeOrAfterWrongState() public {
        uint256 id = createDefault();
        vm.warp(cs.get(id).deadline); // exactly at deadline: verifier still has time
        vm.expectRevert(bytes("NOT_EXPIRED"));
        cs.slashVerifierExpired(id);

        uint256 resolved = createResolved(true);
        vm.warp(cs.get(resolved).deadline + 1);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.slashVerifierExpired(resolved); // resolved in time -> liveness arm closed
    }

    // --- challenge ---

    function test_Challenge_OnlyHarmedPartyWithinWindow() public {
        uint256 id = createResolved(false); // fail verdict harms the staker
        uint256 stakerBefore = usdc.balanceOf(staker);

        vm.prank(staker);
        cs.challenge(id);

        assertStatus(id, CommitStakeV2.Status.Challenged);
        assertEq(usdc.balanceOf(staker), stakerBefore - BOND, "bond escrowed");
        assertEq(cs.get(id).challengeBondPaid, BOND);
        assertEq(usdc.balanceOf(address(cs)), STAKE + BOND);
        assertEq(cs.totalEscrowed(), STAKE + BOND);
    }

    function test_Challenge_RevertNotHarmedParty() public {
        // fail verdict: only the staker is harmed.
        uint256 failId = createResolved(false);
        vm.expectRevert(bytes("NOT_HARMED_PARTY"));
        vm.prank(beneficiary);
        cs.challenge(failId);
        vm.expectRevert(bytes("NOT_HARMED_PARTY"));
        vm.prank(outsider);
        cs.challenge(failId);

        // pass verdict: only the beneficiary is harmed.
        uint256 passId = createResolved(true);
        vm.expectRevert(bytes("NOT_HARMED_PARTY"));
        vm.prank(staker);
        cs.challenge(passId);
    }

    function test_Challenge_RevertOutsideWindowOrWrongState() public {
        uint256 id = createResolved(false);
        CommitStakeV2.Commitment memory c = cs.get(id);
        vm.warp(uint256(c.resolvedAt) + c.challengeWindow + 1);
        vm.expectRevert(bytes("WINDOW_CLOSED"));
        vm.prank(staker);
        cs.challenge(id);

        uint256 active = createDefault();
        vm.expectRevert(bytes("NOT_RESOLVED"));
        vm.prank(staker);
        cs.challenge(active);

        uint256 challenged = createChallenged(false);
        vm.expectRevert(bytes("NOT_RESOLVED")); // no double challenge
        vm.prank(staker);
        cs.challenge(challenged);
    }

    /// @dev Edge mandated by the spec: a challenge in the window's LAST second wins over a
    ///      same-block finalize. The two bounds are mutually exclusive by construction.
    function test_Challenge_LastSecondBeatsSameBlockFinalize() public {
        uint256 id = createResolved(false);
        CommitStakeV2.Commitment memory c = cs.get(id);
        vm.warp(uint256(c.resolvedAt) + c.challengeWindow); // exact window end

        vm.expectRevert(bytes("WINDOW_OPEN"));
        cs.finalize(id); // finalize cannot fire yet...

        vm.prank(staker);
        cs.challenge(id); // ...the challenge can

        vm.expectRevert(bytes("ARBITER_TIME_LEFT"));
        cs.finalize(id); // and the same-block finalize now sees Challenged
    }

    // --- arbitrate: overturn (§7a rows 4-5: damage to the harmed party, surplus burned) ---

    function test_Overturn_FalseFail_DamageToStakerSurplusBurned() public {
        uint256 id = createChallenged(false); // false fail, staker challenged
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 arbiterBefore = usdc.balanceOf(arbiter);
        uint256 verifierBondBefore = agentBond.bond(verifier);

        vm.prank(arbiter);
        cs.arbitrate(id, true);

        assertStatus(id, CommitStakeV2.Status.Finalized);
        assertOutcome(id, CommitStakeV2.Outcome.OverturnedToPass);
        // §7a row "False fail overturned":
        //   stake -> staker (corrected verdict);
        //   damage = feeAccruedToLyingVerifier (0, no stream) + challengerArbiterFeeCost
        //          = ARB_FEE -> staker (the harmed party per the table);
        //   surplus slice - damage -> BURN;
        //   challenge bond refunded minus the arbiter fee; arbiter paid for ruling.
        uint256 damage = 0 + ARB_FEE;
        assertEq(
            usdc.balanceOf(staker),
            stakerBefore + STAKE + damage + (BOND - ARB_FEE),
            "staker: corrected stake + damage + bond refund"
        );
        assertEq(usdc.balanceOf(BURN), SLICE - damage, "surplus -> BURN, never a party");
        assertEq(usdc.balanceOf(arbiter), arbiterBefore + ARB_FEE, "arbiter paid for ruling");
        assertEq(agentBond.bond(verifier), verifierBondBefore - SLICE, "lying verifier slashed");
        assertEq(usdc.balanceOf(address(cs)), 0, "escrow fully drained");
    }

    function test_Overturn_FalsePass_DamageToBeneficiarySurplusBurned() public {
        uint256 id = createChallenged(true); // false pass, beneficiary challenged
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 arbiterBefore = usdc.balanceOf(arbiter);

        vm.prank(arbiter);
        cs.arbitrate(id, true);

        assertOutcome(id, CommitStakeV2.Outcome.OverturnedToFail);
        // §7a row "False pass overturned": stake -> beneficiary (corrected verdict), the
        // harmed BENEFICIARY gets damage only, surplus burned, bond refunded minus fee.
        // This is the anti-raid fix: the old routing paid the whole slice here.
        uint256 damage = 0 + ARB_FEE;
        assertEq(
            usdc.balanceOf(beneficiary),
            beneficiaryBefore + STAKE + damage + (BOND - ARB_FEE),
            "beneficiary: corrected stake + damage + bond refund"
        );
        assertEq(usdc.balanceOf(BURN), SLICE - damage, "surplus -> BURN");
        assertEq(usdc.balanceOf(staker), stakerBefore, "lying-verdict staker gets nothing");
        assertEq(usdc.balanceOf(arbiter), arbiterBefore + ARB_FEE);
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    /// @dev Overturn with a REAL accrued fee: damage = feeAccrued + arbiter cost, where the
    ///      accrued part is read from StreamPay state at the slash (never caller-supplied), and
    ///      the fee stream dies atomically inside arbitrate.
    function test_Overturn_WithAccruedFee_DamageIncludesOnChainAccrued() public {
        uint256 fee = 20e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 hours);
        vm.prank(staker);
        uint256 id = cs.create(p);
        uint256 sid = cs.get(id).feeStreamId;

        // Lie at the deadline, challenge at the window's last second (= stream start).
        vm.warp(p.deadline);
        vm.prank(verifier);
        cs.resolve(id, false);
        vm.warp(p.feeStart);
        vm.prank(staker);
        cs.challenge(id);

        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 verifierBefore = usdc.balanceOf(verifier);

        // Arbiter rules 30 min into the 1-hour stream: half the fee has accrued.
        vm.warp(block.timestamp + 30 minutes);
        uint256 accrued = streamPay.streamedTotal(sid);
        assertEq(accrued, fee / 2);
        vm.prank(arbiter);
        cs.arbitrate(id, true);

        uint256 damage = accrued + ARB_FEE;
        assertEq(uint8(streamPay.get(sid).status), uint8(StreamPay.Status.Ended), "atomic cancel");
        assertEq(usdc.balanceOf(verifier), verifierBefore + accrued, "verifier kept accrued only");
        assertEq(
            usdc.balanceOf(staker),
            stakerBefore + STAKE + damage + (BOND - ARB_FEE) + (fee - accrued),
            "staker: stake + damage + bond refund + unstreamed fee refund"
        );
        assertEq(usdc.balanceOf(BURN), p.verifierSlice - damage, "surplus -> BURN");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    // --- arbitrate: uphold (§7a row 6, anti-grief branch) ---

    function test_Uphold_FrivolousChallengerLosesBond() public {
        uint256 id = createChallenged(true); // beneficiary frivolously challenges a pass
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 verifierWalletBefore = usdc.balanceOf(verifier);
        uint256 arbiterBefore = usdc.balanceOf(arbiter);
        uint256 freeBefore = agentBond.freeBondOf(verifier);

        vm.prank(arbiter);
        cs.arbitrate(id, false);

        // §7a row "Frivolous challenge": stake per the upheld verdict, slice released,
        // challenger bond slashed -> arbiter fee + remainder (fee-scale pennies at the §7a
        // band) to the honest verifier.
        assertOutcome(id, CommitStakeV2.Outcome.UpheldPass);
        assertEq(usdc.balanceOf(staker), stakerBefore + STAKE, "verdict stands");
        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore, "challenger bond gone");
        assertEq(usdc.balanceOf(arbiter), arbiterBefore + ARB_FEE, "fee on uphold too");
        assertEq(
            usdc.balanceOf(verifier),
            verifierWalletBefore + (BOND - ARB_FEE),
            "bond remainder to the honest verifier"
        );
        assertEq(agentBond.freeBondOf(verifier), freeBefore + SLICE, "slice released");
        assertEq(usdc.balanceOf(BURN), 0, "no slash, no burn");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    function test_Uphold_Fail_StakeStillToBeneficiary() public {
        uint256 id = createChallenged(false); // staker frivolously challenges a fail
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 stakerBefore = usdc.balanceOf(staker);

        vm.prank(arbiter);
        cs.arbitrate(id, false);

        assertOutcome(id, CommitStakeV2.Outcome.UpheldFail);
        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore + STAKE);
        assertEq(usdc.balanceOf(staker), stakerBefore, "challenger bond slashed");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    function test_Arbitrate_Reverts() public {
        uint256 id = createChallenged(false);

        vm.expectRevert(bytes("NOT_ARBITER"));
        vm.prank(outsider);
        cs.arbitrate(id, true);
        vm.expectRevert(bytes("NOT_ARBITER"));
        vm.prank(verifier);
        cs.arbitrate(id, true);

        uint256 resolved = createResolved(false);
        vm.expectRevert(bytes("NOT_CHALLENGED"));
        vm.prank(arbiter);
        cs.arbitrate(resolved, true);

        CommitStakeV2.Commitment memory c = cs.get(id);
        vm.warp(uint256(c.challengedAt) + c.arbiterDeadline + 1);
        vm.expectRevert(bytes("ARBITER_LATE"));
        vm.prank(arbiter);
        cs.arbitrate(id, true);
    }

    /// @dev Edge: a ruling at the arbiter deadline's exact last second is valid, and a
    ///      same-block silence-finalize cannot run.
    function test_Arbitrate_LastSecondBeatsSilenceFinalize() public {
        uint256 id = createChallenged(false);
        CommitStakeV2.Commitment memory c = cs.get(id);
        vm.warp(uint256(c.challengedAt) + c.arbiterDeadline);

        vm.expectRevert(bytes("ARBITER_TIME_LEFT"));
        cs.finalize(id);

        vm.prank(arbiter);
        cs.arbitrate(id, true);
        assertOutcome(id, CommitStakeV2.Outcome.OverturnedToPass);
    }

    // --- arbiter silence: fails closed ---

    function test_ArbiterSilence_VerdictStandsBondReturnedArbiterUnpaid() public {
        uint256 id = createChallenged(true); // beneficiary challenged a pass
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 arbiterBefore = usdc.balanceOf(arbiter);
        uint256 freeBefore = agentBond.freeBondOf(verifier);

        warpPastArbiterDeadline(id);
        vm.prank(outsider);
        cs.finalize(id);

        assertOutcome(id, CommitStakeV2.Outcome.SilencePass);
        assertEq(usdc.balanceOf(staker), stakerBefore + STAKE, "original verdict stands");
        assertEq(
            usdc.balanceOf(beneficiary),
            beneficiaryBefore + BOND,
            "bond returned in full - silence proves nothing frivolous"
        );
        assertEq(usdc.balanceOf(arbiter), arbiterBefore, "no ruling, no pay");
        assertEq(agentBond.freeBondOf(verifier), freeBefore + SLICE);
        assertEq(usdc.balanceOf(BURN), 0, "fail-closed slashes nobody");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    function test_ArbiterSilence_FailVerdict() public {
        uint256 id = createChallenged(false); // staker challenged a fail
        uint256 stakerBefore = usdc.balanceOf(staker);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);

        warpPastArbiterDeadline(id);
        cs.finalize(id);

        assertOutcome(id, CommitStakeV2.Outcome.SilenceFail);
        assertEq(usdc.balanceOf(beneficiary), beneficiaryBefore + STAKE, "fail verdict stands");
        assertEq(usdc.balanceOf(staker), stakerBefore + BOND, "challenger refunded");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    // --- full StreamPay composition (§7 timing-gated fee) ---

    function test_FeeStream_CleanPassVerifierEarnsFee() public {
        uint256 fee = 20e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 days);
        vm.prank(staker);
        uint256 id = cs.create(p);
        uint256 sid = cs.get(id).feeStreamId;

        vm.prank(verifier);
        cs.resolve(id, true);
        warpPastWindow(id);
        cs.finalize(id);

        // Fee accrues only after the gate; the verifier collects it post-finalize.
        vm.warp(p.feeStop);
        uint256 verifierBefore = usdc.balanceOf(verifier);
        vm.prank(verifier);
        streamPay.withdraw(sid, 0);
        assertEq(usdc.balanceOf(verifier), verifierBefore + fee, "full fee earned honestly");
    }

    /// @dev §7 slash-branch gating, now contract-enforced: the cancel happens INSIDE arbitrate
    ///      (this contract is the stream sender) — the staker does not need to remember, and
    ///      the unstreamed fee comes back in the same transaction.
    function test_FeeStream_SlashCancelsAtomicallyAndRefundsStaker() public {
        uint256 fee = 20e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 days);
        vm.prank(staker);
        uint256 id = cs.create(p);
        uint256 sid = cs.get(id).feeStreamId;

        vm.prank(verifier);
        cs.resolve(id, false); // false fail
        vm.prank(staker);
        cs.challenge(id);

        uint256 stakerBefore = usdc.balanceOf(staker);
        vm.prank(arbiter);
        cs.arbitrate(id, true); // overturned -> slash branch

        // The gate held the start past the window and the ruling came early: nothing accrued,
        // the ENTIRE fee deposit is back at the staker — no separate cancel transaction.
        assertEq(uint8(streamPay.get(sid).status), uint8(StreamPay.Status.Ended), "cancelled");
        uint256 damage = 0 + ARB_FEE; // feeAccrued = 0
        assertEq(
            usdc.balanceOf(staker),
            stakerBefore + STAKE + damage + (BOND - ARB_FEE) + fee,
            "stake + damage + bond refund + FULL fee refund, atomically"
        );
    }

    /// @dev The verifier (stream recipient) cancels the fee stream EARLY: StreamPay refunds the
    ///      unstreamed remainder to the escrow (the stream sender) before any terminal step.
    ///      The escrow must forward that unbooked residue to the staker at finalize — not
    ///      strand it, and never pay it from another commitment's funds.
    function test_FeeStream_RecipientEarlyCancelResidueForwardedToStaker() public {
        uint256 fee = 20e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 days);
        vm.prank(staker);
        uint256 id = cs.create(p);
        uint256 sid = cs.get(id).feeStreamId;

        // Verifier resolves honestly, then cancels its own fee stream before anything accrued.
        vm.prank(verifier);
        cs.resolve(id, true);
        vm.prank(verifier);
        streamPay.cancel(sid);
        assertEq(usdc.balanceOf(address(cs)), STAKE + fee, "refund parked in the escrow");
        assertEq(cs.totalEscrowed(), STAKE, "refund is unbooked surplus");

        uint256 stakerBefore = usdc.balanceOf(staker);
        warpPastWindow(id);
        cs.finalize(id);

        assertEq(
            usdc.balanceOf(staker),
            stakerBefore + STAKE + fee,
            "stake + parked fee residue both forwarded"
        );
        assertEq(usdc.balanceOf(address(cs)), 0, "nothing stranded");
    }

    // --- views ---

    function test_ChallengeBondFloorAndCap() public view {
        // floor = arbiterFee + ceil(10% x slice); cap = arbiterFee + 25% x slice.
        assertEq(cs.challengeBondFloor(150e6, 5e6), 20e6);
        assertEq(cs.challengeBondCap(150e6, 5e6), 42.5e6);
        // Rounding: the floor's margin never rounds to zero.
        assertEq(cs.challengeBondFloor(1, 0), 1); // ceil(0.1) = 1
        assertEq(cs.challengeBondFloor(10, 0), 1);
        assertEq(cs.challengeBondFloor(11, 0), 2);
        // The floor is sized on the SLICE, not the stake — and it includes the arbiter fee.
        assertEq(cs.challengeBondFloor(150e6, 0), 15e6);
    }

    function test_RecommendedSlice_DefaultAndLargeFeeGuard() public view {
        // Fee below 50% of stake: the 150% default rules.
        assertEq(cs.recommendedSlice(100e6, 0), 150e6);
        assertEq(cs.recommendedSlice(100e6, 49e6), 150e6);
        // Fee at/above 50%: the guard takes over with a strict surplus.
        assertEq(cs.recommendedSlice(100e6, 50e6), 150e6 + 1);
        assertEq(cs.recommendedSlice(100e6, 80e6), 180e6 + 1);
    }
}
