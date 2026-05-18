import type {
  Address,
  Attestation,
  AttNetworkResponseResolve,
  Hex,
  JobBindingContext,
  JobDefinition,
  StepDefinition,
} from "./types.js";
import { resolveStep, buildAdditionParams, computeJobBinding } from "./specBuilder.js";
import { computeDeliverable, encodeSubmitOptParams } from "./encoding.js";

/**
 * Per-step attestor function. The provider plugs in a real implementation
 * (e.g. {@link createPrimusAttestor}) or, in tests, a mock that synthesises
 * fixtures. Separating the attestor from the orchestrator lets us unit-test
 * `runJob` without any network or Primus credentials.
 */
export type AttestorFn = (input: AttestorInput) => Promise<Attestation>;

export interface AttestorInput {
  recipient: Address;
  request: {
    url: string;
    method: string;
    header: Record<string, string>;
    body: string;
  };
  responseResolves: AttNetworkResponseResolve[];
  additionParams: string;
}

export interface RunJobResult {
  attestations: Attestation[];
  deliverable: Hex;
  /** Pre-encoded `optParams` bytes ready to pass to `ERC8183.submit(...)`. */
  submitOptParams: Hex;
}

/**
 * Execute every step of a job spec in order, producing one attestation per
 * step. Bindings are applied to substitute `<<keyName>>` placeholders in
 * each step's url/body before attestation; the per-job binding is embedded
 * into `additionParams` so the attestor signs over it (cross-job replay
 * defense).
 *
 * `opts.ctx` MUST equal the same context the client used in `buildSpec` —
 * otherwise the hashes/binding won't match the spec on chain.
 */
export async function runJob(
  job: JobDefinition,
  opts: {
    recipient: Address;
    attestor: AttestorFn;
    ctx: JobBindingContext;
    /** Bytes to forward verbatim to a customVerifier, if any. */
    customCalldata?: Hex;
  },
): Promise<RunJobResult> {
  const { recipient, attestor, ctx, customCalldata = "0x" } = opts;
  const attestations: Attestation[] = [];

  const stepCount = job.steps.length;
  if (stepCount === 0) throw new Error("runJob: at least one step required");
  if (job.deliverableSourceStep !== undefined &&
      job.deliverableSourceStep >= stepCount) {
    throw new Error("runJob: deliverableSourceStep out of range");
  }

  for (let i = 0; i < stepCount; i++) {
    const step: StepDefinition = job.steps[i]!;
    const bindingsHere = job.bindings.filter(b => b.toStep === i);
    const resolved = resolveStep(step, bindingsHere, ctx);

    const att = await attestor({
      recipient,
      request: {
        url: resolved.url,
        method: step.method,
        header: resolved.header,
        body: resolved.body,
      },
      responseResolves: step.responseResolves,
      additionParams: resolved.additionParams,
    });

    // Defensive: an attestor implementation that returns a different
    // request shape from what we asked for would silently break the
    // on-chain hash checks. Catch it here with a clearer error.
    if (att.request.url !== resolved.url) {
      throw new Error(`runJob: attestor returned wrong url at step ${i}`);
    }
    if (att.request.method !== step.method) {
      throw new Error(`runJob: attestor returned wrong method at step ${i}`);
    }
    if (att.additionParams !== resolved.additionParams) {
      throw new Error(`runJob: attestor returned wrong additionParams at step ${i}`);
    }

    attestations.push(att);
  }

  const deliverable = computeDeliverable(
    attestations,
    job.deliverableSourceStep ?? stepCount - 1,
  );
  const submitOptParams = encodeSubmitOptParams(attestations, customCalldata);

  return { attestations, deliverable, submitOptParams };
}

export { buildAdditionParams, computeJobBinding };
