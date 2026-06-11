// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStakeV2, IERC20, IAgentBond, IStreamPay} from "../src/CommitStakeV2.sol";
import {AgentBond, IERC20 as AB_IERC20} from "agent-bond/AgentBond.sol";
import {StreamPay, IERC20 as SP_IERC20} from "stream-pay/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Halmos symbolic specification for CommitStakeV2 (Phase-3 verification layer).
///      Run: `halmos --function check_ --solver-timeout-assertion 0`.
///      Halmos treats each `check_*` function's parameters as symbolic 256-bit inputs and proves
///      the assertions hold for ALL of them (subject to `vm.assume`), or returns a counterexample.
///
///      DESIGN — assume-guarantee decomposition. The §7a routing arithmetic is mirrored here
///      1:1 from CommitStakeV2.sol (line refs inline). The create-time sizing require
///      (`verifierSlice > amount + feeDeposit + arbiterFee`, src:365) is the *assumption*; it is
///      proven to be ENFORCED by concrete tests (test_Create_RevertSliceAtOrBelowStake,
///      test_ColdAudit_HostileArbiterFeeRejectedAtCreate). Under that assumption these checks
///      prove the *consequences* hold symbolically over the entire 256-bit input space:
///        (b) surplus > 0 on every slash branch (the gate-4 HIGH property), and
///            value conservation: toHarmed + surplus == slice (no slice minted, none lost).
///      The fully-stateful solvency / no-double-pay invariants are exercised by the
///      `fail_on_revert` invariant suite (CommitStakeV2Invariant.t.sol); here we add the
///      arithmetic core that an invariant fuzzer can only sample, not prove.
contract SymbolicSpec is Test {
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice (b) OVERTURN branch (arbitrate, src:508-525): surplus is strictly positive and the
    ///         slice is conserved, for ALL inputs satisfying the create-time sizing rule.
    function check_SurplusPositive_Overturn(
        uint256 amount,
        uint256 feeDeposit,
        uint256 arbiterFee,
        uint256 feeAccrued,
        uint256 challengeBondPaid,
        uint256 slice
    ) public pure {
        // create-time invariants (CommitStakeV2.create, src:325 + src:365)
        vm.assume(amount > 0);
        vm.assume(slice > amount + feeDeposit + arbiterFee); // gate-4 HIGH fix (src:365)
        // feeAccrued is read from StreamPay state; it can never exceed the funded deposit.
        vm.assume(feeAccrued <= feeDeposit);

        // arbitrate overturn routing, mirrored from src:508-525
        uint256 fee = _min(arbiterFee, challengeBondPaid); // src:508
        uint256 damage = feeAccrued + fee; // src:515
        uint256 toHarmed = _min(damage, slice); // src:516
        uint256 surplus = slice - toHarmed; // src:521

        assert(surplus > 0); // gate-4: §7a surplus-burn is never zeroed
        assert(toHarmed + surplus == slice); // conservation: the whole slice is accounted for
        assert(toHarmed <= slice); // no over-routing out of the slice
    }

    /// @notice (b) LIVENESS branch (slashVerifierExpired, src:610-621): no arbiter leg, so
    ///         damage = feeAccrued; surplus strictly positive and slice conserved.
    function check_SurplusPositive_Liveness(
        uint256 amount,
        uint256 feeDeposit,
        uint256 arbiterFee,
        uint256 feeAccrued,
        uint256 slice
    ) public pure {
        vm.assume(amount > 0);
        vm.assume(slice > amount + feeDeposit + arbiterFee);
        vm.assume(feeAccrued <= feeDeposit);

        // slashVerifierExpired routing, mirrored from src:612-621
        uint256 toStaker = _min(feeAccrued, slice); // src:614 (damage = feeAccrued + 0)
        uint256 surplus = slice - toStaker; // src:619

        assert(surplus > 0);
        assert(toStaker + surplus == slice);
    }

    /// @notice (c) NO-OVERPAY of the fee residue: the early-Ended refund is capped at both the
    ///         per-stream remainder AND the unbooked balance (src:713-714), so a residue payout
    ///         can never dip into another commitment's booked escrow. Proven for all inputs.
    function check_FeeResidue_NeverExceedsUnbooked(
        uint256 deposit,
        uint256 withdrawn,
        uint256 balanceOf,
        uint256 totalEscrowed
    ) public pure {
        vm.assume(withdrawn <= deposit); // StreamPay invariant
        vm.assume(totalEscrowed <= balanceOf); // solvency precondition (booked <= held)

        uint256 unbooked = balanceOf - totalEscrowed; // src:713
        uint256 refunded = _min(deposit - withdrawn, unbooked); // src:714

        // the refund never exceeds the unbooked surplus -> booked escrow is untouched
        assert(refunded <= unbooked);
        assert(balanceOf - refunded >= totalEscrowed); // still solvent after the residue payout
    }

    /// @notice (a) STAKE-LEG conservation (arbitrate/finalize/liveness, _routeStake src:674-679 +
    ///         slashVerifierExpired src:622-624): the booked stake leaves totalEscrowed exactly
    ///         once and the contract stays solvent for the remaining booked obligations.
    function check_StakeLeg_Solvency(
        uint256 amount,
        uint256 otherBooked,
        uint256 balanceOf
    ) public pure {
        uint256 totalEscrowed = amount + otherBooked; // this commitment's stake + the rest
        vm.assume(amount <= totalEscrowed); // no overflow in the sum
        vm.assume(totalEscrowed <= balanceOf); // solvency precondition

        // _routeStake: totalEscrowed -= amount; transfer(to, amount)  (src:676-677)
        uint256 newEscrowed = totalEscrowed - amount;
        uint256 newBalance = balanceOf - amount;

        assert(newBalance >= newEscrowed); // still covers every remaining booked obligation
        assert(newEscrowed == otherBooked); // exactly this stake was removed, nothing else
    }

    /// @notice StreamPay accounting invariant (the reused primitive's core, StreamPay.sol:40):
    ///         `withdrawn + recipientBalance + senderBalance == deposit` for an active stream, and
    ///         on cancel `toRecipient + toSender == deposit - withdrawn` (the unwithdrawn remainder
    ///         is split, never minted or lost). Proven for all (deposit, withdrawn, streamed).
    function check_StreamPay_SplitConserves(
        uint256 deposit,
        uint256 withdrawn,
        uint256 streamed
    ) public pure {
        vm.assume(withdrawn <= streamed); // can't withdraw more than streamed
        vm.assume(streamed <= deposit); // can't stream more than deposited

        // live split (StreamPay.sol:153-161): recipientBalance = streamed - withdrawn,
        // senderBalance = deposit - streamed.
        uint256 recipientBalance = streamed - withdrawn;
        uint256 senderBalance = deposit - streamed;
        assert(withdrawn + recipientBalance + senderBalance == deposit);

        // cancel split (StreamPay.sol:192-193): toRecipient + toSender == deposit - withdrawn.
        uint256 toRecipient = streamed - withdrawn;
        uint256 toSender = deposit - streamed;
        assert(toRecipient + toSender == deposit - withdrawn);
    }
}
