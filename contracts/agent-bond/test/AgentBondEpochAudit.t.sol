// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Adversarial counter-tests for the grant-generation (allowanceEpoch) hardening,
///      written during the 2026-07-29 hardened-branch audit. The epoch closes the
///      release-then-relock trap; these tests probe the OTHER side of that trade — where an
///      honest enforcer loses capacity it would previously have got back.
///      See HARDENED_AUDIT_2026-07-29.md.
contract AgentBondEpochAuditTest is Test {
    MockERC20 internal usdc;
    AgentBond internal bond;

    address internal agent = address(0xA1);
    address internal enforcer = address(0xE1);
    address internal creditor = address(0xC1);

    function setUp() public {
        usdc = new MockERC20();
        bond = new AgentBond(IERC20(address(usdc)));
        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(bond), type(uint256).max);
        bond.deposit(1_000e6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // F8. A ONE-UNIT tightening wipes the capacity return of EVERY in-flight obligation,
    //     however large. `decreaseSlashAllowance(e, 1)` bumps the epoch, so an honest
    //     enforcer holding a 500 USDC obligation loses the whole 500 of revolving capacity
    //     on release, not just the 1 unit the agent intended to withdraw. The exposure cap
    //     is never exceeded (so this is not theft) but the penalty is wildly disproportionate
    //     to the stated intent, and the trade is not documented in those terms.
    // ---------------------------------------------------------------------
    function test_F8_oneUnitTightening_wipesFullCapacityOfInFlightObligation() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 600e6);

        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 500e6, 0);
        assertEq(bond.slashAllowance(agent, enforcer), 100e6, "lock spends allowance");

        // Agent trims the grant by ONE micro-USDC.
        vm.prank(agent);
        bond.decreaseSlashAllowance(enforcer, 1);
        assertEq(bond.slashAllowance(agent, enforcer), 100e6 - 1, "only 1 unit was withdrawn");

        // Honest enforcer settles the obligation cleanly.
        vm.prank(enforcer);
        bond.release(id);

        // The 500e6 does NOT come back: a 1-unit tightening cost the enforcer 500e6 of capacity.
        assertEq(
            bond.slashAllowance(agent, enforcer),
            100e6 - 1,
            "capacity is not restored after any epoch bump, however small"
        );
        // The bond itself is intact and free again - this is capacity, not custody.
        assertEq(bond.freeBondOf(agent), 1_000e6, "bond returns to free on release");
    }

    /// The race-free INCREASE path deliberately does not bump the epoch, so an honest
    /// top-up mid-obligation preserves the restore. Pinned so the asymmetry stays intentional.
    function test_F8_increaseDoesNotBumpEpoch_soRestoreSurvives() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 600e6);

        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 500e6, 0);

        vm.prank(agent);
        bond.increaseSlashAllowance(enforcer, 50e6); // 100e6 -> 150e6, epoch unchanged

        vm.prank(enforcer);
        bond.release(id);

        assertEq(
            bond.slashAllowance(agent, enforcer),
            650e6,
            "increase keeps the generation, so release restores the slice"
        );
    }

    // ---------------------------------------------------------------------
    // F9. The revoke is genuinely final: the release-then-relock trap is closed. This is the
    //     property the epoch exists for; asserted end to end rather than via the allowance
    //     number alone.
    // ---------------------------------------------------------------------
    function test_F9_revokeIsFinal_releaseCannotFundARelock() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 600e6);

        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 500e6, 0);

        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 0); // hard revoke while the obligation is live

        vm.prank(enforcer);
        bond.release(id);

        assertEq(bond.slashAllowance(agent, enforcer), 0, "release must not refill a revoked grant");

        vm.prank(enforcer);
        vm.expectRevert(bytes("ALLOWANCE"));
        bond.lock(agent, creditor, 1, 0);
    }

    // ---------------------------------------------------------------------
    // F10. Epoch is per (agent, enforcer). A revoke against enforcer A must not strip the
    //      capacity return of an unrelated enforcer B. Guards against a shared-counter bug.
    // ---------------------------------------------------------------------
    function test_F10_epochIsPerEnforcer_revokeDoesNotLeakAcross() public {
        address enforcerB = address(0xE2);

        vm.startPrank(agent);
        bond.setSlashAllowance(enforcer, 600e6);
        bond.setSlashAllowance(enforcerB, 600e6);
        vm.stopPrank();

        vm.prank(enforcerB);
        uint256 idB = bond.lock(agent, creditor, 200e6, 0);

        // Revoke A only.
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 0);

        vm.prank(enforcerB);
        bond.release(idB);

        assertEq(
            bond.slashAllowance(agent, enforcerB),
            600e6,
            "B's capacity must be restored: the revoke was against A"
        );
    }

    // ---------------------------------------------------------------------
    // F11. Epoch counter overflow. `allowanceEpoch` is uint64 and bumped inside `unchecked`.
    //      At 2^64-1 the next bump wraps to 0. An obligation locked at epoch 0 would then have
    //      its capacity restored after a revoke, re-opening the trap the epoch closes.
    //      Unreachable in practice (2^64 transactions), asserted here as the documented bound.
    // ---------------------------------------------------------------------
    function test_F11_epochWrapsAtUint64Max_documentedBound() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 600e6);
        assertEq(bond.allowanceEpoch(agent, enforcer), 1, "epoch starts bumping from 0");

        // Force the counter to its maximum, then bump once more.
        bytes32 slot = keccak256(
            abi.encode(uint256(uint160(enforcer)), keccak256(abi.encode(uint256(uint160(agent)), uint256(4))))
        );
        vm.store(address(bond), slot, bytes32(uint256(type(uint64).max)));
        assertEq(bond.allowanceEpoch(agent, enforcer), type(uint64).max, "primed to max");

        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 600e6);
        assertEq(bond.allowanceEpoch(agent, enforcer), 0, "unchecked bump wraps to zero");
    }
}
