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
  AttNetworkResponseResolve,
  AttestationSpec,
  BindingDefinition,
  BindingLocation,
  DataBinding,
  Hex,
  JobDefinition,
  RequestStep,
  StepDefinition,
} from "./types.js";
import { applySubstitutions } from "./placeholder.js";

/**
 * Compile a developer-friendly JobDefinition into the on-chain
 * AttestationSpec the hook expects. Per-step bindings are resolved into
 * concrete URL/body strings BEFORE hashing — the spec pins the post-
 * substitution shape, so any provider that fails to apply substitutions
 * identically will produce mismatching hashes and be rejected at submit.
 *
 * Throws if a placeholder in a step's url/body has no corresponding binding.
 */
export function buildSpec(job: JobDefinition): AttestationSpec {
  const stepCount = job.steps.length;
  if (stepCount === 0) throw new Error("buildSpec: at least one step required");
  if (stepCount > 16) throw new Error("buildSpec: too many steps (max 16)");
  if (job.bindings.length > 32) throw new Error("buildSpec: too many bindings (max 32)");

  // Index bindings by the step they target so we can substitute placeholders
  // per-step. Each step's url and body are substituted independently.
  const bindingsByToStep = new Map<number, BindingDefinition[]>();
  for (const b of job.bindings) {
    if (b.fromStep >= b.toStep) {
      throw new Error(`buildSpec: binding must be forward (fromStep=${b.fromStep}, toStep=${b.toStep})`);
    }
    if (b.toStep >= stepCount) throw new Error(`buildSpec: binding toStep ${b.toStep} out of range`);
    if (b.value.length === 0) throw new Error("buildSpec: binding value cannot be empty");
    const list = bindingsByToStep.get(b.toStep) ?? [];
    list.push(b);
    bindingsByToStep.set(b.toStep, list);
  }

  const steps: RequestStep[] = job.steps.map((step, idx) => {
    const subsForUrl = collectSubs(bindingsByToStep.get(idx), "url");
    const subsForBody = collectSubs(bindingsByToStep.get(idx), "body");
    const subsForHeader = collectSubs(bindingsByToStep.get(idx), "header");

    const resolvedUrl = applySubstitutions(step.url, subsForUrl, "url");
    const resolvedBody = applySubstitutions(step.body ?? "", subsForBody, "body");
    const resolvedHeader = canonicalHeader(step.header ?? {}, subsForHeader);
    const additionParams = buildAdditionParams(step.attMode ?? "proxytls");

    return {
      methodHash: keccak256(toBytes(step.method)),
      urlHash: keccak256(toBytes(resolvedUrl)),
      bodyHash: keccak256(toBytes(resolvedBody)),
      responseResolveHash: hashResponseResolves(step.responseResolves),
      additionParamsHash: keccak256(toBytes(additionParams)),
      // header isn't pinned by the hook in MVP, but we expose the canonical
      // form via getResolvedRequest() so the provider can reproduce it.
      maxAge: BigInt(step.maxAgeSeconds ?? 300),
      pinnedAttestor: step.pinnedAttestor ?? zeroAddress,
      // discard `resolvedHeader` — kept here only to validate substitution.
      ...(void resolvedHeader, {}),
    };
  });

  const bindings: DataBinding[] = job.bindings.map(b => ({
    fromStep: b.fromStep,
    toStep: b.toStep,
    toLocation: locationToInt(b.toLocation),
    value: toHex(stringToBytes(b.value)),
  }));

  return {
    steps,
    bindings,
    deliverableSourceStep: job.deliverableSourceStep ?? stepCount - 1,
    customVerifier: job.customVerifier ?? zeroAddress,
    // `configured` is set true by the hook on store; we send false.
    configured: false,
  };
}

/**
 * Build the canonical addition-params JSON the hook hashes. Currently just
 * `{"algorithmType":"<mode>"}`. Kept as a helper so both the client side
 * (spec builder) and the provider side (runJob) hash exactly the same form.
 */
export function buildAdditionParams(attMode: "proxytls" | "mpctls"): string {
  return JSON.stringify({ algorithmType: attMode });
}

/**
 * Compute the on-chain `responseResolveHash` for a step's responseResolves.
 *
 * Encoding must exactly match the Solidity helper `_hashResponseResolves`:
 *   keccak256(abi.encode([keccak256(abi.encode(keyName, parseType, parsePath)), ...]))
 *
 * Primus clears `parseType` in the attestation it signs (the type is
 * consumed during parsing and not preserved on-chain). The SDK mirrors that
 * normalization so the spec's hash matches what the hook recomputes from
 * the attestation at submit time. Developer-facing job definitions can
 * still set parseType: "json" — it's only the hash that drops it.
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
 * the spec builder (with static values from BindingDefinition.value) and by
 * runJob (with the same values at execution time, sanity-checked against
 * the binding declarations).
 */
export function resolveStep(
  step: StepDefinition,
  bindingsToThisStep: BindingDefinition[],
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
    additionParams: buildAdditionParams(step.attMode ?? "proxytls"),
  };
}

function collectSubs(
  bindings: BindingDefinition[] | undefined,
  location: BindingLocation,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const b of bindings ?? []) {
    if (b.toLocation === location) out[b.fromKey] = b.value;
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

function canonicalHeader(header: Record<string, string>, subs: Record<string, string>): string {
  // Stable key order so the hash is reproducible regardless of insertion order.
  const keys = Object.keys(header).sort();
  const out: Record<string, string> = {};
  for (const k of keys) {
    out[k] = applySubstitutions(header[k]!, subs, "header");
  }
  return JSON.stringify(out);
}

// Re-export for users who want to compute a deliverable manually.
export { zeroAddress } from "viem";
