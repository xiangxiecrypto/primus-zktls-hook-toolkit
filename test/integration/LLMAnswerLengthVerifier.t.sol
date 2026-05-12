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
    AttestationSpec
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";
import {LLMAnswerLengthVerifier} from "../../contracts/extensions/LLMAnswerLengthVerifier.sol";
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
    function callAfter(IERC8183Hook hook, uint256 jobId, bytes4 sel, bytes calldata d) external {
        hook.afterAction(jobId, sel, d);
    }
    function callBefore(IERC8183Hook hook, uint256 jobId, bytes4 sel, bytes calldata d) external {
        hook.beforeAction(jobId, sel, d);
    }
}

contract AcceptingVerifier {
    function verifyAttestation(Attestation calldata) external pure {}
}

/// @notice End-to-end through the hook's customVerifier path: spec sets
///         `customVerifier = LLMAnswerLengthVerifier`, hook delegates after
///         every generic check passes, and the answer's byte length is
///         enforced. Covers the happy path plus the two reject paths
///         (too short / too long) and a couple of malformed-input edges.
contract LLMAnswerLengthVerifierTest is Test {
    bytes4 internal constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 internal constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    address internal constant CLIENT = address(0xc1);
    address internal constant PROVIDER = address(0xb0b);
    uint256 internal constant JOB_ID = 1;

    MockCore internal core;
    AcceptingVerifier internal zkVerifier;
    ZkTlsAttestationHook internal hook;

    function setUp() public {
        core = new MockCore();
        zkVerifier = new AcceptingVerifier();
        hook = new ZkTlsAttestationHook(address(core), address(zkVerifier));
        core.setJob(JOB_ID, address(hook));
        vm.warp(block.timestamp + 1 hours);
    }

    // -------- helpers --------

    function _makeAtt(string memory data) internal view returns (Attestation memory) {
        return Attestation({
            recipient: PROVIDER,
            request: AttNetworkRequest({url: "https://api.llm.example/chat", header: "", method: "POST", body: "{}"}),
            reponseResolve: new AttNetworkResponseResolve[](0),
            data: data,
            attConditions: "",
            timestamp: uint64(block.timestamp * 1000),
            additionParams: "",
            attestors: new Attestor[](0),
            signatures: new bytes[](0)
        });
    }

    function _step(Attestation memory att) internal pure returns (RequestStep memory) {
        return RequestStep({
            methodHash: keccak256(bytes(att.request.method)),
            urlHash: keccak256(bytes(att.request.url)),
            bodyHash: keccak256(bytes(att.request.body)),
            responseResolveHash: keccak256(abi.encode(new bytes32[](0))),
            additionParamsHash: keccak256(bytes(att.additionParams)),
            maxAge: 300,
            pinnedAttestor: address(0)
        });
    }

    function _fund(LLMAnswerLengthVerifier verifier, Attestation memory att) internal {
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _step(att);
        AttestationSpec memory spec = AttestationSpec({
            steps: steps,
            bindings: new DataBinding[](0),
            deliverableSourceStep: 0,
            customVerifier: address(verifier),
            configured: false
        });
        bytes memory data = abi.encode(CLIENT, abi.encode(spec));
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function _submit(Attestation memory att) internal {
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function _submitExpectFail(Attestation memory att, bytes4 expectedSelector) internal {
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(expectedSelector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    // -------- constructor --------

    function test_Constructor_RejectsEmptyKey() public {
        vm.expectRevert(LLMAnswerLengthVerifier.InvalidConfig.selector);
        new LLMAnswerLengthVerifier(0, "", 1, 100);
    }

    function test_Constructor_RejectsInvertedRange() public {
        vm.expectRevert(LLMAnswerLengthVerifier.InvalidConfig.selector);
        new LLMAnswerLengthVerifier(0, "answer", 200, 100);
    }

    // -------- happy path --------

    function test_AcceptsAnswerInsideRange() public {
        // 'answer' value below is 22 bytes long.
        LLMAnswerLengthVerifier verifier = new LLMAnswerLengthVerifier(0, "answer", 10, 100);
        Attestation memory att = _makeAtt('{"answer":"Bitcoin is a network."}');
        _fund(verifier, att);
        _submit(att);
        assertTrue(hook.isValidated(JOB_ID));
    }

    // -------- rejection paths --------

    function test_RejectsTooShort() public {
        LLMAnswerLengthVerifier verifier = new LLMAnswerLengthVerifier(0, "answer", 50, 100);
        Attestation memory att = _makeAtt('{"answer":"too short"}');
        _fund(verifier, att);
        // The hook reports ExtensionVerifierFailed; the verifier itself
        // reverted AnswerTooShort, but that's wrapped by the hook's staticcall
        // failure handling.
        _submitExpectFail(att, ZkTlsAttestationHook.ExtensionVerifierFailed.selector);
    }

    function test_RejectsTooLong() public {
        LLMAnswerLengthVerifier verifier = new LLMAnswerLengthVerifier(0, "answer", 0, 10);
        Attestation memory att = _makeAtt('{"answer":"this answer is much longer than allowed"}');
        _fund(verifier, att);
        _submitExpectFail(att, ZkTlsAttestationHook.ExtensionVerifierFailed.selector);
    }

    function test_RejectsKeyMissing() public {
        LLMAnswerLengthVerifier verifier = new LLMAnswerLengthVerifier(0, "answer", 1, 100);
        Attestation memory att = _makeAtt('{"other_field":"x"}');
        _fund(verifier, att);
        _submitExpectFail(att, ZkTlsAttestationHook.ExtensionVerifierFailed.selector);
    }

    // -------- escape handling --------

    /// @notice An answer containing `\"` (escaped quote) must not be treated
    ///         as terminated early. The byte length convention counts the
    ///         escape sequence as 2 raw bytes.
    function test_HandlesEscapedQuotes() public {
        LLMAnswerLengthVerifier verifier = new LLMAnswerLengthVerifier(0, "answer", 1, 100);
        // Raw answer value bytes between the wrapping quotes: she said \"hi\"
        // That's 16 bytes if we count `\"` as 2 bytes each.
        Attestation memory att = _makeAtt('{"answer":"she said \\"hi\\""}');
        _fund(verifier, att);
        _submit(att);
        assertTrue(hook.isValidated(JOB_ID));
    }

    /// @notice Unterminated answer string ("answer":"...) must revert rather
    ///         than silently parse to zero length.
    function test_UnterminatedString_Reverts() public {
        LLMAnswerLengthVerifier verifier = new LLMAnswerLengthVerifier(0, "answer", 1, 100);
        Attestation memory att = _makeAtt('{"answer":"no closing quote here');
        _fund(verifier, att);
        _submitExpectFail(att, ZkTlsAttestationHook.ExtensionVerifierFailed.selector);
    }
}
