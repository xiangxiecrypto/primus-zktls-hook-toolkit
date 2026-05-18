import { encodeAbiParameters, keccak256, parseAbiParameters, toBytes } from "viem";
import type { Attestation, AttestationSpec, Hex } from "./types.js";

// ABI parameter spec for `Attestation` matches the Solidity struct field-by-field.
// Keep this string in sync with `@erc8183-hooks/hooks/ZkTlsAttestationHook.sol`.
const ATTESTATION_TUPLE =
  "(address recipient," +
  "(string url,string header,string method,string body) request," +
  "(string keyName,string parseType,string parsePath)[] reponseResolve," +
  "string data," +
  "string attConditions," +
  "uint64 timestamp," +
  "string additionParams," +
  "(address attestorAddr,string url)[] attestors," +
  "bytes[] signatures)";

// RequestStep now includes expectedJobBinding (bytes32), timeUnit (uint8 enum),
// allowedAttestors (address[]) and minAttestorsRequired (uint8) — and no longer
// has pinnedAttestor.
const REQUEST_STEP_TUPLE =
  "(bytes32 methodHash," +
  "bytes32 urlHash," +
  "bytes32 bodyHash," +
  "bytes32 responseResolveHash," +
  "bytes32 additionParamsHash," +
  "bytes32 expectedJobBinding," +
  "uint64 maxAge," +
  "uint8 timeUnit," +
  "address[] allowedAttestors," +
  "uint8 minAttestorsRequired)";

// DataBinding now carries fromExtractKey alongside the static value.
const DATA_BINDING_TUPLE =
  "(uint8 fromStep,uint8 toStep,uint8 toLocation,bytes value,bytes fromExtractKey)";

const SPEC_TUPLE =
  "(" +
  REQUEST_STEP_TUPLE + "[] steps," +
  DATA_BINDING_TUPLE + "[] bindings," +
  "uint8 deliverableSourceStep," +
  "address customVerifier," +
  "address zkTlsVerifierSnapshot," +
  "bool configured" +
  ")";

// viem v2's `encodeAbiParameters` infers value types from the params arg,
// but `parseAbiParameters` returns an erased `AbiParameter[]` whose inner
// shapes are lost — so the value-type inference collapses to `never`.
// Runtime behaviour is correct (the ABI strings match the Solidity structs
// in the hook), and the wrapper functions below provide typed entrypoints,
// so the cast is contained here.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyEncodeArgs = readonly any[];

/**
 * ABI-encode the spec for use as `optParams` to `fund(...)`. The hook's
 * `_postFund` decodes via `abi.decode(optParams, (AttestationSpec))`.
 */
export function encodeFundOptParams(spec: AttestationSpec): Hex {
  const params = parseAbiParameters(SPEC_TUPLE);
  return encodeAbiParameters(params, [spec] as AnyEncodeArgs as never);
}

/**
 * ABI-encode the payload for use as `optParams` to `submit(...)`. The hook's
 * `_preSubmit` decodes via `abi.decode(optParams, (Attestation[], bytes))`.
 */
export function encodeSubmitOptParams(
  attestations: Attestation[],
  customCalldata: Hex = "0x",
): Hex {
  const params = parseAbiParameters(`${ATTESTATION_TUPLE}[] atts, bytes customCalldata`);
  return encodeAbiParameters(
    params,
    [attestations, customCalldata] as AnyEncodeArgs as never,
  );
}

/**
 * Compute the deliverable bytes32 the provider must pass to `submit`. By
 * default this is `keccak256(bytes(atts[sourceStep].data))` — the same
 * formula the hook applies in `_preSubmit`. Override only if the hook's
 * `deliverableSourceStep` was set to a custom value.
 */
export function computeDeliverable(
  attestations: Attestation[],
  sourceStep?: number,
): Hex {
  const idx = sourceStep ?? attestations.length - 1;
  const att = attestations[idx];
  if (!att) throw new Error(`computeDeliverable: no attestation at step ${idx}`);
  return keccak256(toBytes(att.data));
}
