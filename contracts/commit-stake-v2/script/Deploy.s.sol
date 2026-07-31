// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CommitStakeV2, IERC20, IAgentBond, IStreamPay} from "../src/CommitStakeV2.sol";

/// @notice Deploys CommitStakeV2 to Arc testnet, wired to the ALREADY-DEPLOYED, audited
///         AgentBond + StreamPay (composability thesis — those two are reused, never redeployed).
/// Run: forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast
/// Env (.env, contracts/commit-stake/.env): DEPLOYER_PRIVATE_KEY, ARC_USDC.
/// AgentBond / StreamPay addresses are pinned constants below (the live Phase-1 instances).
contract Deploy is Script {
    // Live, audited primitives on Arc testnet — DO NOT redeploy.
    address constant AGENT_BOND = 0x4383Ea48837eF7e60fC22BD67945BCBf0551702c;
    address constant STREAM_PAY = 0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdc = vm.envAddress("ARC_USDC");

        vm.startBroadcast(pk);
        CommitStakeV2 cs = new CommitStakeV2(
            IERC20(usdc), IAgentBond(AGENT_BOND), IStreamPay(STREAM_PAY)
        );
        vm.stopBroadcast();

        console.log("CommitStakeV2 deployed at:", address(cs));
        console.log("USDC wired:     ", usdc);
        console.log("AgentBond wired:", AGENT_BOND);
        console.log("StreamPay wired:", STREAM_PAY);
    }
}
