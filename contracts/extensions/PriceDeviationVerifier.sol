// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Attestation,
    IAttestationExtensionVerifier
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";

/**
 * @title PriceDeviationVerifier
 * @notice Reference `IAttestationExtensionVerifier` implementation. Wires into
 *         `ZkTlsAttestationHook` via the `customVerifier` field of the job's
 *         AttestationSpec.
 *
 * USE CASE
 * --------
 * A job pulls a price from two independent sources (two separate steps, two
 * separate zkTLS attestations). The hook's generic layer already guarantees
 * both calls happened, hit the expected URLs/methods, and returned what the
 * spec pinned. This extension verifier adds the business rule: the two
 * prices must agree within a configured tolerance, or the submission is
 * rejected.
 *
 * INTEGRATION
 * -----------
 *  1. Deploy this contract with the desired (sourceStepA, sourceStepB,
 *     keyName, maxDeviationBp).
 *  2. In the Job's AttestationSpec, set `customVerifier` to this contract's
 *     address.
 *  3. The provider submits attestations as normal; the hook routes through
 *     `verify(...)` via staticcall after every generic check passes.
 *
 * TRUST MODEL
 * -----------
 *  - The verifier is `view`-only and called via staticcall — it cannot
 *    mutate state, transfer tokens, or interfere with escrow.
 *  - Numeric parsing is intentionally narrow (ASCII digits + optional `.`)
 *    to avoid mis-parsing exotic JSON encodings; the spec author MUST pin
 *    the upstream response shape so `data` arrives in the expected form.
 *  - If parsing fails the verifier reverts — the job stays in Submitted and
 *    the client can reject for refund.
 */
contract PriceDeviationVerifier is IAttestationExtensionVerifier {
    /// @notice Index of the first price attestation in the job's steps[].
    uint8 public immutable sourceStepA;
    /// @notice Index of the second price attestation in the job's steps[].
    uint8 public immutable sourceStepB;
    /// @notice JSON key whose value carries the price string in each step's
    ///         `data` (e.g. "price_usd"). Both steps must expose this key.
    string public keyName;
    /// @notice Maximum allowed deviation in basis points (10_000 = 100%).
    ///         e.g. 500 = 5%.
    uint256 public immutable maxDeviationBp;

    error PriceNotFound();
    error PriceParseError();
    error DeviationTooHigh();
    error WrongAttestationCount();
    error InvalidConfig();

    constructor(uint8 sourceStepA_, uint8 sourceStepB_, string memory keyName_, uint256 maxDeviationBp_) {
        if (sourceStepA_ == sourceStepB_) revert InvalidConfig();
        if (bytes(keyName_).length == 0) revert InvalidConfig();
        if (maxDeviationBp_ == 0 || maxDeviationBp_ > 10_000) revert InvalidConfig();
        sourceStepA = sourceStepA_;
        sourceStepB = sourceStepB_;
        keyName = keyName_;
        maxDeviationBp = maxDeviationBp_;
    }

    /// @inheritdoc IAttestationExtensionVerifier
    function verify(
        uint256 /*jobId*/,
        bytes32 /*deliverable*/,
        Attestation[] calldata attestations,
        bytes calldata /*customCalldata*/
    ) external view override {
        // Bounds-check before indexing; the hook's stepCount mismatch check
        // protects the happy path, but a defective spec could still leave us
        // pointing at a non-existent step here.
        if (attestations.length <= sourceStepA || attestations.length <= sourceStepB) {
            revert WrongAttestationCount();
        }

        uint256 priceA = _extractAndParse(attestations[sourceStepA].data, keyName);
        uint256 priceB = _extractAndParse(attestations[sourceStepB].data, keyName);

        uint256 hi = priceA >= priceB ? priceA : priceB;
        uint256 lo = priceA >= priceB ? priceB : priceA;
        // diff/lo * 10_000 <= maxDeviationBp  →  (hi - lo) * 10_000 <= lo * maxDeviationBp
        if ((hi - lo) * 10_000 > lo * maxDeviationBp) revert DeviationTooHigh();
    }

    // --- internal: minimal JSON value extraction & numeric parsing --------

    /// @dev Finds the FIRST occurrence of `"<keyName>":` in `data` and parses
    ///      the immediately-following numeric token. Spaces between `:` and
    ///      the number are tolerated; everything else (string-wrapped values,
    ///      nested objects, scientific notation, leading `+`) is rejected.
    ///      The extension verifier deliberately stays narrow — clients that
    ///      need richer parsing should write their own.
    function _extractAndParse(string memory dataStr, string memory key) internal pure returns (uint256) {
        bytes memory data = bytes(dataStr);
        bytes memory needle = abi.encodePacked('"', key, '":');

        uint256 nLen = needle.length;
        uint256 hLen = data.length;
        if (nLen > hLen) revert PriceNotFound();

        uint256 last = hLen - nLen;
        uint256 found = type(uint256).max;
        for (uint256 i = 0; i <= last; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < nLen; ++j) {
                if (data[i + j] != needle[j]) { match_ = false; break; }
            }
            if (match_) { found = i + nLen; break; }
        }
        if (found == type(uint256).max) revert PriceNotFound();

        // Skip any single space after `:`.
        if (found < hLen && data[found] == 0x20) ++found;

        return _parseDecimal(data, found);
    }

    /// @dev Parses a fixed-point decimal as an integer scaled to 8 fractional
    ///      digits ("67234.51" → 67234_51_000_000). Eight digits comfortably
    ///      covers asset prices without overflow risk for any sane uint256.
    ///      A whole-number input ("123") yields 123 * 1e8.
    function _parseDecimal(bytes memory data, uint256 start) internal pure returns (uint256) {
        uint256 result;
        uint256 hLen = data.length;
        bool seenDot;
        uint256 fracDigits;
        bool sawDigit;

        uint256 i = start;
        while (i < hLen) {
            bytes1 c = data[i];
            if (c == 0x2E /* '.' */) {
                if (seenDot) revert PriceParseError();
                seenDot = true;
            } else if (c >= 0x30 && c <= 0x39) {
                if (seenDot) {
                    if (fracDigits >= 8) {
                        // Truncate excess precision — keep the first 8 fractional
                        // digits, ignore the rest. Defensible default for prices.
                        break;
                    }
                    ++fracDigits;
                }
                result = result * 10 + uint256(uint8(c) - 0x30);
                sawDigit = true;
            } else {
                break;
            }
            ++i;
        }
        if (!sawDigit) revert PriceParseError();

        // Pad to 8 fractional digits regardless of input precision.
        while (fracDigits < 8) {
            result *= 10;
            unchecked { ++fracDigits; }
        }
        return result;
    }
}
