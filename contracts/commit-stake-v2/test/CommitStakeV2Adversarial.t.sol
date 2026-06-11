// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2, IERC20, IAgentBond, IStreamPay} from "../src/CommitStakeV2.sol";
import {AgentBond, IERC20 as AB_IERC20} from "agent-bond/AgentBond.sol";
import {StreamPay, IERC20 as SP_IERC20} from "stream-pay/StreamPay.sol";
import {ReentrantToken, FeeToken, NoReturnToken} from "./mocks/AttackTokens.sol";

/// @dev Adversarial suite — try to break CommitStakeV2:
///      unauthorized callers in every state, double terminal transitions, reentrancy on the
///      payout path, exotic ERC-20s, the AgentBond self-release backstop, and the economic
///      core: a lying verifier ends strictly net-negative in EVERY branch it can reach, and —
///      new with the §7a surplus burn — the staker≡beneficiary raid nets ZERO even when the
///      arbiter errs in the attacker's favour.
contract CommitStakeV2AdversarialTest is V2TestBase {
    // --- access fuzz: the outsider can never move a commitment, in any state ---

    function test_Outsider_CannotTouchActive() public {
        uint256 id = createDefault();

        vm.startPrank(outsider);
        vm.expectRevert(bytes("NOT_VERIFIER"));
        cs.resolve(id, true);
        vm.expectRevert(bytes("NOT_RESOLVED"));
        cs.challenge(id);
        vm.expectRevert(bytes("NOT_CHALLENGED"));
        cs.arbitrate(id, true);
        vm.expectRevert(bytes("NOT_FINALIZABLE"));
        cs.finalize(id);
        vm.expectRevert(bytes("NOT_EXPIRED"));
        cs.slashVerifierExpired(id);
        vm.stopPrank();

        assertStatus(id, CommitStakeV2.Status.Active);
        assertEq(usdc.balanceOf(address(cs)), STAKE, "escrow untouched");
    }

    function test_Outsider_CannotTouchResolved() public {
        uint256 id = createResolved(false);

        vm.startPrank(outsider);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.resolve(id, true);
        vm.expectRevert(bytes("NOT_HARMED_PARTY"));
        cs.challenge(id);
        vm.expectRevert(bytes("NOT_CHALLENGED"));
        cs.arbitrate(id, true);
        vm.expectRevert(bytes("WINDOW_OPEN"));
        cs.finalize(id);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.slashVerifierExpired(id);
        vm.stopPrank();

        assertStatus(id, CommitStakeV2.Status.Resolved);
    }

    function test_Outsider_CannotTouchChallenged() public {
        uint256 id = createChallenged(false);

        vm.startPrank(outsider);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.resolve(id, true);
        vm.expectRevert(bytes("NOT_RESOLVED"));
        cs.challenge(id);
        vm.expectRevert(bytes("NOT_ARBITER"));
        cs.arbitrate(id, true);
        vm.expectRevert(bytes("ARBITER_TIME_LEFT"));
        cs.finalize(id);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.slashVerifierExpired(id);
        vm.stopPrank();

        assertStatus(id, CommitStakeV2.Status.Challenged);
        assertEq(usdc.balanceOf(address(cs)), STAKE + BOND, "stake + bond still escrowed");
    }

    function test_Terminal_NoFunctionWorksAnymore() public {
        // Finalized via arbiter ruling.
        uint256 id = createChallenged(false);
        vm.prank(arbiter);
        cs.arbitrate(id, true);

        vm.expectRevert(bytes("NOT_ACTIVE"));
        vm.prank(verifier);
        cs.resolve(id, true);
        vm.expectRevert(bytes("NOT_RESOLVED"));
        vm.prank(staker);
        cs.challenge(id);
        vm.expectRevert(bytes("NOT_CHALLENGED"));
        vm.prank(arbiter);
        cs.arbitrate(id, false); // no second ruling / flip-flop
        vm.expectRevert(bytes("NOT_FINALIZABLE"));
        cs.finalize(id); // no double finalize
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.slashVerifierExpired(id); // no liveness slash on a settled commitment

        // Expired via liveness slash.
        uint256 id2 = createDefault();
        vm.warp(cs.get(id2).deadline + 1);
        cs.slashVerifierExpired(id2);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.slashVerifierExpired(id2); // no double slash
        vm.expectRevert(bytes("NOT_FINALIZABLE"));
        cs.finalize(id2);
    }

    /// @dev The verifier cannot rule on the dispute about its own verdict, and the parties
    ///      cannot impersonate the arbiter. (The arbiter-conflict requires in create are
    ///      covered in unit tests; this is the runtime side.)
    function test_PartiesCannotArbitrate() public {
        uint256 id = createChallenged(true);
        address[3] memory parties = [verifier, staker, beneficiary];
        for (uint256 i; i < parties.length; i++) {
            vm.expectRevert(bytes("NOT_ARBITER"));
            vm.prank(parties[i]);
            cs.arbitrate(id, false);
        }
    }

    /// @dev A verifier+beneficiary collusion cannot fabricate a challenge on a FAIL verdict to
    ///      farm the slice: on a fail only the STAKER may challenge, so the colluders cannot
    ///      reach the overturn branch at all without the victim acting.
    function test_Collusion_CannotSelfChallenge() public {
        uint256 id = createResolved(false); // false fail by colluding verifier
        vm.expectRevert(bytes("NOT_HARMED_PARTY"));
        vm.prank(beneficiary);
        cs.challenge(id);
        vm.expectRevert(bytes("NOT_HARMED_PARTY"));
        vm.prank(verifier);
        cs.challenge(id);
    }

    // --- reentrancy on the payout path ---

    /// @dev The token reenters finalize/slashVerifierExpired mid-payout. The mutex must hold:
    ///      reentry reverts, exactly one payout happens.
    function test_Reentrancy_FinalizeBlocked() public {
        ReentrantToken evil = new ReentrantToken();
        AgentBond ab = new AgentBond(AB_IERC20(address(evil)));
        StreamPay sp = new StreamPay(SP_IERC20(address(evil)));
        CommitStakeV2 v2 = new CommitStakeV2(
            IERC20(address(evil)), IAgentBond(address(ab)), IStreamPay(address(sp))
        );

        evil.mint(staker, 1_000e6);
        evil.mint(verifier, 1_000e6);
        vm.prank(staker);
        evil.approve(address(v2), type(uint256).max);
        vm.startPrank(verifier);
        evil.approve(address(ab), type(uint256).max);
        ab.deposit(500e6);
        ab.setSlashAllowance(address(v2), type(uint256).max);
        vm.stopPrank();

        CommitStakeV2.CreateParams memory p = defaultParams();
        vm.prank(staker);
        uint256 id = v2.create(p);
        vm.prank(verifier);
        v2.resolve(id, true);
        vm.warp(uint256(v2.get(id).resolvedAt) + WINDOW + 1);

        evil.setTarget(v2, id);
        uint256 stakerBefore = evil.balanceOf(staker);
        v2.finalize(id);

        assertTrue(evil.reentryAttempted(), "attack ran");
        assertTrue(evil.reentryReverted(), "reentry was blocked by the mutex");
        assertEq(evil.balanceOf(staker), stakerBefore + STAKE, "exactly ONE payout");
        assertEq(evil.balanceOf(address(v2)), 0, "no residue, no double spend");
    }

    /// @dev Same attack on the liveness branch — the §7a routing (surplus burn + stake return)
    ///      must not be replayable.
    function test_Reentrancy_LivenessSlashBlocked() public {
        ReentrantToken evil = new ReentrantToken();
        AgentBond ab = new AgentBond(AB_IERC20(address(evil)));
        StreamPay sp = new StreamPay(SP_IERC20(address(evil)));
        CommitStakeV2 v2 = new CommitStakeV2(
            IERC20(address(evil)), IAgentBond(address(ab)), IStreamPay(address(sp))
        );

        evil.mint(staker, 1_000e6);
        evil.mint(verifier, 1_000e6);
        vm.prank(staker);
        evil.approve(address(v2), type(uint256).max);
        vm.startPrank(verifier);
        evil.approve(address(ab), type(uint256).max);
        ab.deposit(500e6);
        ab.setSlashAllowance(address(v2), type(uint256).max);
        vm.stopPrank();

        vm.prank(staker);
        uint256 id = v2.create(defaultParams());
        vm.warp(uint256(v2.get(id).deadline) + 1);

        evil.setTarget(v2, id);
        uint256 stakerBefore = evil.balanceOf(staker);
        v2.slashVerifierExpired(id);

        assertTrue(evil.reentryAttempted(), "attack ran");
        // §7a liveness row, exactly once: stake back to the staker (damage = 0, no fee stream),
        // the whole slice burned.
        assertEq(evil.balanceOf(staker), stakerBefore + STAKE, "stake paid exactly once");
        assertEq(evil.balanceOf(BURN), SLICE, "slice burned exactly once");
        assertEq(evil.balanceOf(address(v2)), 0);
    }

    // --- exotic ERC-20 behaviour (solvency under fee-on-transfer, no-return tolerance) ---

    /// @dev 10% fee-on-transfer: the escrow books what ARRIVED and pays out exactly that —
    ///      never the requested amount. No branch can over-pay the escrow into insolvency.
    function test_FeeOnTransferToken_PayoutsMatchReceived() public {
        FeeToken feeUsdc = new FeeToken(1000); // 10%
        AgentBond ab = new AgentBond(AB_IERC20(address(feeUsdc)));
        StreamPay sp = new StreamPay(SP_IERC20(address(feeUsdc)));
        CommitStakeV2 v2 = new CommitStakeV2(
            IERC20(address(feeUsdc)), IAgentBond(address(ab)), IStreamPay(address(sp))
        );

        feeUsdc.mint(staker, 1_000e6);
        feeUsdc.mint(verifier, 1_000e6);
        vm.prank(staker);
        feeUsdc.approve(address(v2), type(uint256).max);
        vm.startPrank(verifier);
        feeUsdc.approve(address(ab), type(uint256).max);
        ab.deposit(500e6); // books 450e6 after skim
        ab.setSlashAllowance(address(v2), type(uint256).max);
        vm.stopPrank();

        vm.prank(staker);
        uint256 id = v2.create(defaultParams());
        uint256 booked = v2.get(id).amount;
        assertEq(booked, STAKE - STAKE / 10, "booked the received 90, not the requested 100");
        assertEq(feeUsdc.balanceOf(address(v2)), booked, "escrow holds exactly the booked amount");

        vm.prank(verifier);
        v2.resolve(id, true);
        vm.warp(uint256(v2.get(id).resolvedAt) + WINDOW + 1);
        uint256 stakerBefore = feeUsdc.balanceOf(staker);
        v2.finalize(id);
        // The transfer out skims again — but the escrow SENT exactly what it booked.
        assertEq(feeUsdc.balanceOf(staker), stakerBefore + booked - booked / 10);
        assertEq(feeUsdc.balanceOf(address(v2)), 0, "escrow solvent and empty");
    }

    /// @dev USDT-style no-return token: the full liveness path (§7a routing incl. the burn
    ///      transfer) must work via the safe helpers.
    function test_NoReturnToken_FullFlowWorks() public {
        NoReturnToken nrt = new NoReturnToken();
        AgentBond ab = new AgentBond(AB_IERC20(address(nrt)));
        StreamPay sp = new StreamPay(SP_IERC20(address(nrt)));
        CommitStakeV2 v2 = new CommitStakeV2(
            IERC20(address(nrt)), IAgentBond(address(ab)), IStreamPay(address(sp))
        );

        nrt.mint(staker, 1_000e6);
        nrt.mint(verifier, 1_000e6);
        vm.prank(staker);
        nrt.approve(address(v2), type(uint256).max);
        vm.startPrank(verifier);
        nrt.approve(address(ab), type(uint256).max);
        ab.deposit(500e6);
        ab.setSlashAllowance(address(v2), type(uint256).max);
        vm.stopPrank();

        vm.prank(staker);
        uint256 id = v2.create(defaultParams());
        vm.warp(uint256(v2.get(id).deadline) + 1);
        uint256 stakerBefore = nrt.balanceOf(staker);
        v2.slashVerifierExpired(id);
        assertEq(nrt.balanceOf(staker), stakerBefore + STAKE, "stake returned");
        assertEq(nrt.balanceOf(BURN), SLICE, "surplus burned through the no-return token");
    }

    // --- AgentBond backstop: an abandoned escrow cannot hold the verifier hostage,
    //     and a self-released slice cannot brick the staker's stake ---

    function test_Backstop_VerifierSelfReleaseAfterBufferThenStakeStillRecoverable() public {
        uint256 id = createDefault();
        CommitStakeV2.Commitment memory c = cs.get(id);

        // Nobody touches the commitment for the whole window + buffer (abandonment).
        uint64 bondDeadline = c.deadline + WINDOW + ARB_DEADLINE + cs.BOND_DEADLINE_BUFFER();
        vm.warp(uint256(bondDeadline) + 1);

        // The verifier reclaims its slice via the AgentBond backstop (agent self-release).
        uint256 freeBefore = agentBond.freeBondOf(verifier);
        vm.prank(verifier);
        agentBond.release(c.bondObligationId);
        assertEq(agentBond.freeBondOf(verifier), freeBefore + SLICE);

        // The liveness slash must STILL return the stake — slice is gone (0), not a revert.
        uint256 stakerBefore = usdc.balanceOf(staker);
        cs.slashVerifierExpired(id);
        assertStatus(id, CommitStakeV2.Status.Expired);
        assertEq(usdc.balanceOf(staker), stakerBefore + STAKE, "stake recovered, slice forfeited");
        assertEq(usdc.balanceOf(address(cs)), 0);
    }

    /// @dev Before the backstop deadline the verifier can NOT pull its slice out from under an
    ///      open commitment — the normal flow always wins.
    function test_Backstop_VerifierCannotSelfReleaseEarly() public {
        uint256 id = createDefault();
        uint256 obId = cs.get(id).bondObligationId;
        vm.warp(cs.get(id).deadline + 1); // expired, but well inside the buffer
        vm.expectRevert(bytes("NOT_AUTHORIZED"));
        vm.prank(verifier);
        agentBond.release(obId);

        // And the slash still lands on the full slice: stake back, slice burned (§7a).
        uint256 stakerBefore = usdc.balanceOf(staker);
        cs.slashVerifierExpired(id);
        assertEq(usdc.balanceOf(staker), stakerBefore + STAKE);
        assertEq(usdc.balanceOf(BURN), SLICE);
    }

    /// @dev Nobody but the escrow can drive the obligation it opened.
    function test_Backstop_OutsiderCannotReleaseOrSlashObligation() public {
        uint256 id = createDefault();
        uint256 obId = cs.get(id).bondObligationId;
        vm.startPrank(outsider);
        vm.expectRevert(bytes("NOT_AUTHORIZED"));
        agentBond.release(obId);
        vm.expectRevert(bytes("NOT_ENFORCER"));
        agentBond.slash(obId);
        vm.stopPrank();
    }

    /// @dev Hit-and-run is structurally impossible: with the slice locked, the verifier's free
    ///      bond cannot back a second commitment beyond capacity, and withdraw() of locked
    ///      bond reverts inside AgentBond.
    function test_VerifierCannotWithdrawLockedSlice() public {
        createDefault();
        uint256 free = agentBond.freeBondOf(verifier);
        vm.expectRevert(bytes("INSUFFICIENT_FREE"));
        vm.prank(verifier);
        agentBond.withdraw(free + 1);
    }

    // --- the economic core: lying is strictly net-negative in EVERY branch,
    //     and the §7a burn kills the staker≡beneficiary raid ---

    /// @dev False FAIL, overturned: verifier net = -slice (loses more than the stake it tried
    ///      to steal for its accomplice). Measured from real balances, wallet + bond together.
    ///      Unchanged by the §7a re-routing: WHERE the slice goes (damage vs burn) does not
    ///      change WHAT the verifier loses.
    function test_Economics_FalseFailOverturned_VerifierNetNegative() public {
        uint256 vWallet = usdc.balanceOf(verifier);
        uint256 vBond = agentBond.bond(verifier);

        uint256 id = createChallenged(false);
        vm.prank(arbiter);
        cs.arbitrate(id, true);

        int256 net = int256(usdc.balanceOf(verifier) + agentBond.bond(verifier))
            - int256(vWallet + vBond);
        assertEq(net, -int256(SLICE), "verifier lost the full slice");
        assertLt(net, -int256(STAKE), "loss strictly exceeds the stake it gambled for");
    }

    /// @dev False PASS, overturned: same loss. Even if the verifier colluded with the staker
    ///      (stake returned to staker), the COALITION is negative: +stake -slice < 0.
    function test_Economics_FalsePassOverturned_CoalitionNetNegative() public {
        uint256 coalitionBefore =
            usdc.balanceOf(verifier) + agentBond.bond(verifier) + usdc.balanceOf(staker);

        uint256 id = createChallenged(true);
        vm.prank(arbiter);
        cs.arbitrate(id, true);

        uint256 coalitionAfter =
            usdc.balanceOf(verifier) + agentBond.bond(verifier) + usdc.balanceOf(staker);
        // Coalition delta (snapshot taken pre-create): the staker's stake went to the
        // beneficiary on the corrected verdict AND the verifier's slice was slashed.
        assertLt(coalitionAfter, coalitionBefore, "staker+verifier coalition lost money");
        assertEq(coalitionBefore - coalitionAfter, STAKE + SLICE, "stake gone + slice slashed");
    }

    /// @dev Liveness silence: verifier net = -slice, again > stake.
    function test_Economics_Silence_VerifierNetNegative() public {
        uint256 vTotal = usdc.balanceOf(verifier) + agentBond.bond(verifier);
        uint256 id = createDefault();
        vm.warp(cs.get(id).deadline + 1);
        cs.slashVerifierExpired(id);
        uint256 lost = vTotal - (usdc.balanceOf(verifier) + agentBond.bond(verifier));
        assertEq(lost, SLICE);
        assertGt(lost, STAKE);
    }

    /// @dev WITH a fee stream: even if the verifier accrues the ENTIRE fee before the atomic
    ///      cancel lands (worst case of the §7 timing caveat — late challenge, late ruling),
    ///      the lie stays net-negative, because create enforced slice > stake + maxFee.
    function test_Economics_LieNetNegativeEvenWithFullFeeAccrued() public {
        uint256 fee = 40e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 hours);
        // Minimal slice create accepts for this fee + arbiterFee budget (gate-4 HIGH fix).
        p.verifierSlice = STAKE + fee + p.arbiterFee + 1;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);

        uint256 vTotalBefore = usdc.balanceOf(verifier) + agentBond.bond(verifier);

        vm.prank(staker);
        uint256 id = cs.create(p);
        // Verifier lies (false fail) at the deadline to drag timing as late as possible.
        vm.warp(p.deadline);
        vm.prank(verifier);
        cs.resolve(id, false);
        // Challenge lands at the window's last second (= the stream's start); the arbiter rules
        // at ITS last second — wall-clock is then past the stream's stop: the FULL fee accrued
        // before arbitrate's atomic cancel could land. The §7 worst case.
        vm.warp(p.feeStart);
        vm.prank(staker);
        cs.challenge(id);
        vm.warp(uint256(cs.get(id).challengedAt) + ARB_DEADLINE);
        vm.prank(arbiter);
        cs.arbitrate(id, true);

        uint256 vTotalAfter = usdc.balanceOf(verifier) + agentBond.bond(verifier);
        // Verifier: +fee (accrued, paid at the cancel) -slice (slashed) = -(stake + 1):
        // strictly negative, and the lie lost more than the stake its accomplice gained.
        assertEq(vTotalBefore - vTotalAfter, p.verifierSlice - fee);
        assertGt(vTotalBefore - vTotalAfter, STAKE, "net loss strictly exceeds the stake");
    }

    /// @dev Honest baseline for contrast: truth-telling is profitable (fee earned, slice kept).
    function test_Economics_HonestVerifierProfits() public {
        uint256 fee = 40e6;
        CommitStakeV2.CreateParams memory p = paramsWithFee(fee, 1 hours);
        // Sizing now clears amount + feeDeposit + arbiterFee (gate-4 HIGH fix).
        p.verifierSlice = STAKE + fee + p.arbiterFee + 1;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);

        uint256 vTotalBefore = usdc.balanceOf(verifier) + agentBond.bond(verifier);

        vm.prank(staker);
        uint256 id = cs.create(p);
        vm.prank(verifier);
        cs.resolve(id, true);
        vm.warp(uint256(cs.get(id).resolvedAt) + WINDOW + 1);
        cs.finalize(id);

        vm.warp(p.feeStop);
        uint256 sid = cs.get(id).feeStreamId;
        vm.prank(verifier);
        streamPay.withdraw(sid, 0);

        uint256 vTotalAfter = usdc.balanceOf(verifier) + agentBond.bond(verifier);
        assertEq(vTotalAfter, vTotalBefore + fee, "honesty nets exactly the fee");
    }

    /// @dev THE RAID (G1, the spec's live ~17% finding): a staker≡beneficiary attacker
    ///      challenges an HONEST pass, gambling on an arbiter error. Pre-burn routing paid it
    ///      the whole slice on an erroneous overturn — break-even at only ~17% arbiter error.
    ///      With the §7a burn its upside collapses to `damage`, which here only reimburses its
    ///      own arbiter-fee cost: the successful raid nets EXACTLY ZERO, while a failed one
    ///      still loses the whole bond. The attack is strictly -EV at ANY error rate.
    function test_Economics_RaidNetsZeroEvenOnArbiterError() public {
        address raider = address(0x5AD);
        usdc.mint(raider, 1_000_000e6);
        vm.prank(raider);
        usdc.approve(address(cs), type(uint256).max);

        uint256 raiderBefore = usdc.balanceOf(raider);

        // The attacker is BOTH staker and beneficiary: its stake leg always nets to zero.
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.beneficiary = raider;
        vm.prank(raider);
        uint256 id = cs.create(p);

        vm.prank(verifier);
        cs.resolve(id, true); // HONEST pass
        vm.prank(raider); // raider challenges as the "harmed" beneficiary
        cs.challenge(id);
        vm.prank(arbiter);
        cs.arbitrate(id, true); // the arbiter ERRS — the raid's best case

        // Best case nets zero: stake out and back (staker≡beneficiary), bond out, refund
        // (bond - arbiterFee) back, damage (= 0 accrued + arbiterFee) back. The slice — the
        // old prize — went to the burn address, not to the attacker.
        assertEq(usdc.balanceOf(raider), raiderBefore, "successful raid nets exactly zero");
        assertEq(usdc.balanceOf(BURN), SLICE - ARB_FEE, "the prize was burned");

        // And the raid's failure case still costs the full bond (uphold = frivolous branch).
        uint256 beforeFail = usdc.balanceOf(raider);
        uint256 id2;
        {
            CommitStakeV2.CreateParams memory p2 = defaultParams();
            p2.beneficiary = raider;
            vm.prank(raider);
            id2 = cs.create(p2);
        }
        vm.prank(verifier);
        cs.resolve(id2, true);
        vm.prank(raider);
        cs.challenge(id2);
        vm.prank(arbiter);
        cs.arbitrate(id2, false); // arbiter holds: verdict upheld
        // Raider: -stake +stake (upheld pass routes stake to the staker = raider) -bond.
        assertEq(beforeFail - usdc.balanceOf(raider), BOND, "failed raid loses the full bond");
    }

    /// @dev §7a deterrent anatomy: the frivolous challenger's certain loss is the bond
    ///      (arbiterFee + 10-25% of the slice), while the §7a post-burn capturable prize on an
    ///      erroneous overturn is only `damage`. Floor > prize: spam and raid are both -EV.
    function test_Economics_FrivolousChallengeCostsBond() public {
        uint256 bWallet = usdc.balanceOf(beneficiary);
        uint256 id = createChallenged(true); // beneficiary challenges an honest pass
        vm.prank(arbiter);
        cs.arbitrate(id, false);
        assertEq(bWallet - usdc.balanceOf(beneficiary), BOND, "challenger paid the full bond");
        // The §7a inequality the band exists for: bond strictly above the post-burn prize.
        uint256 postBurnPrize = ARB_FEE; // damage on this commitment: 0 accrued + arbiter fee
        assertGt(BOND, postBurnPrize, "certain loss exceeds the capturable upside");
    }
}
