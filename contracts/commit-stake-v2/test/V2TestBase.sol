// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStakeV2, IERC20, IAgentBond, IStreamPay} from "../src/CommitStakeV2.sol";
import {AgentBond, IERC20 as AB_IERC20} from "agent-bond/AgentBond.sol";
import {StreamPay, IERC20 as SP_IERC20} from "stream-pay/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Shared fixture: CommitStakeV2 wired to the REAL AgentBond and StreamPay (compiled from
///      the sibling projects' sources — no mocks of the primitives, the composition is what is
///      under test). Standard actors, a funded + opted-in verifier, and helpers for the
///      canonical commitment parameters used across the suites.
abstract contract V2TestBase is Test {
    MockERC20 internal usdc;
    AgentBond internal agentBond;
    StreamPay internal streamPay;
    CommitStakeV2 internal cs;

    address internal staker = address(0xA11CE);
    address internal verifier = address(0xF1);
    address internal beneficiary = address(0xBE1);
    address internal arbiter = address(0xAB1);
    address internal outsider = address(0xBAD);
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    // Canonical parameters (micro-USDC / seconds).
    uint256 internal constant STAKE = 100e6;
    uint256 internal constant SLICE = 150e6; // 150% default, > STAKE (+ fee where used)
    uint256 internal constant ARB_FEE = 5e6;
    // Exactly the §7a post-burn floor: arbiterFee + 10% × slice = 5e6 + 15e6.
    uint256 internal constant BOND = 20e6;
    uint64 internal constant WINDOW = 1 hours;
    uint64 internal constant ARB_DEADLINE = 2 hours;
    uint256 internal constant VERIFIER_BOND = 10_000e6;

    function setUp() public virtual {
        usdc = new MockERC20();
        agentBond = new AgentBond(AB_IERC20(address(usdc)));
        streamPay = new StreamPay(SP_IERC20(address(usdc)));
        cs = new CommitStakeV2(
            IERC20(address(usdc)),
            IAgentBond(address(agentBond)),
            IStreamPay(address(streamPay))
        );

        // Fund actors and approve the escrow.
        address[4] memory actors = [staker, verifier, beneficiary, arbiter];
        for (uint256 i; i < actors.length; i++) {
            usdc.mint(actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(cs), type(uint256).max);
        }
        vm.prank(staker);
        usdc.approve(address(streamPay), type(uint256).max);

        // Verifier posts its bond and opts in to CommitStakeV2 as an enforcer.
        vm.startPrank(verifier);
        usdc.approve(address(agentBond), type(uint256).max);
        agentBond.deposit(VERIFIER_BOND);
        agentBond.setSlashAllowance(address(cs), type(uint256).max);
        vm.stopPrank();
    }

    function defaultParams() internal view returns (CommitStakeV2.CreateParams memory p) {
        p = CommitStakeV2.CreateParams({
            verifier: verifier,
            beneficiary: beneficiary,
            arbiter: arbiter,
            amount: STAKE,
            verifierSlice: SLICE,
            deadline: uint64(block.timestamp) + 1 days,
            challengeWindow: WINDOW,
            challengeBond: BOND,
            arbiterDeadline: ARB_DEADLINE,
            arbiterFee: ARB_FEE,
            feeDeposit: 0,
            feeStart: 0,
            feeStop: 0,
            goal: "test goal"
        });
    }

    /// @dev Default params carrying a verifier fee stream at the earliest §7-legal start
    ///      (deadline + challengeWindow), streaming over `duration`. The slice is raised to
    ///      keep the sizing inequality strict, and the bond re-floored for the bigger slice.
    function paramsWithFee(uint256 fee, uint64 duration)
        internal
        view
        returns (CommitStakeV2.CreateParams memory p)
    {
        p = defaultParams();
        p.feeDeposit = fee;
        p.feeStart = p.deadline + p.challengeWindow;
        p.feeStop = p.feeStart + duration;
        if (p.verifierSlice <= p.amount + fee) p.verifierSlice = p.amount + fee + 1;
        p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
    }

    function createDefault() internal returns (uint256 id) {
        vm.prank(staker);
        id = cs.create(defaultParams());
    }

    /// @dev create -> resolve(passed) at the current timestamp.
    function createResolved(bool passed) internal returns (uint256 id) {
        id = createDefault();
        vm.prank(verifier);
        cs.resolve(id, passed);
    }

    /// @dev create -> resolve(passed) -> challenge by the harmed party.
    function createChallenged(bool passed) internal returns (uint256 id) {
        id = createResolved(passed);
        address harmed = passed ? beneficiary : staker;
        vm.prank(harmed);
        cs.challenge(id);
    }

    function warpPastWindow(uint256 id) internal {
        CommitStakeV2.Commitment memory c = cs.get(id);
        vm.warp(uint256(c.resolvedAt) + c.challengeWindow + 1);
    }

    function warpPastArbiterDeadline(uint256 id) internal {
        CommitStakeV2.Commitment memory c = cs.get(id);
        vm.warp(uint256(c.challengedAt) + c.arbiterDeadline + 1);
    }

    function assertStatus(uint256 id, CommitStakeV2.Status s) internal view {
        assertEq(uint8(cs.get(id).status), uint8(s), "status");
    }

    function assertOutcome(uint256 id, CommitStakeV2.Outcome o) internal view {
        assertEq(uint8(cs.get(id).outcome), uint8(o), "outcome");
    }
}
