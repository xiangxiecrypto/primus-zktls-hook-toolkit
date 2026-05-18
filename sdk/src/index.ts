// Public API surface for `@primus-zktls/hook-sdk`.

export type {
  Address,
  Hex,
  AlgorithmType,
  BindingLocation,
  AttNetworkRequest,
  AttNetworkResponseResolve,
  Attestor,
  Attestation,
  RequestStep,
  DataBinding,
  AttestationSpec,
  StepDefinition,
  BindingDefinition,
  JobDefinition,
  JobBindingContext,
} from "./types.js";

export { TimeUnit } from "./types.js";

export { applySubstitutions, escapeForLocation, extractPlaceholders } from "./placeholder.js";

export {
  buildSpec,
  buildAdditionParams,
  computeJobBinding,
  hashResponseResolves,
  resolveStep,
} from "./specBuilder.js";

export {
  encodeFundOptParams,
  encodeSubmitOptParams,
  computeDeliverable,
} from "./encoding.js";

export {
  runJob,
  type AttestorFn,
  type AttestorInput,
  type RunJobResult,
} from "./runJob.js";

export {
  createPrimusAttestor,
  type PrimusCoreTLSLike,
  type PrimusAttRequestLike,
} from "./primusAdapter.js";

export { baseSepolia, baseSepoliaV1, demoWallets } from "./addresses.js";
