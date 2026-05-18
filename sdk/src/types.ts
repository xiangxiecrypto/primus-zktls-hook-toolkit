// On-chain struct mirrors -- field order and names match
// `@erc8183-hooks/hooks/ZkTlsAttestationHook.sol` byte-for-byte, including
// the `reponseResolve` typo. Changing these names breaks ABI compatibility
// with the deployed verifier; the typo is preserved deliberately.

export type Address = `0x${string}`;
export type Hex = `0x${string}`;

export interface AttNetworkRequest {
  url: string;
  /** JSON-encoded header map, e.g. '{"user-agent":"..."}' */
  header: string;
  method: string;
  body: string;
}

export interface AttNetworkResponseResolve {
  keyName: string;
  /** "JSON" or "HTML" — matches the verifier's casing. */
  parseType: string;
  parsePath: string;
}

export interface Attestor {
  attestorAddr: Address;
  url: string;
}

export interface Attestation {
  recipient: Address;
  request: AttNetworkRequest;
  reponseResolve: AttNetworkResponseResolve[];
  data: string;
  attConditions: string;
  timestamp: bigint;
  additionParams: string;
  attestors: Attestor[];
  signatures: Hex[];
}

/** On-chain enum mirror: 0 = Seconds, 1 = Milliseconds. */
export enum TimeUnit {
  Seconds = 0,
  Milliseconds = 1,
}

export interface RequestStep {
  methodHash: Hex;
  urlHash: Hex;
  bodyHash: Hex;
  responseResolveHash: Hex;
  additionParamsHash: Hex;
  /** keccak256(abi.encode(jobId, hookAddress, chainId)). Cross-job replay defense. */
  expectedJobBinding: Hex;
  maxAge: bigint;
  timeUnit: TimeUnit;
  /** Allowlist of acceptable attestor signers. Empty = skip the quorum check. */
  allowedAttestors: Address[];
  /** Minimum number of `att.attestors` whose address must lie in `allowedAttestors`. 0 = skip. */
  minAttestorsRequired: number;
}

export interface DataBinding {
  fromStep: number;
  toStep: number;
  /** 0=url, 1=header, 2=body */
  toLocation: number;
  /** Static expected bytes (used when fromExtractKey is empty). */
  value: Hex;
  /** Dynamic: name of a JSON key in atts[fromStep].data; the hook extracts its value at submit. */
  fromExtractKey: Hex;
}

export interface AttestationSpec {
  steps: RequestStep[];
  bindings: DataBinding[];
  deliverableSourceStep: number;
  customVerifier: Address;
  /** Snapshot of the hook's zkTlsVerifier at fund time. The client sets this to address(0); the hook overwrites at _postFund. */
  zkTlsVerifierSnapshot: Address;
  configured: boolean;
}

// ----- Developer-facing definitions (higher-level than the on-chain structs) -----

export type AlgorithmType = "proxytls" | "mpctls";
export type BindingLocation = "url" | "header" | "body";

export interface StepDefinition {
  method: string;
  /** URL template; may contain `<<keyName>>` placeholders to be substituted from prior steps. */
  url: string;
  /** Optional request headers. */
  header?: Record<string, string>;
  /** Body template; may contain `<<keyName>>` placeholders. */
  body?: string;
  responseResolves: AttNetworkResponseResolve[];
  attMode?: AlgorithmType;
  /** Maximum acceptable age of the attestation in seconds. Must be in [1, 24*3600]. */
  maxAgeSeconds?: number;
  /** Timestamp unit used by the attestor's `att.timestamp`. Defaults to Milliseconds (Primus convention). */
  timeUnit?: TimeUnit;
  /** Attestors that count toward `minAttestorsRequired`. Empty = skip quorum check. */
  allowedAttestors?: Address[];
  /** Minimum number of attestation signers that must lie in allowedAttestors. 0 = skip. */
  minAttestorsRequired?: number;
}

export interface BindingDefinition {
  fromStep: number;
  fromKey: string;
  toStep: number;
  toLocation: BindingLocation;
  /** Static expected value. Set exactly one of {value, fromExtractKey}. */
  value?: string;
  /**
   * Dynamic extraction: name a JSON key in atts[fromStep].data; the hook
   * extracts its parsed value at submit time and uses that as the substring
   * to check. Set exactly one of {value, fromExtractKey}.
   */
  fromExtractKey?: string;
}

export interface JobDefinition {
  steps: StepDefinition[];
  bindings: BindingDefinition[];
  /** Defaults to the last step. */
  deliverableSourceStep?: number;
  /** address(0) means no extension verifier. */
  customVerifier?: Address;
}

/**
 * Context required by buildSpec and runJob so both sides can derive the
 * per-job binding identically: `keccak256(abi.encode(jobId, hookAddress, chainId))`.
 */
export interface JobBindingContext {
  jobId: bigint;
  hookAddress: Address;
  chainId: number | bigint;
}
