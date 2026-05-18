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
    TimeUnit,
    IZkTlsVerifier,
    IAttestationExtensionVerifier
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";
import {IERC8183Hook} from "@erc8183/IERC8183Hook.sol";
import {IERC8183HookMetadata} from "@erc8183-hooks/interfaces/IERC8183HookMetadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// =============================================================================
//                                  MOCKS
// =============================================================================

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

contract MockZkTlsVerifier {
    bool public revertOnVerify;
    function setRevert(bool v) external { revertOnVerify = v; }
    function verifyAttestation(Attestation calldata) external view {
        if (revertOnVerify) revert("mock verifier: rejected");
    }
}

contract MockExtensionVerifier is IAttestationExtensionVerifier {
    bool public shouldRevert;
    function setShouldRevert(bool v) external { shouldRevert = v; }
    function verify(uint256, bytes32, Attestation[] calldata, bytes calldata) external view {
        if (shouldRevert) revert("mock ext: reject");
    }
}

contract NewVerifier {
    function verifyAttestation(Attestation calldata) external pure {}
}

// =============================================================================
//                                TEST BASE
// =============================================================================

abstract contract HookTestBase is Test {
    bytes4 internal constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 internal constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));

    address internal constant CLIENT   = address(0xc1);
    address internal constant PROVIDER = address(0xb0b);
    address internal constant OWNER    = address(0xada);
    uint256 internal constant JOB_ID   = 1;

    MockCore internal core;
    MockZkTlsVerifier internal verifier;
    ZkTlsAttestationHook internal hook;

    function setUp() public virtual {
        core = new MockCore();
        verifier = new MockZkTlsVerifier();
        hook = new ZkTlsAttestationHook(address(core), address(verifier), OWNER);
        core.setJob(JOB_ID, address(hook));
        // Warp forward so attestation timestamps don't underflow when tests
        // stamp att.timestamp at block.timestamp * 1000.
        vm.warp(block.timestamp + 1 hours);
    }

    // ----- attestation factory -------------------------------------------------

    /// @dev Helper: build an Attestation whose additionParams already contains
    ///      the right per-job binding for `jobId`. Provider-side off-chain code
    ///      does the same thing.
    function _makeAtt(
        uint256 jobId,
        string memory url,
        string memory method,
        string memory body,
        string memory data,
        AttNetworkResponseResolve[] memory resolves
    ) internal view returns (Attestation memory) {
        bytes32 binding = hook.jobBindingFor(jobId);
        string memory additionParams = string.concat(
            '{"algorithmType":"proxytls","jobBinding":"',
            _toHexString(binding),
            '"}'
        );
        return _makeAttRaw(url, method, body, data, additionParams, resolves);
    }

    function _makeAttRaw(
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
            attestors: new Attestor[](0),
            signatures: new bytes[](0)
        });
    }

    // ----- spec factory --------------------------------------------------------

    function _stepFor(
        uint256 jobId,
        Attestation memory att,
        uint64 maxAge
    ) internal view returns (RequestStep memory) {
        return RequestStep({
            methodHash: keccak256(bytes(att.request.method)),
            urlHash: keccak256(bytes(att.request.url)),
            bodyHash: keccak256(bytes(att.request.body)),
            responseResolveHash: _hashResolves(att.reponseResolve),
            additionParamsHash: keccak256(bytes(att.additionParams)),
            expectedJobBinding: hook.jobBindingFor(jobId),
            maxAge: maxAge,
            timeUnit: TimeUnit.Milliseconds,
            allowedAttestors: new address[](0),
            minAttestorsRequired: 0
        });
    }

    function _hashResolves(AttNetworkResponseResolve[] memory rs) internal pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](rs.length);
        for (uint256 i = 0; i < rs.length; ++i) {
            leaves[i] = keccak256(abi.encode(rs[i].keyName, rs[i].parseType, rs[i].parsePath));
        }
        return keccak256(abi.encode(leaves));
    }

    function _bareSpec(RequestStep[] memory steps, DataBinding[] memory bindings)
        internal pure returns (AttestationSpec memory)
    {
        return AttestationSpec({
            steps: steps,
            bindings: bindings,
            deliverableSourceStep: uint8(steps.length - 1),
            customVerifier: address(0),
            zkTlsVerifierSnapshot: address(0), // filled in on-chain at _postFund
            configured: false
        });
    }

    function _emptyResolves() internal pure returns (AttNetworkResponseResolve[] memory) {
        return new AttNetworkResponseResolve[](0);
    }

    // ----- lifecycle drivers ---------------------------------------------------

    function _fund(bytes memory optParams) internal {
        bytes memory data = abi.encode(CLIENT, optParams);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function _fundExpectRevert(bytes memory optParams, bytes4 expectedSelector) internal {
        bytes memory data = abi.encode(CLIENT, optParams);
        vm.expectRevert(expectedSelector);
        core.callAfter(IERC8183Hook(address(hook)), JOB_ID, SEL_FUND, data);
    }

    function _submit(bytes32 deliverable, bytes memory optParams) internal {
        bytes memory data = abi.encode(PROVIDER, deliverable, optParams);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    function _submitExpectRevert(bytes32 deliverable, bytes memory optParams, bytes4 expectedSelector) internal {
        bytes memory data = abi.encode(PROVIDER, deliverable, optParams);
        vm.expectRevert(expectedSelector);
        core.callBefore(IERC8183Hook(address(hook)), JOB_ID, SEL_SUBMIT, data);
    }

    // ----- hex helper ----------------------------------------------------------

    function _toHexString(bytes32 v) internal pure returns (string memory) {
        bytes memory out = new bytes(66);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < 32; ++i) {
            uint8 b = uint8(v[i]);
            out[2 + 2 * i]     = _hexChar(b >> 4);
            out[2 + 2 * i + 1] = _hexChar(b & 0x0f);
        }
        return string(out);
    }

    function _hexChar(uint8 nibble) internal pure returns (bytes1) {
        return bytes1(nibble < 10 ? nibble + 0x30 : nibble + 0x57);
    }
}

// =============================================================================
//                              CONSTRUCTOR TESTS
// =============================================================================

contract ConstructorTest is HookTestBase {
    function test_StoresVerifier() public view {
        assertEq(hook.zkTlsVerifier(), address(verifier));
    }

    function test_StoresOwner() public view {
        assertEq(hook.owner(), OWNER);
    }

    function test_RevertsOnZeroVerifier() public {
        vm.expectRevert(ZkTlsAttestationHook.InvalidZkTlsVerifier.selector);
        new ZkTlsAttestationHook(address(core), address(0), OWNER);
    }

    function test_RevertsOnZeroCore() public {
        vm.expectRevert();   // BaseERC8183Hook.InvalidERC8183Contract
        new ZkTlsAttestationHook(address(0), address(verifier), OWNER);
    }

    function test_RevertsOnEoaVerifier() public {
        // An EOA's staticcall returns success with empty returndata — would
        // silently pass the verifier check. The constructor must reject this.
        vm.expectRevert(ZkTlsAttestationHook.NotAContract.selector);
        new ZkTlsAttestationHook(address(core), address(0x1234), OWNER);
    }
}

// =============================================================================
//                       OWNER: VERIFIER ROTATION TESTS
// =============================================================================

contract VerifierRotationTest is HookTestBase {
    NewVerifier internal newVerifier;

    function setUp() public override {
        super.setUp();
        newVerifier = new NewVerifier();
    }

    function test_ProposeRequiresOwner() public {
        vm.expectRevert();   // Ownable.OwnableUnauthorizedAccount
        hook.proposeZkTlsVerifier(address(newVerifier));
    }

    function test_ProposeRejectsEoa() public {
        vm.prank(OWNER);
        vm.expectRevert(ZkTlsAttestationHook.NotAContract.selector);
        hook.proposeZkTlsVerifier(address(0xdeadbeef));
    }

    function test_ProposeRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ZkTlsAttestationHook.InvalidZkTlsVerifier.selector);
        hook.proposeZkTlsVerifier(address(0));
    }

    function test_Propose_SetsPending() public {
        vm.prank(OWNER);
        hook.proposeZkTlsVerifier(address(newVerifier));
        assertEq(hook.pendingZkTlsVerifier(), address(newVerifier));
        assertEq(hook.pendingVerifierActivationTime(), block.timestamp + 7 days);
    }

    function test_Activate_BeforeDelay_Reverts() public {
        vm.startPrank(OWNER);
        hook.proposeZkTlsVerifier(address(newVerifier));
        vm.expectRevert(ZkTlsAttestationHook.RotationDelayNotElapsed.selector);
        hook.activateZkTlsVerifier();
        vm.stopPrank();
    }

    function test_Activate_WithoutProposal_Reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(ZkTlsAttestationHook.NoPendingVerifier.selector);
        hook.activateZkTlsVerifier();
    }

    function test_Activate_AfterDelay_Works() public {
        vm.prank(OWNER);
        hook.proposeZkTlsVerifier(address(newVerifier));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(OWNER);
        hook.activateZkTlsVerifier();
        assertEq(hook.zkTlsVerifier(), address(newVerifier));
        assertEq(hook.pendingZkTlsVerifier(), address(0));
    }

    /// @notice An in-flight job (funded under the old verifier) must continue
    ///         to use the old verifier even after rotation — that's the snapshot.
    function test_Rotation_DoesNotAffectInFlightJob() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fund(abi.encode(spec));

        // Verifier is recorded as snapshot.
        assertEq(hook.getVerifierSnapshot(JOB_ID), address(verifier));

        // Rotate to a new verifier.
        vm.prank(OWNER);
        hook.proposeZkTlsVerifier(address(newVerifier));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(OWNER);
        hook.activateZkTlsVerifier();
        assertEq(hook.zkTlsVerifier(), address(newVerifier));

        // Refresh att.timestamp post-warp so the staleness check still passes
        // — we're testing verifier-source-of-truth, not freshness.
        att.timestamp = uint64(block.timestamp * 1000);

        // The in-flight submit still goes through the OLD verifier (snapshot).
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }
}

// =============================================================================
//                  OWNER: TRUSTED EXTENSION VERIFIER ALLOWLIST
// =============================================================================

contract TrustedExtensionAllowlistTest is HookTestBase {
    MockExtensionVerifier internal ext;
    function setUp() public override {
        super.setUp();
        ext = new MockExtensionVerifier();
    }

    function test_SetRequiresOwner() public {
        vm.expectRevert();
        hook.setTrustedExtensionVerifier(address(ext), true);
    }

    function test_SetRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ZkTlsAttestationHook.InvalidAddress.selector);
        hook.setTrustedExtensionVerifier(address(0), true);
    }

    function test_SetRejectsEoaWhenTrustingNew() public {
        vm.prank(OWNER);
        vm.expectRevert(ZkTlsAttestationHook.NotAContract.selector);
        hook.setTrustedExtensionVerifier(address(0xdeadbeef), true);
    }

    function test_Set_Works() public {
        vm.prank(OWNER);
        hook.setTrustedExtensionVerifier(address(ext), true);
        assertTrue(hook.trustedExtensionVerifiers(address(ext)));
    }

    function test_FundWithCustomVerifier_NotOnAllowlist_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        spec.customVerifier = address(ext); // not on allowlist

        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.ExtensionVerifierNotTrusted.selector);
    }

    function test_FundWithCustomVerifier_OnAllowlist_Works() public {
        vm.prank(OWNER);
        hook.setTrustedExtensionVerifier(address(ext), true);

        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        spec.customVerifier = address(ext);
        _fund(abi.encode(spec));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }
}

// =============================================================================
//                       _postFund VALIDATION TESTS
// =============================================================================

contract PostFundValidationTest is HookTestBase {
    function test_EmptyOptParams_Reverts() public {
        _fundExpectRevert(bytes(""), ZkTlsAttestationHook.SpecRequired.selector);
    }

    function test_EmptySteps_Reverts() public {
        AttestationSpec memory spec = AttestationSpec({
            steps: new RequestStep[](0),
            bindings: new DataBinding[](0),
            deliverableSourceStep: 0,
            customVerifier: address(0),
            zkTlsVerifierSnapshot: address(0),
            configured: false
        });
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.EmptySteps.selector);
    }

    function test_UnsatisfiableStep_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep memory step = _stepFor(JOB_ID, att, 300);
        // Zero out the three required-pinned hashes.
        step.methodHash = bytes32(0);
        step.urlHash    = bytes32(0);
        step.bodyHash   = bytes32(0);
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.UnsatisfiableStep.selector);
    }

    function test_MaxAgeZero_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep memory step = _stepFor(JOB_ID, att, 0);
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.InvalidMaxAge.selector);
    }

    function test_MaxAgeBeyond24h_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep memory step = _stepFor(JOB_ID, att, uint64(24 hours + 1));
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.InvalidMaxAge.selector);
    }

    function test_BadJobBinding_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep memory step = _stepFor(JOB_ID, att, 300);
        step.expectedJobBinding = bytes32(uint256(1234));   // wrong
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.InvalidJobBinding.selector);
    }

    function test_TooManyAttestors_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep memory step = _stepFor(JOB_ID, att, 300);
        step.allowedAttestors = new address[](9); // > MAX_ATTESTORS_PER_STEP (8)
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.TooManyAttestors.selector);
    }

    function test_MinAttestorsGreaterThanAllowed_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep memory step = _stepFor(JOB_ID, att, 300);
        step.allowedAttestors = new address[](2);
        step.minAttestorsRequired = 3;
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.AttestorQuorumNotMet.selector);
    }

    function test_BindingBothValueAndExtractKey_Reverts() public {
        Attestation memory att0 = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        Attestation memory att1 = _makeAtt(JOB_ID, "https://y", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(JOB_ID, att0, 300);
        steps[1] = _stepFor(JOB_ID, att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({
            fromStep: 0, toStep: 1, toLocation: 0,
            value: bytes("v"),
            fromExtractKey: bytes("k")     // both set — invalid
        });
        AttestationSpec memory spec = _bareSpec(steps, bindings);
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.InvalidBinding.selector);
    }

    function test_BindingNeitherValueNorExtractKey_Reverts() public {
        Attestation memory att0 = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        Attestation memory att1 = _makeAtt(JOB_ID, "https://y", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(JOB_ID, att0, 300);
        steps[1] = _stepFor(JOB_ID, att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({
            fromStep: 0, toStep: 1, toLocation: 0,
            value: bytes(""),
            fromExtractKey: bytes("")     // both empty — invalid
        });
        AttestationSpec memory spec = _bareSpec(steps, bindings);
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.InvalidBinding.selector);
    }

    function test_SpecAlreadyConfigured_Reverts() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        _fund(abi.encode(spec));
        // Re-fund attempt
        _fundExpectRevert(abi.encode(spec), ZkTlsAttestationHook.SpecAlreadyConfigured.selector);
    }
}

// =============================================================================
//                       _preSubmit HAPPY-PATH TESTS
// =============================================================================

contract PreSubmitHappyPathTest is HookTestBase {
    function test_SingleStep() public {
        Attestation memory att = _makeAtt(
            JOB_ID, "https://api.example.com/x", "GET", "", "67234.51", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }

    function test_MultiStep_StaticBinding() public {
        Attestation memory att0 = _makeAtt(
            JOB_ID, "https://api.example.com/coins/bitcoin", "GET", "",
            "{\"id\":\"bitcoin\"}", _emptyResolves()
        );
        Attestation memory att1 = _makeAtt(
            JOB_ID, "https://api.example.com/coins/bitcoin/history", "GET", "",
            "{\"x\":1}", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(JOB_ID, att0, 300);
        steps[1] = _stepFor(JOB_ID, att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({
            fromStep: 0, toStep: 1, toLocation: 0,
            value: bytes("bitcoin"),
            fromExtractKey: bytes("")
        });
        _fund(abi.encode(_bareSpec(steps, bindings)));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = att0;
        atts[1] = att1;
        _submit(keccak256(bytes(att1.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }

    function test_MultiStep_DynamicBinding_ExtractKey() public {
        // Step 0's data contains `"id":"bitcoin"`; the binding extracts the value
        // of "id" dynamically and asserts it appears in step 1's URL.
        Attestation memory att0 = _makeAtt(
            JOB_ID, "https://api.example.com/coins/bitcoin", "GET", "",
            "{\"id\":\"bitcoin\"}", _emptyResolves()
        );
        Attestation memory att1 = _makeAtt(
            JOB_ID, "https://api.example.com/coins/bitcoin/history", "GET", "",
            "{\"x\":1}", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(JOB_ID, att0, 300);
        steps[1] = _stepFor(JOB_ID, att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({
            fromStep: 0, toStep: 1, toLocation: 0,
            value: bytes(""),
            fromExtractKey: bytes("id")
        });
        _fund(abi.encode(_bareSpec(steps, bindings)));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = att0;
        atts[1] = att1;
        _submit(keccak256(bytes(att1.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }

    function test_TimeUnitSeconds() public {
        // Build an attestation whose timestamp is in SECONDS (not ms) and pin
        // timeUnit accordingly.
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        att.timestamp = uint64(block.timestamp);
        RequestStep memory step = _stepFor(JOB_ID, att, 300);
        step.timeUnit = TimeUnit.Seconds;
        step.additionParamsHash = keccak256(bytes(att.additionParams));

        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }

    function test_AttestorQuorum_Met() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        att.attestors = new Attestor[](2);
        att.attestors[0] = Attestor({attestorAddr: address(0xAAA), url: ""});
        att.attestors[1] = Attestor({attestorAddr: address(0xBBB), url: ""});

        RequestStep memory step = _stepFor(JOB_ID, att, 300);
        step.allowedAttestors = new address[](3);
        step.allowedAttestors[0] = address(0xAAA);
        step.allowedAttestors[1] = address(0xBBB);
        step.allowedAttestors[2] = address(0xCCC);
        step.minAttestorsRequired = 2;
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submit(keccak256(bytes(att.data)), abi.encode(atts, bytes("")));
        assertTrue(hook.isValidated(JOB_ID));
    }
}

// =============================================================================
//                        _preSubmit FAILURE-PATH TESTS
// =============================================================================

contract PreSubmitFailureTest is HookTestBase {
    function _setupBasicSpec() internal returns (Attestation memory) {
        Attestation memory att = _makeAtt(JOB_ID, "https://api.example.com/x", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));
        return att;
    }

    function test_SpecNotConfigured() public {
        Attestation[] memory atts = new Attestation[](0);
        _submitExpectRevert(
            bytes32(0),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.SpecNotConfigured.selector
        );
    }

    function test_StepCountMismatch() public {
        _setupBasicSpec();
        Attestation[] memory atts = new Attestation[](0);
        _submitExpectRevert(
            bytes32(0),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.StepCountMismatch.selector
        );
    }

    function test_VerifierFailed() public {
        Attestation memory att = _setupBasicSpec();
        verifier.setRevert(true);

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.AttestationVerifierFailed.selector
        );
    }

    function test_JobBindingMissing() public {
        Attestation memory att = _setupBasicSpec();
        // Strip the binding hex from additionParams while keeping the same
        // additionParamsHash. The additionParams hash check will catch it
        // first; to actually exercise JobBindingMissing, the spec's
        // additionParamsHash must be zero (not pinned) and the att.additionParams
        // must lack the binding.
        att.additionParams = "{\"algorithmType\":\"proxytls\"}"; // no jobBinding

        // Build new spec with additionParamsHash = 0 so we reach JobBindingMissing.
        // But getRequest from existing _setupBasicSpec already pinned the hash.
        // For a clean test, set up a fresh spec where additionParamsHash is intentionally 0.
        // (re-fund won't work since spec is already configured; use a fresh job id by
        // overriding setUp inline.)
        // Workaround: use jobId 2.
        uint256 OTHER_JOB = 2;
        core.setJob(OTHER_JOB, address(hook));

        Attestation memory att2 = _makeAtt(OTHER_JOB, "https://api.example.com/x", "GET", "", "v", _emptyResolves());
        att2.additionParams = "{\"algorithmType\":\"proxytls\"}";   // no binding
        RequestStep memory step = _stepFor(OTHER_JOB, att2, 300);
        step.additionParamsHash = bytes32(0);   // not pinned
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));

        bytes memory fundData = abi.encode(CLIENT, abi.encode(spec));
        core.callAfter(IERC8183Hook(address(hook)), OTHER_JOB, SEL_FUND, fundData);

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att2;
        bytes memory submitData = abi.encode(PROVIDER, keccak256(bytes(att2.data)), abi.encode(atts, bytes("")));
        vm.expectRevert(ZkTlsAttestationHook.JobBindingMissing.selector);
        core.callBefore(IERC8183Hook(address(hook)), OTHER_JOB, SEL_SUBMIT, submitData);
    }

    function test_MethodHashMismatch() public {
        Attestation memory att = _setupBasicSpec();
        att.request.method = "POST";
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.MethodHashMismatch.selector
        );
    }

    function test_UrlHashMismatch() public {
        Attestation memory att = _setupBasicSpec();
        att.request.url = "https://malicious.example/x";
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.UrlHashMismatch.selector
        );
    }

    function test_BodyHashMismatch() public {
        Attestation memory att = _makeAtt(
            JOB_ID, "https://api.example.com/x", "POST", "{\"a\":1}", "v", _emptyResolves()
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        att.request.body = "{\"a\":2}";
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.BodyHashMismatch.selector
        );
    }

    function test_AttestationStale_Past() public {
        Attestation memory att = _setupBasicSpec();
        // Warp far enough that att.timestamp/1000 is older than maxAge=300s.
        vm.warp(block.timestamp + 1 hours);
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.AttestationStale.selector
        );
    }

    function test_AttestationStale_FutureBeyondSkew() public {
        Attestation memory att = _setupBasicSpec();
        // Set timestamp far enough in the future to exceed FORWARD_SKEW_TOLERANCE (30s).
        att.timestamp = uint64((block.timestamp + 1 hours) * 1000);
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.AttestationStale.selector
        );
    }

    function test_AttestorQuorumNotMet() public {
        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        att.attestors = new Attestor[](1);
        att.attestors[0] = Attestor({attestorAddr: address(0xDDD), url: ""});  // not in allowlist

        RequestStep memory step = _stepFor(JOB_ID, att, 300);
        step.allowedAttestors = new address[](2);
        step.allowedAttestors[0] = address(0xAAA);
        step.allowedAttestors[1] = address(0xBBB);
        step.minAttestorsRequired = 1;
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = step;
        _fund(abi.encode(_bareSpec(steps, new DataBinding[](0))));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.AttestorQuorumNotMet.selector
        );
    }

    function test_DataBindingViolated() public {
        Attestation memory att0 = _makeAtt(JOB_ID, "https://x/a", "GET", "", "{\"id\":\"ethereum\"}", _emptyResolves());
        Attestation memory att1 = _makeAtt(JOB_ID, "https://x/b", "GET", "", "{}", _emptyResolves());

        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(JOB_ID, att0, 300);
        steps[1] = _stepFor(JOB_ID, att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({
            fromStep: 0, toStep: 1, toLocation: 0,
            value: bytes("bitcoin"),    // not in att0.data ("ethereum")
            fromExtractKey: bytes("")
        });
        _fund(abi.encode(_bareSpec(steps, bindings)));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = att0; atts[1] = att1;
        _submitExpectRevert(
            keccak256(bytes(att1.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.DataBindingViolated.selector
        );
    }

    function test_DeliverableMismatch() public {
        Attestation memory att = _setupBasicSpec();
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256("totally different"),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.DeliverableMismatch.selector
        );
    }

    function test_ContainsBounded_NoFalsePositiveOnAdjacentKeys() public {
        // The source data is `"price":"1000"`. The binding searches for the
        // static value `"price":"100"` (which would mistakenly match an
        // unbounded substring search). _containsBounded should reject it
        // because the closing position is followed by `0`, which isn't a
        // boundary character.
        //
        // We make this work by constructing two attestations where the dst
        // location contains exactly `"price":"100"` (legitimately bracketed)
        // but the src data only contains `"price":"1000"` — boundary check
        // on the src side should fail.
        Attestation memory att0 = _makeAtt(JOB_ID, "https://x?ref=1000a", "GET", "", "{\"price\":\"1000\"}", _emptyResolves());
        Attestation memory att1 = _makeAtt(JOB_ID, "https://x?price=100&", "GET", "", "{}", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](2);
        steps[0] = _stepFor(JOB_ID, att0, 300);
        steps[1] = _stepFor(JOB_ID, att1, 300);
        DataBinding[] memory bindings = new DataBinding[](1);
        bindings[0] = DataBinding({
            fromStep: 0, toStep: 1, toLocation: 0,
            value: bytes("100"),     // appears in att1.url between "=" and "&"
            fromExtractKey: bytes("")
        });
        _fund(abi.encode(_bareSpec(steps, bindings)));

        Attestation[] memory atts = new Attestation[](2);
        atts[0] = att0; atts[1] = att1;
        // "100" inside att0.data = `{"price":"1000"}` is followed by '0', not a
        // boundary char → _containsBounded returns false on the src side.
        _submitExpectRevert(
            keccak256(bytes(att1.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.DataBindingViolated.selector
        );
    }

    function test_ExtensionVerifierFailed() public {
        MockExtensionVerifier ext = new MockExtensionVerifier();
        vm.prank(OWNER);
        hook.setTrustedExtensionVerifier(address(ext), true);
        ext.setShouldRevert(true);

        Attestation memory att = _makeAtt(JOB_ID, "https://x", "GET", "", "v", _emptyResolves());
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(JOB_ID, att, 300);
        AttestationSpec memory spec = _bareSpec(steps, new DataBinding[](0));
        spec.customVerifier = address(ext);
        _fund(abi.encode(spec));

        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        _submitExpectRevert(
            keccak256(bytes(att.data)),
            abi.encode(atts, bytes("")),
            ZkTlsAttestationHook.ExtensionVerifierFailed.selector
        );
    }
}

// =============================================================================
//                          ACCESS & METADATA
// =============================================================================

contract MetadataTest is HookTestBase {
    function test_OnlyCoreCanCallHook() public {
        Attestation[] memory atts = new Attestation[](0);
        bytes memory data = abi.encode(PROVIDER, bytes32(uint256(1)), abi.encode(atts, bytes("")));
        vm.prank(address(0xDEAD));
        vm.expectRevert();   // BaseERC8183Hook.OnlyERC8183Contract
        IERC8183Hook(address(hook)).beforeAction(JOB_ID, SEL_SUBMIT, data);
    }

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

    function test_JobBindingFor() public view {
        bytes32 b = hook.jobBindingFor(JOB_ID);
        assertEq(b, keccak256(abi.encode(JOB_ID, address(hook), block.chainid)));
    }
}
