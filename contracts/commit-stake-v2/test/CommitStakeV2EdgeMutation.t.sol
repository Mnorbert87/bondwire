// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {V2TestBase} from "./V2TestBase.sol";
import {CommitStakeV2, IERC20, IAgentBond, IStreamPay} from "../src/CommitStakeV2.sol";
import {AgentBond, IERC20 as AB_IERC20} from "agent-bond/AgentBond.sol";
import {StreamPay, IERC20 as SP_IERC20} from "stream-pay/StreamPay.sol";
import {FalseTransferToken} from "./mocks/AttackTokens.sol";

/// @dev Edge tests closing the low-severity defensive-`require` mutants that survived the
///      Phase-3 mutation campaign (MUTATION_TESTING.md). DISCIPLINE: every assert is derived from
///      the contract's DECLARED behaviour (the exact revert string in `src/CommitStakeV2.sol`),
///      not reverse-engineered from a mutant's output — the same rule as the §7a seed asserts.
contract CommitStakeV2EdgeMutationTest is V2TestBase {
    // (a) Constructor zero-address guards (CommitStakeV2.sol:290-292). The contract DECLARES three
    //     distinct revert reasons; assert each one for its respective zero argument.
    function test_Ctor_RevertOnZeroUsdc() public {
        vm.expectRevert(bytes("USDC_ZERO"));
        new CommitStakeV2(IERC20(address(0)), IAgentBond(address(agentBond)), IStreamPay(address(streamPay)));
    }

    function test_Ctor_RevertOnZeroAgentBond() public {
        vm.expectRevert(bytes("AGENT_BOND_ZERO"));
        new CommitStakeV2(IERC20(address(usdc)), IAgentBond(address(0)), IStreamPay(address(streamPay)));
    }

    function test_Ctor_RevertOnZeroStreamPay() public {
        vm.expectRevert(bytes("STREAM_PAY_ZERO"));
        new CommitStakeV2(IERC20(address(usdc)), IAgentBond(address(agentBond)), IStreamPay(address(0)));
    }

    // (b) Dust slice: the bond band `[arbiterFee + ceil(10%·slice), arbiterFee + floor(25%·slice)]`
    //     is unsatisfiable below 4 micro-USDC (ceil(10%) > floor(25%)), so `create` DECLARES the
    //     clean guard `require(verifierSlice >= 4, "SLICE_TOO_SMALL_FOR_BOND_BAND")` (src:346),
    //     which fires before the band/sizing checks. slice == 3 is the largest value it rejects.
    function test_Create_RevertDustSlice() public {
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.verifierSlice = 3; // < 4 -> band is unsatisfiable -> the dedicated dust guard
        vm.prank(staker);
        vm.expectRevert(bytes("SLICE_TOO_SMALL_FOR_BOND_BAND"));
        cs.create(p);
    }

    // (c) Silent-failure token: a payout transfer that returns `false` must HARD-revert the whole
    //     terminal call (`_safeTransfer` -> `require(... abi.decode(data,(bool)), "TRANSFER_FAILED")`,
    //     src:770) — the escrow never silently loses a routed payout. Spec: the declared
    //     TRANSFER_FAILED reason.
    function test_SafeTransfer_RevertOnFalseReturningToken() public {
        // Fresh stack wired to a token whose transferFrom succeeds (so create/deposit work) but
        // whose transfer returns false (so the payout at finalize must revert).
        FalseTransferToken tok = new FalseTransferToken();
        AgentBond ab = new AgentBond(AB_IERC20(address(tok)));
        StreamPay sp = new StreamPay(SP_IERC20(address(tok)));
        CommitStakeV2 csx = new CommitStakeV2(IERC20(address(tok)), IAgentBond(address(ab)), IStreamPay(address(sp)));

        // fund + approve staker and verifier (verifier must cover the full bond deposit)
        tok.mint(staker, 1_000_000e6);
        tok.mint(verifier, 1_000_000e6);
        vm.prank(staker);
        tok.approve(address(csx), type(uint256).max);
        vm.startPrank(verifier);
        tok.approve(address(ab), type(uint256).max);
        ab.deposit(VERIFIER_BOND);
        ab.setSlashAllowance(address(csx), type(uint256).max);
        vm.stopPrank();

        // create (no fee stream, so only the USDC + AgentBond legs are touched) -> resolve pass
        CommitStakeV2.CreateParams memory p = defaultParams();
        p.feeDeposit = 0;
        vm.prank(staker);
        uint256 id = csx.create(p);
        vm.prank(verifier);
        csx.resolve(id, true);

        // window closes; finalize routes the stake via _safeTransfer -> token returns false -> revert
        CommitStakeV2.Commitment memory c = csx.get(id);
        vm.warp(uint256(c.resolvedAt) + c.challengeWindow + 1);
        vm.expectRevert(bytes("TRANSFER_FAILED"));
        csx.finalize(id);
    }
}
