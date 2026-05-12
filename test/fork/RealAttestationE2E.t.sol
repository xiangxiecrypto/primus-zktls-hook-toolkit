// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    ZkTlsAttestationHook,
    Attestation
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";

contract MockCore {
    struct JobView {
        address client; uint8 status; address provider; uint48 expiredAt;
        address evaluator; uint48 submittedAt; uint256 budget; address hook;
        address paymentToken; uint256 providerAgentId; string description;
    }
    mapping(uint256 => JobView) public jobs;
    function setJob(uint256 jobId, address hookAddr, address providerAddr) external {
        jobs[jobId] = JobView({
            client: address(0xc1), status: 0, provider: providerAddr,
            expiredAt: uint48(block.timestamp + 1 days), evaluator: address(0xe0e),
            submittedAt: 0, budget: 0, hook: hookAddr,
            paymentToken: address(0), providerAgentId: 0, description: ""
        });
    }
    function getJob(uint256 jobId) external view returns (JobView memory) { return jobs[jobId]; }
    function callBefore(IERC8183Hook hook, uint256 jobId, bytes4 sel, bytes calldata d) external {
        hook.beforeAction(jobId, sel, d);
    }
    function callAfter(IERC8183Hook hook, uint256 jobId, bytes4 sel, bytes calldata d) external {
        hook.afterAction(jobId, sel, d);
    }
}

/// @notice The full E2E: real signed Primus attestation → real
///         PrimusZKTLS verifier on Base Sepolia → our hook.
///
///         Opt-in: requires both
///           BASE_SEPOLIA_RPC_URL              and
///           test/fixtures/real-fund.hex etc.  (produced ad-hoc via
///           sdk/scripts/generate-real-fixture.ts).
///
///         When either is missing, the test marks itself skipped.
contract RealAttestationE2ETest is Test {
    address constant PRIMUS_BASE_SEPOLIA = 0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE;
    bytes4 internal constant SEL_FUND   = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 internal constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    address internal constant PROVIDER  = 0x000000000000000000000000000000000000b0b1;
    address internal constant CLIENT    = address(0xc1);
    uint256 internal constant JOB_ID    = 1;

    bool internal ready;

    MockCore internal core;
    ZkTlsAttestationHook internal hook;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        // Skip cleanly when the fixture hasn't been generated. `vm.exists`
        // requires fs_permissions; the read-only allow-list already covers
        // test/fixtures.
        if (!vm.exists("test/fixtures/real-fund.hex")) return;

        vm.createSelectFork(rpc);

        core = new MockCore();
        hook = new ZkTlsAttestationHook(address(core), PRIMUS_BASE_SEPOLIA);
        core.setJob(JOB_ID, address(hook), PROVIDER);

        ready = true;
    }

    function test_RealAttestation_FlowsThroughHook_AndRealVerifier() public {
        vm.skip(!ready);

        bytes memory fundOptParams = vm.parseBytes(vm.readFile("test/fixtures/real-fund.hex"));
        bytes memory submitOptParams = vm.parseBytes(vm.readFile("test/fixtures/real-submit.hex"));
        bytes32 deliverable = vm.parseBytes32(vm.readFile("test/fixtures/real-deliverable.hex"));

        // 1) Configure spec on the hook (client side).
        bytes memory fundData = abi.encode(CLIENT, fundOptParams);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, fundData);

        // 2) Submit with the REAL signed attestation. The hook's
        //    `_verifyOneStep` invokes IZkTlsVerifier.verifyAttestation via
        //    staticcall on the live Primus verifier, which:
        //      - decodes our Attestation struct (proves ABI compatibility);
        //      - recovers the signer from the 65-byte signature;
        //      - checks the signer is in Primus's `_attestors` set.
        //    Then the hook's own per-field hash checks fire.
        bytes memory submitData = abi.encode(PROVIDER, deliverable, submitOptParams);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, submitData);

        assertTrue(hook.isValidated(JOB_ID), "real attestation accepted end-to-end");
    }
}
