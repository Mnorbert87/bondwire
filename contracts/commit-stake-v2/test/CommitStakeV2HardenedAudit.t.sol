// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2, IAgentBond} from "../src/CommitStakeV2.sol";
import {AgentBond} from "agent-bond/AgentBond.sol";

/// @dev Adversarial counter-tests written during the 2026-07-29 hardened-branch audit.
///      Each test encodes a specific attack idea against the THREE new fixes landing together
///      (arbiter opt-in, time/leverage ceilings, AgentBond grant generations) and pins a
///      behaviour that was previously unasserted. See HARDENED_AUDIT_2026-07-29.md.
contract CommitStakeV2HardenedAuditTest is V2TestBase {
    // ---------------------------------------------------------------------
    // F3. The leverage cap and the bond-band floor carve out an UNSATISFIABLE region.
    //     Before this branch a 1 micro-USDC commitment was legal (slice = 4 satisfied both
    //     `slice > amount` and `slice >= 4`). Now:
    //       slice >= 4                (SLICE_TOO_SMALL_FOR_BOND_BAND)
    //       slice <= 3 * 1 = 3        (SLICE_ABOVE_LEVERAGE_CAP)
    //     -> no legal slice exists; `create` reverts for EVERY slice value.
    //     `amount > 0` is the only lower bound, so amount = 1 is valid input.
    // ---------------------------------------------------------------------
    function test_F3_leverageCap_makesDustCommitmentUnconstructible() public {
        for (uint256 slice = 1; slice <= 12; slice++) {
            CommitStakeV2.CreateParams memory p = defaultParams();
            p.amount = 1;
            p.arbiterFee = 0;
            p.feeDeposit = 0;
            p.verifierSlice = slice;
            p.challengeBond = cs.challengeBondFloor(slice, 0);

            bool constructed;
            vm.prank(staker);
            try cs.create(p) returns (uint256) {
                constructed = true;
            } catch {
                constructed = false;
            }
            assertFalse(constructed, "amount=1 must be unconstructible at every slice");
        }
    }

    /// The hole is exactly the V = 1 point, not a general "dust is banned" rule.
    function test_F3_amountTwo_isStillConstructible() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = 2;
        p.arbiterFee = 0;
        p.feeDeposit = 0;
        p.verifierSlice = 4; // >= 4, > 2, <= 3*2 = 6
        p.challengeBond = cs.challengeBondFloor(4, 0);

        vm.prank(staker);
        uint256 id = cs.create(p);
        assertGt(id, 0, "amount=2 must remain constructible");
    }

    // ---------------------------------------------------------------------
    // F4. Role collision the distinctness checks do NOT cover: beneficiary == verifier.
    //     `create` rejects arbiter==verifier / arbiter==staker / arbiter==beneficiary, but
    //     says nothing about beneficiary==verifier. With that pairing a FAIL verdict routes
    //     the stake to the verifier itself, so the judge DOES pay itself. THREAT_MODEL §1
    //     says "it cannot pay itself"; that holds only because the staker is assumed to pick
    //     a sane beneficiary. Pinned here so code and claim cannot drift apart silently.
    // ---------------------------------------------------------------------
    function test_F4_beneficiaryEqualsVerifier_letsTheJudgePayItself() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.beneficiary = verifier; // NOT rejected by any check

        vm.prank(staker);
        uint256 id = cs.create(p);

        uint256 before = usdc.balanceOf(verifier);

        vm.prank(verifier);
        cs.resolve(id, false); // FAIL -> stake routes to beneficiary (== verifier)

        vm.warp(block.timestamp + WINDOW + 1);
        cs.finalize(id);

        assertEq(
            usdc.balanceOf(verifier) - before,
            STAKE,
            "verifier received the full stake as its own beneficiary"
        );
    }

    // ---------------------------------------------------------------------
    // F5. staker == verifier self-dealing: one address funds the escrow and judges it.
    //     Not rejected. Asserted to be value-neutral and to leave bond accounting intact.
    // ---------------------------------------------------------------------
    function test_F5_stakerEqualsVerifier_isNeutralButAllowed() public {
        vm.startPrank(staker);
        usdc.approve(address(agentBond), type(uint256).max);
        agentBond.deposit(VERIFIER_BOND);
        agentBond.setSlashAllowance(address(cs), type(uint256).max);
        cs.approveArbiter(arbiter, true);
        vm.stopPrank();

        CommitStakeV2.CreateParams memory p = defaultParams();
        p.verifier = staker; // same address in both roles

        uint256 freeBefore = agentBond.freeBondOf(staker);
        uint256 balBefore = usdc.balanceOf(staker);

        vm.prank(staker);
        uint256 id = cs.create(p);

        vm.prank(staker);
        cs.resolve(id, true); // PASS -> stake returns to staker

        vm.warp(block.timestamp + WINDOW + 1);
        cs.finalize(id);

        assertEq(usdc.balanceOf(staker), balBefore, "self-dealt commitment must be value-neutral");
        assertEq(agentBond.freeBondOf(staker), freeBefore, "slice must be fully returned");
    }

    // ---------------------------------------------------------------------
    // F6. Arbiter approval revoked while a commitment is ALREADY live. Documented as
    //     intentional ("existing ones keep the arbiter"), never asserted. If it ever became
    //     a live check, an in-flight dispute would be unarbitrable and funds would hang.
    // ---------------------------------------------------------------------
    function test_F6_revokingArbiterMidFlight_doesNotStrandTheDispute() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        vm.prank(staker);
        uint256 id = cs.create(p);

        vm.prank(verifier);
        cs.resolve(id, true); // PASS -> harmed party is the beneficiary

        vm.prank(verifier);
        cs.approveArbiter(arbiter, false); // revoke AFTER creation

        // A new commitment naming that arbiter is now blocked...
        CommitStakeV2.CreateParams memory p2 = defaultParams();
        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_NOT_APPROVED"));
        cs.create(p2);

        // ...but the live one still reaches a terminal state through the revoked arbiter.
        vm.prank(beneficiary);
        cs.challenge(id);
        vm.prank(arbiter);
        cs.arbitrate(id, true); // overturn

        CommitStakeV2.Commitment memory c = cs.get(id);
        assertTrue(uint8(c.status) != 0, "live dispute must still reach a terminal state");
        assertTrue(uint8(c.outcome) != 0, "terminal outcome must be recorded");
    }

    // ---------------------------------------------------------------------
    // F7. Aggregate leverage: the per-commitment cap bounds ONE job, but N commitments stack.
    //     Measures the real capital ratio needed to pin a verifier's bond, so the claim can be
    //     stated in aggregate terms rather than per-commitment terms.
    // ---------------------------------------------------------------------
    function test_F7_aggregateLeverage_stacksAcrossCommitments() public {
        uint256 lockedTotal;
        uint256 escrowedTotal;

        for (uint256 i; i < 5; i++) {
            CommitStakeV2.CreateParams memory p = defaultParams();
            p.verifierSlice = 3 * (STAKE + ARB_FEE); // exactly at the cap
            p.challengeBond = cs.challengeBondFloor(p.verifierSlice, ARB_FEE);
            vm.prank(staker);
            cs.create(p);
            lockedTotal += p.verifierSlice;
            escrowedTotal += STAKE;
        }

        assertEq(
            VERIFIER_BOND - agentBond.freeBondOf(verifier),
            lockedTotal,
            "each commitment locks its full slice; the per-commitment caps do not interact"
        );
        assertGe(lockedTotal, escrowedTotal * 3, "3x aggregate leverage is reachable");
    }

    // ---------------------------------------------------------------------
    // F12. Direct interface-conformance guard for the decode that money depends on.
    //      `_releaseSliceIfActive` / `_slashSliceIfActive` (CommitStakeV2.sol:819, :829) read
    //      `getObligation(id).status` through the hand-copied IAgentBond struct and FAIL SILENTLY
    //      when it does not say Active — a skipped slash, not a revert. Reverting the interface to
    //      its old six-field form is currently caught by exactly ONE test in the whole suite
    //      (`test_Backstop_VerifierSelfReleaseAfterBufferThenStakeStillRecoverable`), incidentally
    //      and with an opaque NOT_ACTIVE. This asserts the decode itself, field for field.
    // ---------------------------------------------------------------------
    function test_F12_obligationDecodeMatchesAgentBond_fieldForField() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        vm.prank(staker);
        uint256 id = cs.create(p);

        uint256 obId = cs.get(id).bondObligationId;

        // What CommitStakeV2 sees through its own copied interface...
        IAgentBond.Obligation memory viaInterface = IAgentBond(address(agentBond)).getObligation(obId);
        // ...must equal what AgentBond itself reports.
        AgentBond.Obligation memory real = agentBond.getObligation(obId);

        assertEq(viaInterface.agent, real.agent, "agent");
        assertEq(viaInterface.enforcer, real.enforcer, "enforcer");
        assertEq(viaInterface.creditor, real.creditor, "creditor");
        assertEq(viaInterface.amount, real.amount, "amount");
        assertEq(uint256(viaInterface.deadline), uint256(real.deadline), "deadline");
        assertEq(
            uint256(viaInterface.allowanceEpoch), uint256(real.allowanceEpoch), "allowanceEpoch"
        );
        assertEq(uint8(viaInterface.status), uint8(real.status), "status");
        assertEq(uint8(viaInterface.status), 1, "a fresh obligation must decode as Active(1)");
    }
}
