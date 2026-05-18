// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8183} from "@erc8183/ERC8183.sol";
import {MockUSDC} from "@erc8183/mocks/MockUSDC.sol";
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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Always-accept mock zkTLS verifier (no signature check). Lets us
///      exercise the *hook + core* integration without depending on a real
///      verifier deployment. Real-verifier coverage belongs in the e2e
///      fork-test suite.
contract AcceptingVerifier {
    function verifyAttestation(Attestation calldata) external pure {}
}

/// @notice End-to-end integration: real ERC8183 (behind UUPS proxy) + real
///         ZkTlsAttestationHook + mock USDC + mock verifier. Exercises the
///         complete Open → Funded → Submitted → Completed flow and asserts
///         the escrowed budget reaches the provider.
contract FullLifecycleTest is Test {
    address constant TREASURY  = address(0xfee);
    address constant ADMIN     = address(0xad);
    address constant CLIENT    = address(0xc1);
    address constant PROVIDER  = address(0xb0b);
    address constant EVALUATOR = address(0xe0e);

    uint256 constant BUDGET = 100_000_000; // 100 USDC (6 decimals)

    ERC8183 internal core;
    MockUSDC internal usdc;
    ZkTlsAttestationHook internal hook;
    AcceptingVerifier internal verifier;

    function setUp() public {
        // 1) Deploy ERC8183 behind a UUPS proxy and initialize it.
        ERC8183 impl = new ERC8183();
        bytes memory initData = abi.encodeCall(ERC8183.initialize, (TREASURY, ADMIN));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        core = ERC8183(address(proxy));

        // 2) Deploy verifier + hook (constructor takes core + verifier + owner).
        verifier = new AcceptingVerifier();
        hook = new ZkTlsAttestationHook(address(core), address(verifier), ADMIN);

        // 3) Deploy USDC mock and admin-whitelist token + hook.
        usdc = new MockUSDC();
        vm.startPrank(ADMIN);
        core.setHookWhitelist(address(hook), true);
        core.setPaymentTokenAllowed(address(usdc), true);
        vm.stopPrank();

        // 4) Fund client and approve escrow up front.
        usdc.mint(CLIENT, BUDGET);
        vm.prank(CLIENT);
        usdc.approve(address(core), BUDGET);

        // 5) Move clock forward so attestation timestamps don't underflow
        //    when tests stamp att.timestamp at block.timestamp.
        vm.warp(block.timestamp + 1 hours);
    }

    // ------------------------------------------------------------- helpers

    function _emptyResolves() internal pure returns (AttNetworkResponseResolve[] memory) {
        return new AttNetworkResponseResolve[](0);
    }

    function _makeAtt(uint256 jobId, string memory url, string memory data) internal view returns (Attestation memory) {
        string memory additionParams = string.concat(
            '{"algorithmType":"proxytls","jobBinding":"',
            _toHexString(hook.jobBindingFor(jobId)),
            '"}'
        );
        return Attestation({
            recipient: PROVIDER,
            request: AttNetworkRequest({url: url, header: "", method: "GET", body: ""}),
            reponseResolve: _emptyResolves(),
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

    function _toHexString(bytes32 v) internal pure returns (string memory) {
        bytes memory out = new bytes(66);
        out[0] = "0"; out[1] = "x";
        for (uint256 i = 0; i < 32; ++i) {
            uint8 b = uint8(v[i]);
            out[2 + 2*i]     = _hexChar(b >> 4);
            out[2 + 2*i + 1] = _hexChar(b & 0x0f);
        }
        return string(out);
    }
    function _hexChar(uint8 n) internal pure returns (bytes1) {
        return bytes1(n < 10 ? n + 0x30 : n + 0x57);
    }

    // --------------------------------------------------------- happy path

    function test_FullLifecycle_PaysProvider() public {
        // a) Client creates the job with our hook attached.
        uint48 expiredAt = uint48(block.timestamp + 1 days);
        vm.prank(CLIENT);
        uint256 jobId = core.createJob(PROVIDER, EVALUATOR, expiredAt, "test job", address(hook), 0);

        // b) Provider sets the budget (no hook optParams needed here — our hook
        //    is silent on setBudget).
        vm.prank(PROVIDER);
        core.setBudget(jobId, address(usdc), BUDGET, "");

        // c) Build the attestation spec (single step).
        Attestation memory att = _makeAtt(
            jobId,
            "https://api.example.com/coins/bitcoin",
            "{\"price_usd\":67234.51}"
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(jobId, att);

        AttestationSpec memory spec = AttestationSpec({
            steps: steps,
            bindings: new DataBinding[](0),
            deliverableSourceStep: 0,
            customVerifier: address(0),
            zkTlsVerifierSnapshot: address(0),
            configured: false
        });

        // d) Client funds. Spec lives in optParams; afterAction stores it.
        uint256 escrowBalBefore = usdc.balanceOf(address(core));
        vm.prank(CLIENT);
        core.fund(jobId, BUDGET, abi.encode(spec));
        assertEq(usdc.balanceOf(address(core)) - escrowBalBefore, BUDGET, "escrow funded");

        // e) Provider submits with the attestation in optParams.
        bytes32 deliverable = keccak256(bytes(att.data));
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory submitOpt = abi.encode(atts, bytes(""));

        vm.prank(PROVIDER);
        core.submit(jobId, deliverable, submitOpt);

        assertTrue(hook.isValidated(jobId), "hook validated");

        // f) Evaluator completes — money releases to provider.
        uint256 providerBalBefore = usdc.balanceOf(PROVIDER);
        vm.prank(EVALUATOR);
        core.complete(jobId, bytes32(0), "");

        // With zero platform/evaluator fees configured (defaults), provider gets the full budget.
        assertEq(usdc.balanceOf(PROVIDER) - providerBalBefore, BUDGET, "provider paid");
        assertEq(usdc.balanceOf(address(core)), 0, "escrow drained");
    }

    // ------------------------------------------- failure: bad attestation

    /// @notice A tampered attestation must abort `submit`, leaving the job in
    ///         Funded and the escrow untouched. The client can then `reject`.
    function test_BadAttestation_BlocksSubmit_AndAllowsRefund() public {
        uint48 expiredAt = uint48(block.timestamp + 1 days);
        vm.prank(CLIENT);
        uint256 jobId = core.createJob(PROVIDER, EVALUATOR, expiredAt, "test job", address(hook), 0);

        vm.prank(PROVIDER);
        core.setBudget(jobId, address(usdc), BUDGET, "");

        Attestation memory att = _makeAtt(
            jobId,
            "https://api.example.com/coins/bitcoin",
            "{\"price_usd\":67234.51}"
        );
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(jobId, att);
        AttestationSpec memory spec = AttestationSpec({
            steps: steps,
            bindings: new DataBinding[](0),
            deliverableSourceStep: 0,
            customVerifier: address(0),
            zkTlsVerifierSnapshot: address(0),
            configured: false
        });

        vm.prank(CLIENT);
        core.fund(jobId, BUDGET, abi.encode(spec));

        // Tamper: change the URL on the attestation away from what the spec pinned.
        att.request.url = "https://malicious.example/x";
        bytes32 deliverable = keccak256(bytes(att.data));
        Attestation[] memory atts = new Attestation[](1);
        atts[0] = att;
        bytes memory submitOpt = abi.encode(atts, bytes(""));

        vm.prank(PROVIDER);
        vm.expectRevert(ZkTlsAttestationHook.UrlHashMismatch.selector);
        core.submit(jobId, deliverable, submitOpt);

        // Escrow still holds the budget — provider got nothing.
        assertEq(usdc.balanceOf(address(core)), BUDGET, "escrow intact after blocked submit");
        assertEq(usdc.balanceOf(PROVIDER), 0, "provider unpaid");

        // Evaluator rejects → funds refunded to client (no hook lock-up).
        uint256 clientBalBefore = usdc.balanceOf(CLIENT);
        vm.prank(EVALUATOR);
        core.reject(jobId, bytes32(uint256(uint160(0xDEAD))), "");
        assertEq(usdc.balanceOf(CLIENT) - clientBalBefore, BUDGET, "client refunded");
        assertEq(usdc.balanceOf(address(core)), 0, "escrow drained on reject");
    }

    // -------------------------- claimRefund must work even with hook attached

    /// @notice Verifies hook does NOT block expiry refunds — `claimRefund` is
    ///         not hookable, so a misbehaving hook (or a Funded job whose
    ///         provider never submitted) cannot trap funds past expiry.
    function test_Expiry_ClaimRefundUnaffectedByHook() public {
        uint48 expiredAt = uint48(block.timestamp + 1 days);
        vm.prank(CLIENT);
        uint256 jobId = core.createJob(PROVIDER, EVALUATOR, expiredAt, "test job", address(hook), 0);

        vm.prank(PROVIDER);
        core.setBudget(jobId, address(usdc), BUDGET, "");

        Attestation memory att = _makeAtt(jobId, "https://x", "v");
        RequestStep[] memory steps = new RequestStep[](1);
        steps[0] = _stepFor(jobId, att);
        AttestationSpec memory spec = AttestationSpec({
            steps: steps,
            bindings: new DataBinding[](0),
            deliverableSourceStep: 0,
            customVerifier: address(0),
            zkTlsVerifierSnapshot: address(0),
            configured: false
        });

        vm.prank(CLIENT);
        core.fund(jobId, BUDGET, abi.encode(spec));
        // Provider never submits. Move past expiry.
        vm.warp(uint256(expiredAt) + 1);

        uint256 clientBalBefore = usdc.balanceOf(CLIENT);
        core.claimRefund(jobId);
        assertEq(usdc.balanceOf(CLIENT) - clientBalBefore, BUDGET, "client refunded on expiry");
    }
}
