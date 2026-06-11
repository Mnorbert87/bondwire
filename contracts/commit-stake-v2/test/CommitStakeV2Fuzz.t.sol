// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2} from "../src/CommitStakeV2.sol";

/// @dev Fuzz suite (10k runs each, see foundry.toml):
///      - the create-time sizing inequality and the §7a challenge-bond BAND at their exact
///        boundaries,
///      - every timing gate at its exact boundary second (the spec calls the transition EDGES
///        the typical failure spot of challenge-window systems, not the bookkeeping),
///      - a full random lifecycle (optionally carrying a real StreamPay fee stream) with
///        token-conservation — including the BURN address — and escrow-drain assertions.
contract CommitStakeV2FuzzTest is V2TestBase {
    /// @dev Fuzzed slices can exceed the fixture's posted bond; top it up so the only checks
    ///      exercised are CommitStakeV2's own (AgentBond capacity has its own suite).
    function _ensureVerifierBond(uint256 slice) internal {
        uint256 free = agentBond.freeBondOf(verifier);
        if (free < slice) {
            uint256 topUp = slice - free;
            usdc.mint(verifier, topUp);
            vm.prank(verifier);
            agentBond.deposit(topUp);
        }
    }

    /// @dev §7a band: below the floor reverts, inside the band creates, above the cap reverts.
    function testFuzz_Create_BondBandBoundary(uint256 amount, uint256 bondDelta, uint8 mode)
        public
    {
        amount = bound(amount, 4, 100_000e6);
        mode = uint8(bound(mode, 0, 2)); // 0 below, 1 inside, 2 above

        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = amount;
        p.verifierSlice = amount + 1; // minimal valid slice, isolate the bond check
        p.arbiterFee = 0;
        uint256 floor = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
        uint256 cap = cs.challengeBondCap(p.verifierSlice, p.arbiterFee);
        assertGe(cap, floor, "band is non-empty for any non-dust slice");

        if (mode == 0) {
            p.challengeBond = floor - bound(bondDelta, 1, floor);
            vm.expectRevert(bytes("BOND_BELOW_FLOOR"));
            vm.prank(staker);
            cs.create(p);
        } else if (mode == 2) {
            p.challengeBond = cap + bound(bondDelta, 1, amount);
            vm.expectRevert(bytes("BOND_ABOVE_CAP"));
            vm.prank(staker);
            cs.create(p);
        } else {
            p.challengeBond = floor + bound(bondDelta, 0, cap - floor);
            _ensureVerifierBond(p.verifierSlice);
            vm.prank(staker);
            uint256 id = cs.create(p);
            assertEq(cs.get(id).challengeBond, p.challengeBond);
        }
    }

    /// @dev The central formula at its boundary: slice == stake + maxFee always reverts,
    ///      slice == stake + maxFee + 1 always creates (collusion must be strictly negative).
    ///      The fee budget enters as the create-side feeDeposit — the stream the contract
    ///      itself opens.
    function testFuzz_Create_SliceBoundary(uint256 amount, uint256 fee, bool atBoundary) public {
        amount = bound(amount, 4, 100_000e6);
        fee = bound(fee, 1, 50_000e6);

        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = amount;
        p.arbiterFee = 0;
        p.feeDeposit = fee;
        p.feeStart = p.deadline + p.challengeWindow;
        p.feeStop = p.feeStart + 1 days;

        if (atBoundary) {
            p.verifierSlice = amount + fee; // net-zero collusion point
            p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
            vm.expectRevert(bytes("SLICE_TOO_SMALL"));
            vm.prank(staker);
            cs.create(p);
        } else {
            p.verifierSlice = amount + fee + 1; // minimal strict surplus
            p.challengeBond = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
            _ensureVerifierBond(p.verifierSlice);
            vm.prank(staker);
            uint256 id = cs.create(p);
            assertEq(cs.get(id).verifierSlice, p.verifierSlice);
            assertTrue(cs.get(id).feeStreamId != 0, "fee stream opened");
        }
    }

    /// @dev resolve: valid at every second up to and INCLUDING the deadline, never after.
    function testFuzz_Resolve_DeadlineBoundary(uint64 offset, bool late) public {
        uint256 id = createDefault();
        uint64 deadline = cs.get(id).deadline;

        if (late) {
            vm.warp(uint256(deadline) + bound(offset, 1, 365 days));
            vm.expectRevert(bytes("DEADLINE_PASSED"));
            vm.prank(verifier);
            cs.resolve(id, true);
            // ... and at that point the liveness arm is open instead.
            cs.slashVerifierExpired(id);
            assertOutcome(id, CommitStakeV2.Outcome.LivenessSlash);
        } else {
            vm.warp(uint256(deadline) - bound(offset, 0, 1 days));
            vm.prank(verifier);
            cs.resolve(id, true);
            assertStatus(id, CommitStakeV2.Status.Resolved);
            // ... and the liveness arm must be closed forever.
            vm.warp(uint256(deadline) + 1);
            vm.expectRevert(bytes("NOT_ACTIVE"));
            cs.slashVerifierExpired(id);
        }
    }

    /// @dev challenge: valid at every second up to and INCLUDING resolvedAt + window; finalize
    ///      only STRICTLY after. The two never both fire — at any fuzzed second exactly one of
    ///      {challenge allowed, finalize allowed} holds.
    function testFuzz_Challenge_WindowBoundary(uint64 offset, bool inside) public {
        uint256 id = createResolved(false);
        CommitStakeV2.Commitment memory c = cs.get(id);
        uint256 windowEnd = uint256(c.resolvedAt) + c.challengeWindow;

        if (inside) {
            vm.warp(windowEnd - bound(offset, 0, c.challengeWindow));
            vm.expectRevert(bytes("WINDOW_OPEN"));
            cs.finalize(id); // finalize must NOT fire inside the window
            vm.prank(staker);
            cs.challenge(id);
            assertStatus(id, CommitStakeV2.Status.Challenged);
        } else {
            vm.warp(windowEnd + bound(offset, 1, 365 days));
            vm.expectRevert(bytes("WINDOW_CLOSED"));
            vm.prank(staker);
            cs.challenge(id); // challenge must NOT fire after the window
            cs.finalize(id);
            assertOutcome(id, CommitStakeV2.Outcome.CleanFail);
        }
    }

    /// @dev arbitrate: valid up to and INCLUDING challengedAt + arbiterDeadline; the silence
    ///      finalize only STRICTLY after. Exactly one path at any fuzzed second.
    function testFuzz_Arbitrate_DeadlineBoundary(uint64 offset, bool inTime, bool overturn)
        public
    {
        uint256 id = createChallenged(true);
        CommitStakeV2.Commitment memory c = cs.get(id);
        uint256 ruleEnd = uint256(c.challengedAt) + c.arbiterDeadline;

        if (inTime) {
            vm.warp(ruleEnd - bound(offset, 0, c.arbiterDeadline));
            vm.expectRevert(bytes("ARBITER_TIME_LEFT"));
            cs.finalize(id);
            vm.prank(arbiter);
            cs.arbitrate(id, overturn);
            assertOutcome(
                id,
                overturn
                    ? CommitStakeV2.Outcome.OverturnedToFail
                    : CommitStakeV2.Outcome.UpheldPass
            );
        } else {
            vm.warp(ruleEnd + bound(offset, 1, 365 days));
            vm.expectRevert(bytes("ARBITER_LATE"));
            vm.prank(arbiter);
            cs.arbitrate(id, overturn);
            cs.finalize(id); // silence: fails closed
            assertOutcome(id, CommitStakeV2.Outcome.SilencePass);
        }
    }

    /// @dev Full random lifecycle, a third of the runs carrying a REAL fee stream. Whatever
    ///      path the fuzzer picks:
    ///      - tokens are conserved across all parties + the three contracts + the BURN address
    ///        (the §7a sink is a destination, not a leak),
    ///      - the escrow ends EMPTY for the commitment (every entered token leaves, including
    ///        an atomically-refunded fee remainder),
    ///      - the commitment ends in exactly one terminal state with a recorded outcome.
    function testFuzz_FullFlow_ConservationAndDrain(
        uint256 amount,
        uint8 path,
        bool verdict,
        uint64 jitter
    ) public {
        amount = bound(amount, 4, 100_000e6);
        path = uint8(bound(path, 0, 3)); // 0 clean, 1 liveness, 2 ruled, 3 silence

        CommitStakeV2.CreateParams memory p = defaultParams();
        p.amount = amount;
        if (jitter % 3 == 0) {
            p.feeDeposit = bound(uint256(jitter) * 7919 + 1, 1, amount);
            p.feeStart = p.deadline + p.challengeWindow;
            p.feeStop = p.feeStart + 1 days;
        }
        // arbiterFee first, then size the slice strictly above amount + feeDeposit + arbiterFee
        // (gate-4 HIGH fix: the slice must clear the full §7a damage ceiling).
        p.arbiterFee = bound(uint256(jitter) >> 3, 0, amount);
        p.verifierSlice = amount + p.feeDeposit + p.arbiterFee + 1 + bound(jitter, 0, amount);
        {
            uint256 floor = cs.challengeBondFloor(p.verifierSlice, p.arbiterFee);
            uint256 cap = cs.challengeBondCap(p.verifierSlice, p.arbiterFee);
            p.challengeBond = floor + (uint256(jitter) % (cap - floor + 1));
        }
        _ensureVerifierBond(p.verifierSlice); // mints — must precede the conservation snapshot

        uint256 totalBefore = _totalHeld();

        vm.prank(staker);
        uint256 id = cs.create(p);

        if (path == 1) {
            // liveness: verifier never shows up (sometimes long after the fee stream started,
            // so the §7a damage leg routes a real accrued amount)
            vm.warp(uint256(p.deadline) + 1 + (jitter % 30 days));
            cs.slashVerifierExpired(id);
        } else {
            // resolve somewhere inside the allowed window (deadline inclusive)
            vm.warp(uint256(p.deadline) - (jitter % 1 days));
            vm.prank(verifier);
            cs.resolve(id, verdict);

            if (path == 0) {
                warpPastWindow(id);
                cs.finalize(id);
            } else {
                CommitStakeV2.Commitment memory c = cs.get(id);
                // challenge somewhere inside the window (last second inclusive)
                vm.warp(uint256(c.resolvedAt) + (jitter % (c.challengeWindow + 1)));
                vm.prank(verdict ? beneficiary : staker);
                cs.challenge(id);

                if (path == 2) {
                    c = cs.get(id);
                    vm.warp(uint256(c.challengedAt) + (jitter % (c.arbiterDeadline + 1)));
                    vm.prank(arbiter);
                    cs.arbitrate(id, verdict ? jitter % 2 == 0 : jitter % 3 == 0);
                } else {
                    warpPastArbiterDeadline(id);
                    cs.finalize(id);
                }
            }
        }

        // Terminal, with a recorded outcome.
        CommitStakeV2.Status s = cs.get(id).status;
        assertTrue(
            s == CommitStakeV2.Status.Finalized || s == CommitStakeV2.Status.Expired, "terminal"
        );
        assertTrue(cs.get(id).outcome != CommitStakeV2.Outcome.None, "outcome recorded");

        // Conservation (burn included) + full drain.
        assertEq(_totalHeld(), totalBefore, "tokens conserved across the system");
        assertEq(usdc.balanceOf(address(cs)), 0, "escrow fully drained");
        assertEq(cs.totalEscrowed(), 0, "owed-ledger drained with it");
    }

    function _totalHeld() internal view returns (uint256 sum) {
        sum = usdc.balanceOf(staker) + usdc.balanceOf(verifier) + usdc.balanceOf(beneficiary)
            + usdc.balanceOf(arbiter) + usdc.balanceOf(outsider) + usdc.balanceOf(address(cs))
            + usdc.balanceOf(address(agentBond)) + usdc.balanceOf(address(streamPay))
            + usdc.balanceOf(BURN);
    }
}
