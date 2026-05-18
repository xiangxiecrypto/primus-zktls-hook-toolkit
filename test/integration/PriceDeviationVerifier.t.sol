// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    ZkTlsAttestationHook,
    Attestation,
    AttNetworkRequest,
    AttNetworkResponseResolve,
    Attestor,
    RequestStep,
    DataBinding,
    AttestationSpec,
    TimeUnit
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";
import {PriceDeviationVerifier} from "../../contracts/extensions/PriceDeviationVerifier.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";

contract MockCore {
    struct JobView {
        address client; uint8 status; address provider; uint48 expiredAt;
        address evaluator; uint48 submittedAt; uint256 budget; address hook;
        address paymentToken; uint256 providerAgentId; string description;
    }
    mapping(uint256 => JobView) public jobs;
    function setJob(uint256 jobId, address hookAddr) external {
        jobs[jobId] = JobView({
            client: address(0xc1), status: 0, provider: address(0xb0b),
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

contract AcceptingVerifier {
    function verifyAttestation(Attestation calldata) external pure {}
}

/// @notice Validates the PriceDeviationVerifier extension end-to-end through
///         the hook's customVerifier path (not by direct call), so the
///         staticcall plumbing and IAttestationExtensionVerifier ABI are
///         covered alongside the price-comparison logic.
contract PriceDeviationVerifierTest is Test {
    bytes4 internal constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 internal constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));

    address internal constant CLIENT = address(0xc1);
    address internal constant PROVIDER = address(0xb0b);
    address internal constant OWNER = address(0xada);
    uint256 internal constant JOB_ID = 1;

    MockCore internal core;
    AcceptingVerifier internal zkVerifier;
    ZkTlsAttestationHook internal hook;

    function setUp() public {
        core = new MockCore();
        zkVerifier = new AcceptingVerifier();
        hook = new ZkTlsAttestationHook(address(core), address(zkVerifier), OWNER);
        core.setJob(JOB_ID, address(hook));
        vm.warp(block.timestamp + 1 hours);
    }

    function _makeAtt(uint256 jobId, string memory url, string memory data) internal view returns (Attestation memory) {
        string memory additionParams = string.concat(
            '{"algorithmType":"proxytls","jobBinding":"', _toHex(hook.jobBindingFor(jobId)), '"}'
        );
        return Attestation({
            recipient: PROVIDER,
            request: AttNetworkRequest({url: url, header: "", method: "GET", body: ""}),
            reponseResolve: new AttNetworkResponseResolve[](0),
            data: data,
            attConditions: "",
            timestamp: uint64(block.timestamp * 1000),
            additionParams: additionParams,
            attestors: new Attestor[](0),
            signatures: new bytes[](0)
        });
    }

    function _stepFor(uint256 jobId, Attestation memory att) internal view returns (RequestStep memory) {
        return RequestStep({
            methodHash: keccak256(bytes(att.request.method)),
            urlHash: keccak256(bytes(att.request.url)),
            bodyHash: keccak256(bytes(att.request.body)),
            responseResolveHash: keccak256(abi.encode(new bytes32[](0))),
            additionParamsHash: keccak256(bytes(att.additionParams)),
            expectedJobBinding: hook.jobBindingFor(jobId),
            maxAge: 300,
            timeUnit: TimeUnit.Milliseconds,
            allowedAttestors: new address[](0),
            minAttestorsRequired: 0
        });
    }

    function _twoPriceSpec(Attestation memory a, Attestation memory b, address customVerifier)
        internal view returns (AttestationSpec memory spec)
    {
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(JOB_ID, a);
        steps[1] = _stepFor(JOB_ID, b);
        spec = AttestationSpec({
            steps: steps,
            bindings: new DataBinding[](0),
            deliverableSourceStep: 1,
            customVerifier: customVerifier,
            zkTlsVerifierSnapshot: address(0),
            configured: false
        });
    }

    function _toHex(bytes32 v) internal pure returns (string memory) {
        bytes memory out = new bytes(66);
        out[0] = "0"; out[1] = "x";
        for (uint256 i = 0; i < 32; ++i) {
            uint8 b = uint8(v[i]);
            out[2 + 2*i]     = bytes1((b >> 4) < 10 ? (b >> 4) + 0x30 : (b >> 4) + 0x57);
            out[2 + 2*i + 1] = bytes1((b & 0x0f) < 10 ? (b & 0x0f) + 0x30 : (b & 0x0f) + 0x57);
        }
        return string(out);
    }

    function _fund(bytes memory optParams) internal {
        bytes memory data = abi.encode(CLIENT, optParams);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function _submit(bytes32 deliverable, bytes memory optParams) internal {
        bytes memory data = abi.encode(PROVIDER, deliverable, optParams);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_PriceWithinDeviation_Passes() public {
        // 5% max deviation; prices differ by 1.5% → accepted.
        PriceDeviationVerifier ext = new PriceDeviationVerifier(0, 1, "price_usd", 500);
        vm.prank(OWNER);
        hook.setTrustedExtensionVerifier(address(ext), true);

        Attestation memory a = _makeAtt(JOB_ID, "https://exchange-a.example/btc", "{\"price_usd\":67000.00}");
        Attestation memory b = _makeAtt(JOB_ID, "https://exchange-b.example/btc", "{\"price_usd\":68000.00}");
        _fund(abi.encode(_twoPriceSpec(a, b, address(ext))));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = a; atts[1] = b;
        _submit(keccak256(bytes(b.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }

    function test_PriceBeyondDeviation_Reverts() public {
        // 5% max; prices differ by ~10% → rejected.
        PriceDeviationVerifier ext = new PriceDeviationVerifier(0, 1, "price_usd", 500);
        vm.prank(OWNER);
        hook.setTrustedExtensionVerifier(address(ext), true);

        Attestation memory a = _makeAtt(JOB_ID, "https://exchange-a.example/btc", "{\"price_usd\":60000.00}");
        Attestation memory b = _makeAtt(JOB_ID, "https://exchange-b.example/btc", "{\"price_usd\":66000.00}");
        _fund(abi.encode(_twoPriceSpec(a, b, address(ext))));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = a; atts[1] = b;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(b.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.ExtensionVerifierFailed.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_MissingKey_Reverts() public {
        PriceDeviationVerifier ext = new PriceDeviationVerifier(0, 1, "price_usd", 500);
        vm.prank(OWNER);
        hook.setTrustedExtensionVerifier(address(ext), true);

        // step b is missing the "price_usd" key entirely
        Attestation memory a = _makeAtt(JOB_ID, "https://exchange-a.example/btc", "{\"price_usd\":60000.00}");
        Attestation memory b = _makeAtt(JOB_ID, "https://exchange-b.example/btc", "{\"value\":60000.00}");
        _fund(abi.encode(_twoPriceSpec(a, b, address(ext))));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = a; atts[1] = b;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(b.data)), abi.encode(atts, bytes("")));
        // Reverts inside the extension verifier with PriceNotFound; the hook
        // catches it as ExtensionVerifierFailed via the staticcall boundary.
        vm.expectRevert(ZkTlsAttestationHook.ExtensionVerifierFailed.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Constructor_RejectsBadConfig() public {
        vm.expectRevert(PriceDeviationVerifier.InvalidConfig.selector);
        new PriceDeviationVerifier(0, 0, "price", 500); // same step index

        vm.expectRevert(PriceDeviationVerifier.InvalidConfig.selector);
        new PriceDeviationVerifier(0, 1, "", 500); // empty key

        vm.expectRevert(PriceDeviationVerifier.InvalidConfig.selector);
        new PriceDeviationVerifier(0, 1, "price", 0); // zero deviation

        vm.expectRevert(PriceDeviationVerifier.InvalidConfig.selector);
        new PriceDeviationVerifier(0, 1, "price", 10_001); // > 100%
    }
}
