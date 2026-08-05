// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev One operational question, answered by running it rather than by reading the source:
///      does `release` give the slash allowance back, so a small grant supports an unlimited
///      number of SUCCESSFUL jobs while still capping what a single hostile one can destroy?
///      The answer decides how tight an operator can set the grant during a review window.
contract AllowanceRevolveCheck is Test {
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
        bond.deposit(10 * UNIT);
    }

    /// A 1.5 grant, run three times in a row. If the allowance revolves, all three succeed.
    function test_ReleaseRevolvesTheGrant_SoASmallOneSupportsManyJobs() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 15 * UNIT / 10); // 1.5 USDC

        for (uint256 i; i < 3; i++) {
            assertEq(
                bond.slashAllowance(agent, enforcer), 15 * UNIT / 10, "grant is whole again"
            );
            vm.prank(enforcer);
            uint256 id = bond.lock(agent, creditor, 15 * UNIT / 10, uint64(block.timestamp + 1 days));
            assertEq(bond.slashAllowance(agent, enforcer), 0, "lock spent the whole grant");

            vm.prank(enforcer);
            bond.release(id);
        }
        assertEq(bond.slashAllowance(agent, enforcer), 15 * UNIT / 10, "still 1.5 after three jobs");
    }

    /// The other half of the same fact: a slash does NOT give it back. That is why one hostile
    /// job ends the run regardless of how the grant is sized, and why the grant caps the damage
    /// rather than the outage.
    function test_SlashDoesNotRevolveTheGrant() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 15 * UNIT / 10);

        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 15 * UNIT / 10, uint64(block.timestamp + 1 days));
        vm.prank(enforcer);
        bond.slash(id);

        assertEq(bond.slashAllowance(agent, enforcer), 0, "burned capacity does not come back");
    }

    /// And the guard that makes tightening the grant safe: capacity locked under an older
    /// generation is not restored, so an enforcer cannot release-then-relock around a revoke.
    function test_TighteningTheGrantMidFlightDoesNotRestoreOldCapacity() public {
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 3 * UNIT);

        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 15 * UNIT / 10, uint64(block.timestamp + 1 days));
        assertEq(bond.slashAllowance(agent, enforcer), 15 * UNIT / 10, "1.5 left of 3");

        vm.prank(agent);
        bond.decreaseSlashAllowance(enforcer, 15 * UNIT / 10); // to 0, and bumps the epoch

        vm.prank(enforcer);
        bond.release(id);
        assertEq(bond.slashAllowance(agent, enforcer), 0, "old-generation capacity stays gone");
    }
}
