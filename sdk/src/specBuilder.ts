import {
  encodeAbiParameters,
  keccak256,
  stringToBytes,
  toBytes,
  toHex,
  zeroAddress,
} from "viem";
import type {
  Address,
  AlgorithmType,
  AttNetworkResponseResolve,
  AttestationSpec,
  BindingDefinition,
  BindingLocation,
  DataBinding,
  Hex,
  JobBindingContext,
  JobDefinition,
  RequestStep,
  StepDefinition,
} from "./types.js";
import { TimeUnit } from "./types.js";
import { applySubstitutions } from "./placeholder.js";

/**
 * Compute the per-job binding hash the hook expects:
 *   keccak256(abi.encode(jobId, hookAddress, chainId))
 *
 * Embedded into every step's `additionParams` (and pinned in
 * `RequestStep.expectedJobBinding`) to prevent cross-job replay of
 * signed attestations.
 */
export function computeJobBinding(ctx: JobBindingContext): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "uint256" }],
      [BigInt(ctx.jobId), ctx.hookAddress, BigInt(ctx.chainId)],
    ),
  );
}

/**
 * Compile a developer-friendly JobDefinition into the on-chain
 * AttestationSpec the hook expects. Per-step bindings are resolved into
 * concrete URL/body strings BEFORE hashing — the spec pins the post-
 * substitution shape, so any provider that fails to apply substitutions
 * identically will produce mismatching hashes and be rejected at submit.
 *
 * The `ctx` parameter is required so both the spec's `expectedJobBinding`
 * and the canonical `additionParams` carry the per-job binding. The
 * provider's runJob must be given the SAME `ctx` so the attestation
 * Primus signs over carries the same binding string.
 */
export function buildSpec(job: JobDefinition, ctx: JobBindingContext): AttestationSpec {
  const stepCount = job.steps.length;
  if (stepCount === 0) throw new Error("buildSpec: at least one step required");
  if (stepCount > 16) throw new Error("buildSpec: too many steps (max 16)");
  if (job.bindings.length > 32) throw new Error("buildSpec: too many bindings (max 32)");

  const jobBinding = computeJobBinding(ctx);

  // Index bindings by destination step for placeholder substitution.
  const bindingsByToStep = new Map<number, BindingDefinition[]>();
  for (const b of job.bindings) {
    if (b.fromStep >= b.toStep) {
      throw new Error(`buildSpec: binding must be forward (fromStep=${b.fromStep}, toStep=${b.toStep})`);
    }
    if (b.toStep >= stepCount) throw new Error(`buildSpec: binding toStep ${b.toStep} out of range`);
    const hasStatic = typeof b.value === "string" && b.value.length > 0;
    const hasDynamic = typeof b.fromExtractKey === "string" && b.fromExtractKey.length > 0;
    if (hasStatic === hasDynamic) {
      throw new Error("buildSpec: exactly one of {value, fromExtractKey} must be set");
    }
    const list = bindingsByToStep.get(b.toStep) ?? [];
    list.push(b);
    bindingsByToStep.set(b.toStep, list);
  }

  const steps: RequestStep[] = job.steps.map((step, idx) => {
    const subsForUrl = collectSubs(bindingsByToStep.get(idx), "url");
    const subsForBody = collectSubs(bindingsByToStep.get(idx), "body");

    const resolvedUrl = applySubstitutions(step.url, subsForUrl, "url");
    const resolvedBody = applySubstitutions(step.body ?? "", subsForBody, "body");
    const additionParams = buildAdditionParams(step.attMode ?? "proxytls", jobBinding);

    return {
      methodHash: keccak256(toBytes(step.method)),
      urlHash: keccak256(toBytes(resolvedUrl)),
      bodyHash: keccak256(toBytes(resolvedBody)),
      responseResolveHash: hashResponseResolves(step.responseResolves),
      additionParamsHash: keccak256(toBytes(additionParams)),
      expectedJobBinding: jobBinding,
      maxAge: BigInt(step.maxAgeSeconds ?? 300),
      timeUnit: step.timeUnit ?? TimeUnit.Milliseconds,
      allowedAttestors: step.allowedAttestors ?? [],
      minAttestorsRequired: step.minAttestorsRequired ?? 0,
    };
  });

  const bindings: DataBinding[] = job.bindings.map(b => {
    const hasDynamic = typeof b.fromExtractKey === "string" && b.fromExtractKey.length > 0;
    return {
      fromStep: b.fromStep,
      toStep: b.toStep,
      toLocation: locationToInt(b.toLocation),
      value: hasDynamic ? ("0x" as Hex) : toHex(stringToBytes(b.value!)),
      fromExtractKey: hasDynamic ? toHex(stringToBytes(b.fromExtractKey!)) : ("0x" as Hex),
    };
  });

  return {
    steps,
    bindings,
    deliverableSourceStep: job.deliverableSourceStep ?? stepCount - 1,
    customVerifier: job.customVerifier ?? zeroAddress,
    // Hook overwrites this slot at _postFund with its live zkTlsVerifier.
    zkTlsVerifierSnapshot: zeroAddress,
    configured: false,
  };
}

/**
 * Build the canonical addition-params JSON the hook hashes. Carries both
 * the algorithm-type declaration and the per-job binding hash. Used both
 * by the spec builder (for additionParamsHash) and runJob (for the
 * attestor request).
 */
export function buildAdditionParams(attMode: AlgorithmType, jobBinding: Hex): string {
  // Field order is fixed — both sides must produce byte-identical JSON
  // for the on-chain hash to match.
  return JSON.stringify({ algorithmType: attMode, jobBinding });
}

/**
 * Compute the on-chain `responseResolveHash` for a step's responseResolves.
 * Primus clears `parseType` in the attestation it signs; the SDK mirrors
 * that normalization so the spec's hash matches what the hook recomputes
 * from the attestation at submit time.
 */
export function hashResponseResolves(resolves: AttNetworkResponseResolve[]): Hex {
  const leaves: Hex[] = resolves.map(r =>
    keccak256(
      encodeAbiParameters(
        [{ type: "string" }, { type: "string" }, { type: "string" }],
        [r.keyName, "", r.parsePath],
      ),
    ),
  );
  return keccak256(encodeAbiParameters([{ type: "bytes32[]" }], [leaves]));
}

/**
 * Resolve a step's runtime URL/body given the binding values. Used by both
 * the spec builder (with static values from BindingDefinition.value) and
 * by runJob (with the same values at execution time). The returned
 * additionParams matches what `buildSpec` hashes — so the provider's
 * attestor request, when signed, will produce the same hash.
 */
export function resolveStep(
  step: StepDefinition,
  bindingsToThisStep: BindingDefinition[],
  ctx: JobBindingContext,
): {
  url: string;
  body: string;
  header: Record<string, string>;
  additionParams: string;
} {
  const subsForUrl = collectSubs(bindingsToThisStep, "url");
  const subsForBody = collectSubs(bindingsToThisStep, "body");
  return {
    url: applySubstitutions(step.url, subsForUrl, "url"),
    body: applySubstitutions(step.body ?? "", subsForBody, "body"),
    header: step.header ?? {},
    additionParams: buildAdditionParams(step.attMode ?? "proxytls", computeJobBinding(ctx)),
  };
}

function collectSubs(
  bindings: BindingDefinition[] | undefined,
  location: BindingLocation,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const b of bindings ?? []) {
    if (b.toLocation !== location) continue;
    // For dynamic bindings, the runtime substitution value is the same as
    // the static value would be — the off-chain side knows what's
    // expected, the hook just verifies it matches.
    const v = (b.value ?? b.fromExtractKey ?? "");
    if (v.length > 0) out[b.fromKey] = v;
  }
  return out;
}

function locationToInt(loc: BindingLocation): number {
  switch (loc) {
    case "url": return 0;
    case "header": return 1;
    case "body": return 2;
  }
}

// Re-export for users who want to compute a deliverable manually.
export { zeroAddress } from "viem";
