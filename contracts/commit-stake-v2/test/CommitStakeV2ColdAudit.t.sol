// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2} from "../src/CommitStakeV2.sol";

/// @dev Gate-4 cold-audit regressions (HIGH finding, now FIXED). These started life as two
///      *demonstration* tests proving the gap; per the Phase-1 probe pattern they are now flipped
///      into *guards* so the closed hole stays closed.
///
///      ORIGINAL FINDING: `arbiterFee` was an unbounded staker-chosen create parameter feeding
///      the 7a `damage` term (`damage = feeAccrued + min(arbiterFee, bond)`, CommitStakeV2.sol).
///      With `arbiterFee >= slice`, `damage >= slice` => `toHarmed = slice`, `surplus = 0`: the
///      7a surplus-burn was disabled and a `staker==beneficiary` raid with a colluding arbiter
///      recaptured the entire slashed slice.
///
///      FIX (CommitStakeV2.sol create()): the sizing rule is now
///      `verifierSlice > amount + feeDeposit + arbiterFee` (strict), which subsumes the old
///      `> amount + feeDeposit`. So `damage = feeAccrued + min(arbiterFee, bond)
///      <= feeDeposit + arbiterFee < slice` ALWAYS => `surplus > 0` on every slash branch, by
///      construction. The hostile region (`arbiterFee >= slice - amount - feeDeposit`) is now
///      rejected at create.
///
///      ERROR-CLASS LESSON (same as the Phase-1 fee-on-transfer finding, now in a *parameter*
///      dimension): the suite missed this because the invariant handler's input domain
///      (`arbiterFee <= amount`) was NARROWER than the contract's accepted input space
///      (`arbiterFee` unbounded). A green invariant proves a property only over the domain it
///      actually fuzzes. The handler is now widened to fuzz `arbiterFee` across/above the slice.
contract CommitStakeV2ColdAuditTest is V2TestBase {
    /// @dev GUARD (was the demonstration): the hostile region is rejected at create. The smallest
    ///      hostile value is `arbiterFee == slice - amount - feeDeposit` (makes the strict
    ///      inequality fail by equality); `arbiterFee == slice` is deep in the hostile region.
    function test_ColdAudit_HostileArbiterFeeRejectedAtCreate() public {
        // Exactly on the boundary (equality, not strict) -> rejected.
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.arbiterFee = SLICE - STAKE; // amount + feeDeposit(0) + arbiterFee == slice -> not strict
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        vm.prank(staker);
        vm.expectRevert(bytes("SLICE_TOO_SMALL"));
        cs.create(p);

        // Deep in the hostile region (the original exploit input) -> rejected.
        p.arbiterFee = SLICE;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        vm.prank(staker);
        vm.expectRevert(bytes("SLICE_TOO_SMALL"));
        cs.create(p);
    }

    /// @dev GUARD: at the LARGEST legal arbiterFee (`slice - amount - feeDeposit - 1`), an
    ///      overturn slash STILL burns a strictly-positive surplus — the finding is now a
    ///      protected property at the exact edge of the allowed region, not an absence.
    function test_ColdAudit_MaxAllowedArbiterFee_StillBurnsPositive() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        uint256 maxFee = SLICE - STAKE - 1; // largest arbiterFee that keeps slice strictly larger
        p.arbiterFee = maxFee;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);

        vm.prank(staker);
        uint256 id = cs.create(p); // accepted: strict inequality holds by exactly 1

        vm.prank(verifier);
        cs.resolve(id, true); // honest pass
        vm.prank(beneficiary);
        cs.challenge(id);

        uint256 burnBefore = usdc.balanceOf(BURN);
        uint256 harmedBefore = usdc.balanceOf(beneficiary);

        vm.prank(arbiter);
        cs.arbitrate(id, true); // overturn -> OverturnedToFail, harmed = beneficiary

        uint256 burned = usdc.balanceOf(BURN) - burnBefore;
        // damage = feeAccrued(0) + min(arbiterFee, bond) = maxFee (bond = maxFee + 10%slice > maxFee)
        uint256 damage = maxFee;
        assertGt(burned, 0, "surplus strictly positive even at the max legal arbiterFee");
        assertEq(burned, SLICE - damage, "surplus == slice - damage (the 7a burn is real)");
        // harmed party's slice-leg gain is capped at damage, NOT the whole slice.
        uint256 harmedSliceGain =
            usdc.balanceOf(beneficiary) - harmedBefore - STAKE - (p.challengeBond - damage);
        assertEq(harmedSliceGain, damage, "harmed captures only damage (< slice), the rest burns");
    }

    /// @dev GUARD: the documented `staker==beneficiary` raid + colluding arbiter can no longer
    ///      recapture the whole slice. At the max legal arbiterFee the coalition's joint take is
    ///      bounded at `damage` (= arbiterFee here) and the rest is burned — the 7a cap is real.
    function test_ColdAudit_CollusionBoundedToDamageNotWholeSlice() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.beneficiary = staker; // raid: staker is also the beneficiary (only the arbiter is gated)
        uint256 maxFee = SLICE - STAKE - 1;
        p.arbiterFee = maxFee;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);

        uint256 stakerStart = usdc.balanceOf(staker);
        uint256 arbiterStart = usdc.balanceOf(arbiter);
        uint256 verifierBondStart = agentBond.freeBondOf(verifier);
        uint256 burnStart = usdc.balanceOf(BURN);

        vm.prank(staker);
        uint256 id = cs.create(p);
        vm.prank(verifier);
        cs.resolve(id, true);
        vm.prank(staker); // staker == beneficiary == harmed on a pass
        cs.challenge(id);
        vm.prank(arbiter);
        cs.arbitrate(id, true); // colluding overturn

        int256 stakerNet = int256(usdc.balanceOf(staker)) - int256(stakerStart);
        int256 arbiterNet = int256(usdc.balanceOf(arbiter)) - int256(arbiterStart);
        int256 coalitionNet = stakerNet + arbiterNet;

        uint256 verifierBondLoss = verifierBondStart - agentBond.freeBondOf(verifier);
        uint256 burned = usdc.balanceOf(BURN) - burnStart;

        assertEq(verifierBondLoss, SLICE, "verifier still loses its full slice");
        // Coalition take is now bounded at damage (= maxFee), NOT the whole slice.
        assertEq(coalitionNet, int256(maxFee), "coalition take bounded at damage, not the slice");
        assertEq(burned, SLICE - maxFee, "the slice - damage surplus is burned (7a cap is real)");
        assertGt(burned, 0, "a strictly-positive surplus is always burned on a slash");
    }
}
