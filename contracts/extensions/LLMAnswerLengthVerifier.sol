// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Attestation,
    IAttestationExtensionVerifier
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";

/**
 * @title LLMAnswerLengthVerifier
 * @notice Extension verifier that bounds the byte length of an LLM-style
 *         answer field inside a target step's attestation data.
 *
 * USE CASE
 * --------
 * The zkTLS hook proves cryptographically that the provider really called
 * the LLM endpoint and got back the response that's now bound to the
 * deliverable. What it cannot tell you is whether the response is sensibly
 * shaped: a one-character "ok" or a thousand-page novel both technically
 * count as completing the job. This verifier adds a single business
 * invariant — the answer's byte length must fall inside [minBytes, maxBytes]
 * — that the hook delegates to during submit.
 *
 * INTEGRATION
 * -----------
 *  1. Deploy with (sourceStep, keyName, minBytes, maxBytes).
 *  2. Wire its address into the Job's `AttestationSpec.customVerifier`.
 *  3. The hook will staticcall `verify(...)` after every generic check
 *     passes; this verifier reverts if the answer's byte length is out of
 *     range, which the hook turns into `ExtensionVerifierFailed` and which
 *     in turn fails the provider's `submit()` transaction.
 *
 * TRUST MODEL
 * -----------
 *  - View-only by design; called via staticcall so it cannot mutate state.
 *  - Parses raw JSON bytes — no full JSON tokenizer, just a substring scan
 *    for `"keyName":"` followed by quote-terminated string reading that
 *    respects backslash escapes. Sufficient for well-formed LLM JSON;
 *    pathological inputs (unterminated strings, nested escapes) revert
 *    rather than silently misparse.
 *  - Byte length, not character length: a multi-byte UTF-8 codepoint counts
 *    as its byte size. For the LLM-quality use case this is the right
 *    proxy; clients that need codepoint counting can write their own.
 */
contract LLMAnswerLengthVerifier is IAttestationExtensionVerifier {
    /// @notice Which step's attestation carries the LLM answer.
    uint8 public immutable sourceStep;
    /// @notice JSON key whose string value is checked.
    string public keyName;
    /// @notice Inclusive lower bound on the answer's byte length.
    uint256 public immutable minBytes;
    /// @notice Inclusive upper bound on the answer's byte length.
    uint256 public immutable maxBytes;

    error InvalidConfig();
    error WrongAttestationCount();
    error KeyNotFound();
    error UnterminatedString();
    error MalformedEscape();
    error AnswerTooShort();
    error AnswerTooLong();

    constructor(uint8 sourceStep_, string memory keyName_, uint256 minBytes_, uint256 maxBytes_) {
        if (bytes(keyName_).length == 0) revert InvalidConfig();
        if (minBytes_ > maxBytes_) revert InvalidConfig();
        sourceStep = sourceStep_;
        keyName = keyName_;
        minBytes = minBytes_;
        maxBytes = maxBytes_;
    }

    /// @inheritdoc IAttestationExtensionVerifier
    function verify(
        uint256 /*jobId*/,
        bytes32 /*deliverable*/,
        Attestation[] calldata attestations,
        bytes calldata /*customCalldata*/
    ) external view override {
        if (attestations.length <= sourceStep) revert WrongAttestationCount();
        uint256 len = _stringFieldLength(attestations[sourceStep].data, keyName);
        if (len < minBytes) revert AnswerTooShort();
        if (len > maxBytes) revert AnswerTooLong();
    }

    /// @dev Return the byte length of the string value of `"key":"<value>"`
    ///      inside `dataStr`. Walks the JSON respecting backslash escapes;
    ///      reverts on unterminated strings or trailing backslashes.
    function _stringFieldLength(string memory dataStr, string memory key) internal pure returns (uint256) {
        bytes memory data = bytes(dataStr);
        bytes memory needle = abi.encodePacked('"', key, '":"');

        uint256 nLen = needle.length;
        uint256 hLen = data.length;
        if (nLen > hLen) revert KeyNotFound();

        // Locate the FIRST occurrence of `"<key>":"`.
        uint256 start = type(uint256).max;
        uint256 last = hLen - nLen;
        for (uint256 k = 0; k <= last; ++k) {
            bool match_ = true;
            for (uint256 j = 0; j < nLen; ++j) {
                if (data[k + j] != needle[j]) { match_ = false; break; }
            }
            if (match_) { start = k + nLen; break; }
        }
        if (start == type(uint256).max) revert KeyNotFound();

        // Walk until the matching closing quote.
        uint256 p = start;
        while (p < hLen) {
            bytes1 c = data[p];
            if (c == 0x22 /* " */) {
                return p - start;
            }
            if (c == 0x5C /* \ */) {
                // Treat the backslash + next byte as a single escape token,
                // counted as 2 raw bytes by the byte-length convention above.
                if (p + 1 >= hLen) revert MalformedEscape();
                p += 2;
                continue;
            }
            p += 1;
        }
        revert UnterminatedString();
    }
}
