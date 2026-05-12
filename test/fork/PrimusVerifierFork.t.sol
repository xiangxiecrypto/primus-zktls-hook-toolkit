// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    ZkTlsAttestationHook,
    Attestation,
    AttNetworkRequest,
    AttNetworkResponseResolve,
    Attestor,
    IZkTlsVerifier
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";

/// @notice Live fork test against the actually-deployed Primus PrimusZKTLS
///         verifier on Base Sepolia (0xCE7c...0afdE).
///
///         These tests do NOT require a valid signed attestation — they
///         prove the more fundamental property that our local Attestation
///         struct shape is *ABI-compatible* with what Primus deployed:
///
///           - A correctly-shaped Attestation can be passed through the
///             external call boundary into Primus's verifier without an
///             ABI decode error.
///           - A semantically-invalid Attestation (empty signatures, etc.)
///             reaches Primus's internal checks and reverts there — proving
///             our struct successfully decoded on the verifier side.
///
///         End-to-end coverage with a real signed attestation comes next
///         (Phase 2) once the off-chain SDK can produce fixtures via the
///         Primus SaaS.
///
///         Opt-in: requires BASE_SEPOLIA_RPC_URL env to be set. Without it,
///         each test skips itself via `vm.skip`.
contract PrimusVerifierForkTest is Test {
    address constant PRIMUS_BASE_SEPOLIA = 0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // No RPC — every test below will mark itself skipped.
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;
    }

    // --------------------------------------------------- sanity / liveness

    function test_PrimusVerifier_IsDeployedOnBaseSepolia() public {
        vm.skip(!forked);
        assertGt(PRIMUS_BASE_SEPOLIA.code.length, 0, "Primus PrimusZKTLS not at expected address");
    }

    function test_Hook_DeploysAgainstRealVerifier() public {
        vm.skip(!forked);
        // Use a non-zero placeholder for the core address; constructor only
        // rejects zero addresses, not non-deployed addresses.
        ZkTlsAttestationHook hook = new ZkTlsAttestationHook(address(0xDEAD), PRIMUS_BASE_SEPOLIA);
        assertEq(hook.zkTlsVerifier(), PRIMUS_BASE_SEPOLIA);
    }

    // ----------------------------- ABI-compatibility against real verifier

    /// @notice Calling the real Primus verifier with an Attestation that has
    ///         no signatures must revert: that proves (a) ABI decode of our
    ///         struct succeeded on Primus's side, and (b) Primus's
    ///         "signatures.length == 1" check is reachable.
    function test_RealVerifier_RejectsEmptySignatures() public {
        vm.skip(!forked);
        Attestation memory att = _bareAttestation();
        vm.expectRevert();
        IZkTlsVerifier(PRIMUS_BASE_SEPOLIA).verifyAttestation(att);
    }

    /// @notice Same shape, but with a single zero-byte signature so the
    ///         "signatures.length == 1" branch is taken. Must revert at the
    ///         next layer (signature length / v range / signer recovery).
    function test_RealVerifier_RejectsMalformedSignature() public {
        vm.skip(!forked);
        Attestation memory att = _bareAttestation();
        att.signatures = new bytes[](1);
        att.signatures[0] = new bytes(65); // 65 zero bytes — wrong v, wrong signer
        vm.expectRevert();
        IZkTlsVerifier(PRIMUS_BASE_SEPOLIA).verifyAttestation(att);
    }

    /// @notice 64-byte signature (wrong length) must hit the length check.
    function test_RealVerifier_RejectsShortSignature() public {
        vm.skip(!forked);
        Attestation memory att = _bareAttestation();
        att.signatures = new bytes[](1);
        att.signatures[0] = new bytes(64);
        vm.expectRevert();
        IZkTlsVerifier(PRIMUS_BASE_SEPOLIA).verifyAttestation(att);
    }

    // ------------------------------------------------------------- helpers

    function _bareAttestation() internal pure returns (Attestation memory) {
        return Attestation({
            recipient: address(0xb0b),
            request: AttNetworkRequest({
                url: "https://api.example.com/x",
                header: "",
                method: "GET",
                body: ""
            }),
            reponseResolve: new AttNetworkResponseResolve[](0),
            data: "",
            attConditions: "",
            timestamp: 1700000000,
            additionParams: "",
            attestors: new Attestor[](0),
            signatures: new bytes[](0)
        });
    }
}
