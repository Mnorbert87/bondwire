// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2} from "../src/CommitStakeV2.sol";

/// @dev Regression guard for the free-amplification finding (external review, 2026-08-05).
///
///      `arbiterFee` is never escrowed at `create` — no transfer moves it, at any point — yet it
///      sits in the denominator of BOTH sizing rules: the strict inequality
///      `slice > amount + feeDeposit + arbiterFee` and the leverage cap
///      `slice <= MAX_SLICE_LEVERAGE x (amount + feeDeposit + arbiterFee)`. A free parameter in
///      the denominator of a cap is not a cap. Combined with a `deadline` that had only a
///      lower bound of "not in the past", a 1 USDC stake could lock a verifier's entire bond
///      and then burn it through the permissionless liveness branch, with the stake refunded
///      in full. Net cost to the attacker: gas.
///
///      Each test below ran GREEN against the pre-fix source, which is how the finding was
///      confirmed rather than accepted. They now assert the revert instead.
contract CommitStakeV2GriefBounds is V2TestBase {
    /// The headline case. Before the fix this burned the verifier's whole 10,000 USDC bond.
    function test_DustStakeCannotBuyAWholeBondSlice() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = 1e6;
        p.feeDeposit = 0;
        p.arbiterFee = 9_000e6; // free: never transferred, only ever a denominator
        p.verifierSlice = 10_000e6; // the verifier's entire bond
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        p.deadline = uint64(block.timestamp) + 1 days;

        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_FEE_TOO_LARGE"));
        cs.create(p);
    }

    /// A deadline the verifier cannot physically meet made the liveness burn a one-second
    /// trigger rather than a real liveness failure.
    function test_DeadlineMustLeaveTimeToResolve() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.deadline = uint64(block.timestamp) + 1;

        vm.prank(staker);
        vm.expectRevert(bytes("DEADLINE_TOO_SOON"));
        cs.create(p);
    }

    /// The bond band's cap bounds only the spam margin. `arbiterFee` is added on top of it, so
    /// before the fix a 10 USDC stake could put a 6,500 USDC price on contesting a false pass,
    /// which is exactly what the constant's own comment says cannot happen.
    function test_BeneficiaryCannotBePricedOutOfChallenging() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = 10e6;
        p.feeDeposit = 0;
        p.arbiterFee = 5_000e6;
        p.verifierSlice = 6_000e6;
        p.challengeBond = cs.challengeBondCap(p.verifierSlice, p.arbiterFee);
        p.deadline = uint64(block.timestamp) + 1 days;

        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_FEE_TOO_LARGE"));
        cs.create(p);
    }

    /// The control. With `arbiterFee` at zero the leverage cap always worked, which is what
    /// pins the defect on the free parameter rather than on the cap.
    function test_Control_LeverageCapHoldsWithoutTheFreeParameter() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = 1e6;
        p.feeDeposit = 0;
        p.arbiterFee = 0;
        p.verifierSlice = 10_000e6;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        p.deadline = uint64(block.timestamp) + 1 days;

        vm.prank(staker);
        vm.expectRevert(bytes("SLICE_ABOVE_LEVERAGE_CAP"));
        cs.create(p);
    }

    /// What the fix buys, stated as a number rather than a claim. The burn is not eliminated:
    /// a verifier that misses its window still loses the slice, and the staker's stake still
    /// comes back in full. What changes is the amplification, from unbounded to
    /// MAX_SLICE_LEVERAGE x (MAX_ARBITER_FEE_LEVERAGE + 1) = 33x the escrowed value.
    function test_ResidualAmplificationIsBoundedAt33x() public {
        uint256 burnBefore = usdc.balanceOf(BURN);
        uint256 stakerBefore = usdc.balanceOf(staker);

        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = 1e6;
        p.feeDeposit = 0;
        p.arbiterFee = 10e6; // exactly the cap
        p.verifierSlice = 33e6; // exactly the leverage cap on top of it
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        p.deadline = uint64(block.timestamp) + cs.MIN_RESOLVE_WINDOW();

        vm.prank(staker);
        uint256 id = cs.create(p);

        vm.warp(block.timestamp + cs.MIN_RESOLVE_WINDOW() + 1);
        vm.prank(outsider);
        cs.slashVerifierExpired(id);

        assertEq(usdc.balanceOf(BURN) - burnBefore, 33e6, "33 USDC of bond per 1 USDC staked");
        assertEq(usdc.balanceOf(staker), stakerBefore, "the stake is still refunded in full");

        // One more than the cap is rejected, so 33x is the ceiling and not a sample.
        CommitStakeV2.CreateParams memory q = defaultParams();
        q.amount = 1e6;
        q.feeDeposit = 0;
        q.arbiterFee = 10e6 + 1;
        q.verifierSlice = 33e6;
        q.challengeBond = cs.challengeBondFloor(q.verifierSlice, q.arbiterFee);
        q.deadline = uint64(block.timestamp) + cs.MIN_RESOLVE_WINDOW();
        vm.prank(staker);
        vm.expectRevert(bytes("ARBITER_FEE_TOO_LARGE"));
        cs.create(q);
    }
}
