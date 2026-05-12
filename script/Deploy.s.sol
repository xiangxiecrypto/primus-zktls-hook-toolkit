// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ZkTlsAttestationHook} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";

/// @notice Deploys ZkTlsAttestationHook against the right Primus PrimusZKTLS
///         verifier for the current chain.
///
/// Usage
/// -----
/// Set the ERC-8183 core address for the target chain (no canonical address
/// yet — it's deployed per environment) and broadcast:
///
///     ERC8183_CORE=0x... \
///     forge script script/Deploy.s.sol:Deploy \
///         --rpc-url base_sepolia --broadcast --verify
///
/// The verifier address is picked automatically from chainid. Override with
/// PRIMUS_VERIFIER env var if you need a non-default deployment (e.g. a
/// staging contract).
///
/// Primus verifier addresses come from Primus's published deployments —
/// see https://docs.primuslabs.xyz/.
contract Deploy is Script {
    error UnsupportedChain(uint256 chainid);
    error ZeroCore();

    function run() external returns (address hook) {
        address core = vm.envAddress("ERC8183_CORE");
        if (core == address(0)) revert ZeroCore();

        address verifier = vm.envOr("PRIMUS_VERIFIER", address(0));
        if (verifier == address(0)) {
            verifier = primusVerifierFor(block.chainid);
        }

        console2.log("chainid          :", block.chainid);
        console2.log("ERC-8183 core    :", core);
        console2.log("Primus verifier  :", verifier);

        vm.startBroadcast();
        hook = address(new ZkTlsAttestationHook(core, verifier));
        vm.stopBroadcast();

        console2.log("Hook deployed at :", hook);
        console2.log();
        console2.log("Next step: have the ERC-8183 admin whitelist this hook:");
        console2.log("    core.setHookWhitelist(", hook, ", true)");
    }

    /// @dev Canonical Primus PrimusZKTLS addresses per chain. Pure so this
    ///      function can also be unit-tested without broadcasting.
    function primusVerifierFor(uint256 chainid) public pure returns (address) {
        // Base + Base Sepolia
        if (chainid == 8453)       return 0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE;
        if (chainid == 84532)      return 0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE;
        // Ethereum Sepolia
        if (chainid == 11155111)   return 0x3760aB354507a29a9F5c65A66C74353fd86393FA;
        // BNB Chain + BNB Testnet
        if (chainid == 56)         return 0xF24199D5D431bE869af3Da61162CbBb58C389324;
        if (chainid == 97)         return 0xBc074EbE6D39A97Fb35726832300a950e2D94324;
        // Arbitrum
        if (chainid == 42161)      return 0x982Cef8d9F184566C2BeC48c4fb9b6e7B0b4A58B;
        // Linea
        if (chainid == 59144)      return 0xe6a7E3d26B898e96fA8bC00fFE6e51b25Dc24d6a;
        // Scroll
        if (chainid == 534352)     return 0x06c3c00dc556d2493A661E6a929d3E17f5F097a4;
        revert UnsupportedChain(chainid);
    }
}
