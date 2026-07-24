// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Regression suite for the M1 (release-then-relock trap) and M2 (approve-race)
///         hardening: epoch-gated allowance restore + relative increase/decrease.
contract AgentBondHardeningTest is Test {
    AgentBond bond;
    MockERC20 usdc;

    address agent = address(0xA1);
    address enforcer = address(0xE1);
    address creditor = address(0xC1);

    uint256 constant UNIT = 1e6;

    function setUp() public {
        usdc = new MockERC20();
        bond = new AgentBond(IERC20(address(usdc)));
        usdc.mint(agent, 1000 * UNIT);
        vm.prank(agent);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(agent);
        bond.deposit(100 * UNIT);
    }

    // ---------------------------------------------------------------------------
    // M2 — relative allowance changes (no approve-race overwrite)
    // ---------------------------------------------------------------------------

    function test_increaseAllowance_addsCapacity() public {
        vm.startPrank(agent);
        bond.increaseSlashAllowance(enforcer, 30 * UNIT);
        bond.increaseSlashAllowance(enforcer, 20 * UNIT);
        vm.stopPrank();
        assertEq(bond.slashAllowance(agent, enforcer), 50 * UNIT);
    }

    function test_decreaseAllowance_saturatesAtZero() public {
        vm.startPrank(agent);
        bond.setSlashAllowance(enforcer, 40 * UNIT);
        bond.decreaseSlashAllowance(enforcer, 100 * UNIT); // more than current
        vm.stopPrank();
        assertEq(bond.slashAllowance(agent, enforcer), 0);
    }

    function test_increaseDecrease_revertOnZeroDelta() public {
        vm.startPrank(agent);
        vm.expectRevert("AMOUNT_ZERO");
        bond.increaseSlashAllowance(enforcer, 0);
        vm.expectRevert("AMOUNT_ZERO");
        bond.decreaseSlashAllowance(enforcer, 0);
        vm.stopPrank();
    }

    function test_increaseDecrease_revertOnZeroEnforcer() public {
        vm.startPrank(agent);
        vm.expectRevert("ENFORCER_ZERO");
        bond.increaseSlashAllowance(address(0), 1);
        vm.expectRevert("ENFORCER_ZERO");
        bond.decreaseSlashAllowance(address(0), 1);
        vm.stopPrank();
    }

    /// @dev decrease is a race-free tightening: reducing capacity the enforcer hasn't locked yet
    ///      leaves exactly the intended remainder, regardless of interleaving.
    function test_decrease_leavesExactRemainder() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 60 * UNIT);
        vm.prank(enforcer);
        bond.lock(agent, creditor, 20 * UNIT, 0); // allowance 60 -> 40
        vm.prank(agent);
        bond.decreaseSlashAllowance(enforcer, 25 * UNIT); // 40 -> 15
        assertEq(bond.slashAllowance(agent, enforcer), 15 * UNIT);
    }

    // ---------------------------------------------------------------------------
    // M1 — a revoke can no longer be undone by an in-flight obligation
    // ---------------------------------------------------------------------------

    /// @dev The core M1 attack: enforcer locks, agent revokes, enforcer releases hoping the
    ///      restore re-arms the grant, then tries to re-lock. With the epoch guard the restore
    ///      is suppressed and the re-lock reverts on ALLOWANCE.
    function test_M1_revokeThenRelease_doesNotRestoreCapacity() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 50 * UNIT, 0); // allowance 50 -> 0
        assertEq(bond.slashAllowance(agent, enforcer), 0);

        // agent hard-revokes while the obligation is open (bumps the grant generation)
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 0);

        // enforcer releases — capacity must NOT come back
        vm.prank(enforcer);
        bond.release(id);
        assertEq(bond.slashAllowance(agent, enforcer), 0, "revoked grant must not be restored");

        // and the enforcer therefore cannot re-lock
        vm.prank(enforcer);
        vm.expectRevert("ALLOWANCE");
        bond.lock(agent, creditor, 50 * UNIT, 0);

        // the agent's bond is fully free again — clean exit
        assertEq(bond.freeBondOf(agent), 100 * UNIT);
    }

    /// @dev decrease-to-zero is also a hard revoke (bumps epoch): same protection.
    function test_M1_decreaseRevoke_doesNotRestore() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 40 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 40 * UNIT, 0);

        vm.prank(agent);
        bond.decreaseSlashAllowance(enforcer, type(uint256).max); // hard revoke via decrease

        vm.prank(enforcer);
        bond.release(id);
        assertEq(bond.slashAllowance(agent, enforcer), 0, "decrease-revoke must not be restored");
    }

    /// @dev Normal revolving is preserved: with no revoke in between, release DOES restore
    ///      the capacity (same epoch), so the grant keeps revolving as designed.
    function test_revolving_restoresWhenGrantUnchanged() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0); // 50 -> 20
        assertEq(bond.slashAllowance(agent, enforcer), 20 * UNIT);
        vm.prank(enforcer);
        bond.release(id); // same epoch -> restore
        assertEq(bond.slashAllowance(agent, enforcer), 50 * UNIT, "revolving must restore");
    }

    /// @dev increase does NOT bump the epoch, so topping up mid-obligation still lets the
    ///      in-flight obligation restore on release (capacity keeps revolving).
    function test_increaseKeepsEpoch_restoreStillHappens() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 50 * UNIT, 0); // 50 -> 0
        vm.prank(agent);
        bond.increaseSlashAllowance(enforcer, 10 * UNIT); // 0 -> 10, epoch unchanged
        vm.prank(enforcer);
        bond.release(id); // restore 50 on top of 10
        assertEq(bond.slashAllowance(agent, enforcer), 60 * UNIT);
    }

    /// @dev A slash still burns capacity permanently and is unaffected by the epoch logic.
    function test_slash_afterRevoke_stillPaysCreditor() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 50 * UNIT, 0);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 0); // revoke future capacity, not the open obligation
        vm.prank(enforcer);
        bond.slash(id);
        assertEq(usdc.balanceOf(creditor), 50 * UNIT);
        assertEq(bond.bond(agent), 50 * UNIT);
        assertEq(bond.slashAllowance(agent, enforcer), 0);
    }

    /// @dev Epoch is tracked per (agent, enforcer): revoking one enforcer must not disturb another.
    function test_epoch_isolatedPerEnforcer() public {
        address enforcer2 = address(0xE2);
        vm.startPrank(agent);
        bond.setSlashAllowance(enforcer, 30 * UNIT);
        bond.setSlashAllowance(enforcer2, 30 * UNIT);
        vm.stopPrank();
        vm.prank(enforcer2);
        uint256 id2 = bond.lock(agent, creditor, 30 * UNIT, 0);

        // revoke enforcer1 only
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 0);

        // enforcer2's obligation still restores normally
        vm.prank(enforcer2);
        bond.release(id2);
        assertEq(bond.slashAllowance(agent, enforcer2), 30 * UNIT);
    }
}
