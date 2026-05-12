import type { AttestorFn } from "./runJob.js";
import type { Attestation } from "./types.js";

/**
 * Thin adapter that turns Primus's `PrimusCoreTLS` into an `AttestorFn` the
 * runJob orchestrator can use. Everything Primus-specific lives in this
 * module so the rest of the SDK stays vendor-neutral and unit-testable
 * without the Primus SDK installed.
 *
 * Usage:
 *
 *   import { PrimusCoreTLS } from "@primuslabs/zktls-core-sdk";
 *   const primus = new PrimusCoreTLS();
 *   await primus.init(appId, appSecret, "auto");
 *   const attestor = createPrimusAttestor(primus);
 *   const result = await runJob(job, { recipient, attestor });
 *
 * The adapter is the only place that imports the Primus SDK type. Tests
 * skip this module entirely and inject a mock attestor directly.
 */

/** Loose structural type for what we actually call on Primus's main class. */
export interface PrimusCoreTLSLike {
  generateRequestParams(
    request: {
      url: string;
      method: string;
      header?: Record<string, string>;
      body?: string;
    },
    responseResolves: { keyName: string; parseType: string; parsePath: string }[],
    userAddress: string,
  ): PrimusAttRequestLike;

  startAttestation(req: PrimusAttRequestLike): Promise<Attestation>;
}

export interface PrimusAttRequestLike {
  setAttMode(opts: { algorithmType: "proxytls" | "mpctls"; resultType: "plain" }): void;
  setAdditionParams(json: string): void;
}

export function createPrimusAttestor(primus: PrimusCoreTLSLike): AttestorFn {
  return async input => {
    // additionParams contains the algorithm-type declaration the hook will
    // hash and pin. Parse it back out so we can pass it to Primus.
    let algorithmType: "proxytls" | "mpctls" = "proxytls";
    try {
      const parsed = JSON.parse(input.additionParams) as { algorithmType?: string };
      if (parsed.algorithmType === "mpctls" || parsed.algorithmType === "proxytls") {
        algorithmType = parsed.algorithmType;
      }
    } catch {
      // additionParams free-form for non-attMode use cases; default to proxytls.
    }

    const req = primus.generateRequestParams(
      {
        url: input.request.url,
        method: input.request.method,
        header: input.request.header,
        body: input.request.body,
      },
      input.responseResolves,
      input.recipient,
    );

    req.setAttMode({ algorithmType, resultType: "plain" });
    req.setAdditionParams(input.additionParams);

    return primus.startAttestation(req);
  };
}
