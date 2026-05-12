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

export interface RequestStep {
  methodHash: Hex;
  urlHash: Hex;
  bodyHash: Hex;
  responseResolveHash: Hex;
  additionParamsHash: Hex;
  maxAge: bigint;
  pinnedAttestor: Address;
}

export interface DataBinding {
  fromStep: number;
  toStep: number;
  /** 0=url, 1=header, 2=body */
  toLocation: number;
  /** The static bytes the spec expects to flow across this binding. */
  value: Hex;
}

export interface AttestationSpec {
  steps: RequestStep[];
  bindings: DataBinding[];
  deliverableSourceStep: number;
  customVerifier: Address;
  configured: boolean;
}

// ----- Developer-facing definitions (higher-level than the on-chain structs) -----

export type AlgorithmType = "proxytls" | "mpctls";
export type BindingLocation = "url" | "header" | "body";

export interface StepDefinition {
  method: string;
  /** URL template; may contain `<<keyName>>` placeholders to be substituted from prior steps. */
  url: string;
  /** Optional request headers. Stringified to canonical JSON before hashing. */
  header?: Record<string, string>;
  /** Body template; may contain `<<keyName>>` placeholders. */
  body?: string;
  responseResolves: AttNetworkResponseResolve[];
  attMode?: AlgorithmType;
  maxAgeSeconds?: number;
  pinnedAttestor?: Address;
}

export interface BindingDefinition {
  fromStep: number;
  fromKey: string;
  toStep: number;
  toLocation: BindingLocation;
  /** The actual bytes (UTF-8 string) that must flow from fromStep.data into toStep.<location>. */
  value: string;
}

export interface JobDefinition {
  steps: StepDefinition[];
  bindings: BindingDefinition[];
  /** Defaults to the last step. */
  deliverableSourceStep?: number;
  /** address(0) means no extension verifier. */
  customVerifier?: Address;
}
