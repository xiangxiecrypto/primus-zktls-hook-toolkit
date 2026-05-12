// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {LLMAnswerLengthVerifier} from "../contracts/extensions/LLMAnswerLengthVerifier.sol";

/// @notice Deploys `LLMAnswerLengthVerifier` on Base Sepolia, wired against
///         step index 1 (which is the LLM step in the existing onchain-llm
///         scenario), keyed on `"answer"`, accepting answers between 20 and
///         800 bytes — a comfortable band for one-sentence LLM responses.
///
/// Run with:
///   PRIVATE_KEY=0x... \
///   forge script script/DeployLLMVerifier.s.sol:DeployLLMVerifier \
///       --rpc-url base_sepolia --broadcast
contract DeployLLMVerifier is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint8  sourceStep = uint8(vm.envOr("LLM_STEP", uint256(1)));
        uint256 minBytes  = vm.envOr("LLM_MIN_BYTES", uint256(20));
        uint256 maxBytes  = vm.envOr("LLM_MAX_BYTES", uint256(800));

        vm.startBroadcast(deployerKey);
        LLMAnswerLengthVerifier verifier = new LLMAnswerLengthVerifier(
            sourceStep,
            "answer",
            minBytes,
            maxBytes
        );
        vm.stopBroadcast();

        console2.log("LLMAnswerLengthVerifier deployed at:", address(verifier));
        console2.log("  sourceStep :", sourceStep);
        console2.log("  keyName    : answer");
        console2.log("  minBytes   :", minBytes);
        console2.log("  maxBytes   :", maxBytes);
    }
}
