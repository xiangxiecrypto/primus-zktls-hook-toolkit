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
    IZkTlsVerifier,
    IAttestationExtensionVerifier
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";
import {IERC8183HookMetadata} from "@erc8183-hooks/interfaces/IERC8183HookMetadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Stand-in for the ERC-8183 core in unit tests. Acts as the authorized
///      caller of the hook's beforeAction/afterAction. Provides a settable
///      job.hook value so the onlyERC8183 modifier resolves correctly when
///      the router path is exercised separately (not used by these tests).
contract MockCore {
    struct JobView {
        address client;
        uint8 status;
        address provider;
        uint48 expiredAt;
        address evaluator;
        uint48 submittedAt;
        uint256 budget;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        string description;
    }

    mapping(uint256 => JobView) public jobs;

    function setJob(uint256 jobId, address hook) external {
        jobs[jobId] = JobView({
            client: address(0xc1),
            status: 0,
            provider: address(0xb0b),
            expiredAt: uint48(block.timestamp + 1 days),
            evaluator: address(0xe0e),
            submittedAt: 0,
            budget: 0,
            hook: hook,
            paymentToken: address(0),
            providerAgentId: 0,
            description: ""
        });
    }

    function getJob(uint256 jobId) external view returns (JobView memory) {
        return jobs[jobId];
    }

    function callBefore(IERC8183Hook hook, uint256 jobId, bytes4 selector, bytes calldata data) external {
        hook.beforeAction(jobId, selector, data);
    }

    function callAfter(IERC8183Hook hook, uint256 jobId, bytes4 selector, bytes calldata data) external {
        hook.afterAction(jobId, selector, data);
    }
}

/// @dev Toggleable mock zkTLS verifier. revertOnVerify is the global default;
///      a per-recipient override lets specific attestations be rejected.
contract MockZkTlsVerifier {
    bool public revertOnVerify;
    mapping(address => bool) public revertForRecipient;

    function setRevert(bool v) external {
        revertOnVerify = v;
    }

    function setRevertForRecipient(address r, bool v) external {
        revertForRecipient[r] = v;
    }

    function verifyAttestation(Attestation calldata att) external view {
        if (revertOnVerify) revert("mock verifier: rejected");
        if (revertForRecipient[att.recipient]) revert("mock verifier: rejected for recipient");
    }
}

/// @dev Mock extension verifier — flips between accept and reject.
contract MockExtensionVerifier is IAttestationExtensionVerifier {
    bool public shouldRevert;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function verify(
        uint256 /*jobId*/,
        bytes32 /*deliverable*/,
        Attestation[] calldata /*attestations*/,
        bytes calldata /*customCalldata*/
    ) external view {
        if (shouldRevert) revert("mock ext: reject");
    }
}

contract ZkTlsAttestationHookTest is Test {
    bytes4 internal constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 internal constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));

    address internal constant CLIENT   = address(0xc1);
    address internal constant PROVIDER = address(0xb0b);
    uint256 internal constant JOB_ID   = 1;

    MockCore internal core;
    MockZkTlsVerifier internal verifier;
    ZkTlsAttestationHook internal hook;

    function setUp() public {
        core = new MockCore();
        verifier = new MockZkTlsVerifier();
        hook = new ZkTlsAttestationHook(address(core), address(verifier));
        core.setJob(JOB_ID, address(hook));
        // Move clock forward so attestation timestamps don't underflow when
        // tests build "fresh" attestations using block.timestamp.
        vm.warp(block.timestamp + 1 hours);
    }

    // ---------------------------------------------------------------- helpers

    function _emptyResolves() internal pure returns (AttNetworkResponseResolve[] memory) {
        return new AttNetworkResponseResolve[](0);
    }

    function _emptyAttestors() internal pure returns (Attestor[] memory) {
        return new Attestor[](0);
    }

    function _emptySignatures() internal pure returns (bytes[] memory) {
        return new bytes[](0);
    }

    function _makeAtt(
        string memory url,
        string memory method,
        string memory body,
        string memory data,
        string memory additionParams,
        AttNetworkResponseResolve[] memory resolves
    ) internal view returns (Attestation memory) {
        return Attestation({
            recipient: PROVIDER,
            request: AttNetworkRequest({url: url, header: "", method: method, body: body}),
            reponseResolve: resolves,
            data: data,
            attConditions: "",
            timestamp: uint64(block.timestamp * 1000),
            additionParams: additionParams,
            attestors: _emptyAttestors(),
            signatures: _emptySignatures()
        });
    }

    function _stepFor(Attestation memory att, uint64 maxAge) internal pure returns (RequestStep memory) {
        return RequestStep({
            methodHash: keccak256(bytes(att.request.method)),
            urlHash: keccak256(bytes(att.request.url)),
            bodyHash: keccak256(bytes(att.request.body)),
            responseResolveHash: _hashResolves(att.reponseResolve),
            additionParamsHash: keccak256(bytes(att.additionParams)),
            maxAge: maxAge,
            pinnedAttestor: address(0)
        });
    }

    function _hashResolves(AttNetworkResponseResolve[] memory rs) internal pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](rs.length);
        for (uint256 i = 0; i < rs.length; ++i) {
            leaves[i] = keccak256(abi.encode(rs[i].keyName, rs[i].parseType, rs[i].parsePath));
        }
        return keccak256(abi.encode(leaves));
    }

    function _fund(bytes memory optParams) internal {
        bytes memory data = abi.encode(CLIENT, optParams);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function _submit(bytes32 deliverable, bytes memory optParams) internal {
        bytes memory data = abi.encode(PROVIDER, deliverable, optParams);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
        // afterAction is a no-op for this hook on submit — exercise it anyway
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function _bareSpec(RequestStep[] memory steps, DataBinding[] memory bindings) internal pure returns (AttestationSpec memory) {
        return AttestationSpec({
            steps: steps,
            bindings: bindings,
            deliverableSourceStep: uint8(steps.length - 1),
            customVerifier: address(0),
            configured: false
        });
    }

    // ---------------------------------------------------------- constructor

    function test_Constructor_RevertsOnZeroVerifier() public {
        vm.expectRevert(ZkTlsAttestationHook.InvalidZkTlsVerifier.selector);
        new ZkTlsAttestationHook(address(core), address(0));
    }

    function test_Constructor_StoresVerifier() public view {
        assertEq(hook.zkTlsVerifier(), address(verifier));
    }

    function test_Constructor_RevertsOnZeroCore() public {
        // BaseERC8183Hook validates the core address; selector is in BaseERC8183Hook.
        vm.expectRevert(); // InvalidERC8183Contract
        new ZkTlsAttestationHook(address(0), address(verifier));
    }

    // ------------------------------------------- happy path: 1 step, no binding

    function test_HappyPath_SingleStep() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/price",
            "GET",
            "",
            "67234.51",
            "{\"algorithmType\":\"proxytls\"}",
            _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        DataBinding[] memory bindings = new DataBinding[](0);

        AttestationSpec memory spec = _bareSpec(steps, bindings);
        _fund(abi.encode(spec));

        bytes32 deliverable = keccak256(bytes(att.data));
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(deliverable, abi.encode(atts, bytes("")));

        assertTrue(hook.isValidated(JOB_ID));
    }

    // ----------------------------------- happy path: 2 steps + static binding

    function test_HappyPath_TwoStepsWithBinding() public {
        // step 0: GET /coins/bitcoin → data containing the literal "bitcoin"
        Attestation memory att0 = _makeAtt(
            "https://api.example.com/coins/bitcoin",
            "GET",
            "",
            "{\"id\":\"bitcoin\"}",
            "{\"algorithmType\":\"proxytls\"}",
            _emptyResolves()
        );
        // step 1: URL embeds "bitcoin" (the value flowing across)
        Attestation memory att1 = _makeAtt(
            "https://api.example.com/coins/bitcoin/history",
            "GET",
            "",
            "{\"price_usd\":67234.51}",
            "{\"algorithmType\":\"proxytls\"}",
            _emptyResolves()
        );

        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(att0, 300);
        steps[1] = _stepFor(att1, 300);

        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({
            fromStep: 0,
            toStep: 1,
            toLocation: 0, // url
            value: bytes("bitcoin")
        });

        AttestationSpec memory spec = _bareSpec(steps, bindings);
        _fund(abi.encode(spec));

        bytes32 deliverable = keccak256(bytes(att1.data));
        Attestation[] memory atts = new Attestation[](2);
        atts[0] = att0;
        atts[1] = att1;
        _submit(deliverable, abi.encode(atts, bytes("")));

        assertTrue(hook.isValidated(JOB_ID));
    }

    // --------------------------------------------------------- failure paths

    function test_Revert_SpecNotConfigured() public {
        // Skip fund, go straight to submit
        Attestation[] memory atts = new Attestation[](0);
        bytes32 deliverable = keccak256("anything");
        bytes memory data = abi.encode(PROVIDER, deliverable, abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.SpecNotConfigured.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_StepCountMismatch() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        // Submit zero attestations when spec expects one
        Attestation[] memory atts = new Attestation[](0);
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.StepCountMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_AttestationVerifierFailed() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        verifier.setRevert(true);
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.AttestationVerifierFailed.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_MethodHashMismatch() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        // Provider submits the SAME spec but tampers the method on the attestation
        att.request.method = "POST";

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.MethodHashMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_UrlHashMismatch() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        att.request.url = "https://malicious.example/x";
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.UrlHashMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_BodyHashMismatch() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "POST", "{\"a\":1}", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        att.request.body = "{\"a\":2}";
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.BodyHashMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_ResponseResolveHashMismatch() public {
        AttNetworkResponseResolve[] memory rs = new AttNetworkResponseResolve[](1);
        rs[0] = AttNetworkResponseResolve({keyName: "price", parseType: "json", parsePath: "$.price"});
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "{\"price\":1}", "", rs
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        // tamper response schema
        att.reponseResolve[0].parsePath = "$.different";
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.ResponseResolveHashMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_AdditionParamsHashMismatch_AttModeDowngrade() public {
        // Spec pins mpctls; provider submits proxytls attestation
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v",
            "{\"algorithmType\":\"mpctls\"}", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        att.additionParams = "{\"algorithmType\":\"proxytls\"}";
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.AdditionParamsHashMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_AttestationStale() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        // maxAge = 60s
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 60);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        // Warp 5 minutes past the attestation timestamp
        vm.warp(block.timestamp + 5 minutes);
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.AttestationStale.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_PinnedAttestorMismatch() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        att.attestors = new Attestor[](1);
        att.attestors[0] = Attestor({attestorAddr: address(0xAAAA), url: "att"});
        RequestStep memory step = _stepFor(att, 300);
        step.pinnedAttestor = address(0xBBBB); // different from att.attestors[0].attestorAddr
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.PinnedAttestorMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_PinnedAttestor_Match() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        att.attestors = new Attestor[](1);
        att.attestors[0] = Attestor({attestorAddr: address(0xAAAA), url: "att"});
        RequestStep memory step = _stepFor(att, 300);
        step.pinnedAttestor = address(0xAAAA);
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }

    function test_Revert_DataBindingViolated_NotInSource() public {
        Attestation memory att0 = _makeAtt(
            "https://api.example.com/coins/bitcoin", "GET", "",
            "{\"id\":\"ethereum\"}", "", _emptyResolves() // source data does NOT contain "bitcoin"
        );
        Attestation memory att1 = _makeAtt(
            "https://api.example.com/coins/bitcoin/history", "GET", "",
            "{\"x\":1}", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(att0, 300);
        steps[1] = _stepFor(att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({fromStep: 0, toStep: 1, toLocation: 0, value: bytes("bitcoin")});
        _fund(abi.encode(_bareSpec(steps, bindings)));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = att0;
        atts[1] = att1;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att1.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.DataBindingViolated.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_DataBindingViolated_NotInDestination() public {
        Attestation memory att0 = _makeAtt(
            "https://api.example.com/coins/bitcoin", "GET", "",
            "{\"id\":\"bitcoin\"}", "", _emptyResolves()
        );
        Attestation memory att1 = _makeAtt(
            "https://api.example.com/coins/ethereum/history", "GET", "", // dest url does NOT contain "bitcoin"
            "{\"x\":1}", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(att0, 300);
        steps[1] = _stepFor(att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({fromStep: 0, toStep: 1, toLocation: 0, value: bytes("bitcoin")});
        _fund(abi.encode(_bareSpec(steps, bindings)));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = att0;
        atts[1] = att1;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att1.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.DataBindingViolated.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function test_Revert_DeliverableMismatch() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "real-data", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        bytes32 wrongDeliverable = keccak256("totally-different");
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, wrongDeliverable, abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.DeliverableMismatch.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    // --------------------------------------------------- extension verifier

    function test_ExtensionVerifier_Accepted() public {
        MockExtensionVerifier ext = new MockExtensionVerifier();
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        spec.customVerifier = address(ext);
        _fund(abi.encode(spec));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("opaque-extension-blob")));
        assertTrue(hook.isValidated(JOB_ID));
    }

    function test_Revert_ExtensionVerifierFailed() public {
        MockExtensionVerifier ext = new MockExtensionVerifier();
        ext.setShouldRevert(true);
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        spec.customVerifier = address(ext);
        _fund(abi.encode(spec));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.ExtensionVerifierFailed.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    // ------------------------------------------------- spec config errors

    function test_Revert_EmptySteps() public {
        AttestationSpec memory spec = AttestationSpec({
            steps: new RequestStep[](0),
            bindings: new DataBinding[](0),
            deliverableSourceStep: 0,
            customVerifier: address(0),
            configured: false
        });
        bytes memory data = abi.encode(CLIENT, abi.encode(spec));
        vm.expectRevert(ZkTlsAttestationHook.EmptySteps.selector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function test_Revert_InvalidDeliverableSourceStep() public {
        Attestation memory att = _makeAtt("https://x", "GET", "", "v", "", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        spec.deliverableSourceStep = 5; // out of range
        bytes memory data = abi.encode(CLIENT, abi.encode(spec));
        vm.expectRevert(ZkTlsAttestationHook.InvalidDeliverableSourceStep.selector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function test_Revert_InvalidBinding_BackwardOrSame() public {
        Attestation memory att0 = _makeAtt("https://x", "GET", "", "v", "", _emptyResolves());
        Attestation memory att1 = _makeAtt("https://y", "GET", "", "v", "", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(att0, 300);
        steps[1] = _stepFor(att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({fromStep: 1, toStep: 0, toLocation: 0, value: bytes("v")}); // backward
        bytes memory data = abi.encode(CLIENT, abi.encode(_bareSpec(steps, bindings)));
        vm.expectRevert(ZkTlsAttestationHook.InvalidBinding.selector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function test_Revert_InvalidLocation() public {
        Attestation memory att0 = _makeAtt("https://x", "GET", "", "v", "", _emptyResolves());
        Attestation memory att1 = _makeAtt("https://y", "GET", "", "v", "", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(att0, 300);
        steps[1] = _stepFor(att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({fromStep: 0, toStep: 1, toLocation: 99, value: bytes("v")});
        bytes memory data = abi.encode(CLIENT, abi.encode(_bareSpec(steps, bindings)));
        vm.expectRevert(ZkTlsAttestationHook.InvalidLocation.selector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function test_Revert_InvalidBinding_EmptyValue() public {
        Attestation memory att0 = _makeAtt("https://x", "GET", "", "v", "", _emptyResolves());
        Attestation memory att1 = _makeAtt("https://y", "GET", "", "v", "", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(att0, 300);
        steps[1] = _stepFor(att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({fromStep: 0, toStep: 1, toLocation: 0, value: bytes("")});
        bytes memory data = abi.encode(CLIENT, abi.encode(_bareSpec(steps, bindings)));
        vm.expectRevert(ZkTlsAttestationHook.InvalidBinding.selector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function test_Revert_SpecAlreadyConfigured() public {
        Attestation memory att = _makeAtt("https://x", "GET", "", "v", "", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        // Replay fund with another non-empty spec — must revert
        bytes memory data = abi.encode(CLIENT, abi.encode(_bareSpec(steps, new DataBinding[](0))));
        vm.expectRevert(ZkTlsAttestationHook.SpecAlreadyConfigured.selector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function test_Fund_EmptyOptParams_IsNoop() public {
        // Empty optParams must not configure a spec, but also must not revert.
        _fund(bytes(""));
        (, , , , bool configured) = hook.getSpec(JOB_ID);
        assertFalse(configured);
    }

    function test_Revert_AlreadyValidated() public {
        Attestation memory att = _makeAtt(
            "https://api.example.com/x", "GET", "", "v", "", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("")));

        bytes memory data = abi.encode(PROVIDER, keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.AlreadyValidated.selector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    // -------------------------------------------- onlyERC8183 enforcement

    function test_Revert_OnlyERC8183Contract() public {
        // Direct call from an EOA / unrelated contract must fail
        Attestation[] memory atts = new Attestation[](0);
        bytes memory data = abi.encode(PROVIDER, bytes32(uint256(1)), abi.encode(atts, bytes("")));
        vm.prank(address(0xDEAD));
        vm.expectRevert(); // BaseERC8183Hook.OnlyERC8183Contract
        IERC8183Hook(address(hook)).beforeAction(JOB_ID, SEL_SUBMIT, data);
    }

    // -------------------------------------------- metadata / interfaces

    function test_RequiredSelectors() public view {
        bytes4[] memory sels = hook.requiredSelectors();
        assertEq(sels.length, 2);
        assertEq(sels[0], SEL_FUND);
        assertEq(sels[1], SEL_SUBMIT);
    }

    function test_SupportsInterface() public view {
        assertTrue(hook.supportsInterface(type(IERC8183Hook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC8183HookMetadata).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(0xdeadbeef));
    }

    // -------------------------------------------- bound checks

    function test_Revert_TooManySteps() public {
        RequestStep[] memory steps = new RequestStep[](17);
        for (uint256 i = 0; i < steps.length; ++i) {
            // dummy steps — content doesn't matter since the bound check is first
            steps[i] = RequestStep({
                methodHash: bytes32(0),
                urlHash: bytes32(0),
                bodyHash: bytes32(0),
                responseResolveHash: bytes32(0),
                additionParamsHash: bytes32(0),
                maxAge: 0,
                pinnedAttestor: address(0)
            });
        }
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        bytes memory data = abi.encode(CLIENT, abi.encode(spec));
        vm.expectRevert(ZkTlsAttestationHook.TooManySteps.selector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }
}
