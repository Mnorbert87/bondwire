// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2} from "../src/CommitStakeV2.sol";

/// @dev Regression suite for the per-commitment arbiter opt-in (sockpuppet-arbiter griefing fix).
///      Cold-audit finding: the §7a surplus burn makes a colluding arbiter unable to TAKE the
///      slice, but a staker could still name an only-address-distinct ("sockpuppet") arbiter, have
///      it overturn a CORRECT verdict, and burn an honest verifier's slice — griefing: profitless
///      to the attacker (~gas) but harmful to the honest verifier. The fix requires the verifier to
///      opt in to the exact arbiter address before a staker may name it on the verifier's bond.
contract CommitStakeV2ArbiterOptInTest is V2TestBase {
    address internal sockpuppet = address(0xBAD);

    /// The core attack: a staker pairs the verifier's bond with an arbiter the verifier never
    /// approved. It is address-distinct from all parties (the old conflict checks pass) — but
    /// `create` now reverts before any bond is locked.
    function test_sockpuppetArbiter_blockedAtCreate() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.arbiter = sockpuppet; // distinct from verifier/staker/beneficiary, but NOT approved
        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_NOT_APPROVED"));
        cs.create(p);
    }

    /// The griefing path (lock -> honest pass -> challenge -> sockpuppet overturn -> burn) cannot
    /// even begin: no bond is locked behind an unapproved arbiter.
    function test_griefing_cannotLockHonestVerifierBond() public {
        uint256 freeBefore = agentBond.freeBondOf(verifier);
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.arbiter = sockpuppet;
        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_NOT_APPROVED"));
        cs.create(p);
        assertEq(agentBond.freeBondOf(verifier), freeBefore, "no bond locked");
    }

    /// Opt-in restores the open-market flow: once the verifier approves an arbiter, a staker may use it.
    function test_approveArbiter_enablesCreate() public {
        vm.prank(verifier);
        cs.approveArbiter(sockpuppet, true);
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.arbiter = sockpuppet;
        vm.prank(staker);
        uint256 id = cs.create(p);
        assertEq(cs.get(id).arbiter, sockpuppet, "arbiter set");
    }

    /// A staker cannot self-authorize an arbiter for someone else's bond: approval is keyed on the
    /// verifier (the bonded party), so the staker's own mapping entry does not unlock create.
    function test_onlyVerifierApprovesOwnArbiter() public {
        vm.prank(staker);
        cs.approveArbiter(sockpuppet, true); // writes staker's mapping, not the verifier's
        assertTrue(cs.arbiterApproved(staker, sockpuppet));
        assertFalse(cs.arbiterApproved(verifier, sockpuppet));
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.arbiter = sockpuppet;
        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_NOT_APPROVED"));
        cs.create(p);
    }

    /// Revocation blocks NEW commitments but does not retroactively alter existing ones.
    function test_revokeArbiter_blocksNewKeepsExisting() public {
        uint256 id = createDefault(); // uses the approved default arbiter
        assertEq(cs.get(id).arbiter, arbiter, "existing arbiter intact");

        vm.prank(verifier);
        cs.approveArbiter(arbiter, false); // revoke

        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_NOT_APPROVED"));
        cs.create(defaultParams());

        // the pre-existing commitment is untouched and still resolvable
        vm.prank(verifier);
        cs.resolve(id, true);
        assertStatus(id, CommitStakeV2.Status.Resolved);
    }

    function test_approveArbiter_zeroReverts() public {
        vm.prank(verifier);
        vm.expectRevert(bytes("ARBITER_ZERO"));
        cs.approveArbiter(address(0), true);
    }

    function test_approveArbiter_emitsEvent() public {
        vm.expectEmit(true, true, false, true, address(cs));
        emit CommitStakeV2.ArbiterApproved(verifier, sockpuppet, true);
        vm.prank(verifier);
        cs.approveArbiter(sockpuppet, true);
    }
}
