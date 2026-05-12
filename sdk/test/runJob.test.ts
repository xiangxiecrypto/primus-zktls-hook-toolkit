import { describe, expect, it, vi } from "vitest";
import { keccak256, toBytes } from "viem";
import { runJob, type AttestorFn } from "../src/runJob.js";
import type { Attestation, JobDefinition } from "../src/types.js";

const PROVIDER = "0x000000000000000000000000000000000000b0b1";

function mockAttestor(dataPerStep: string[]): AttestorFn {
  let i = 0;
  return async input => {
    const data = dataPerStep[i++] ?? "";
    const att: Attestation = {
      recipient: input.recipient,
      request: {
        url: input.request.url,
        // header is serialised as JSON because the on-chain struct holds it
        // as a string; the SDK does not roundtrip headers in this MVP.
        header: JSON.stringify(input.request.header),
        method: input.request.method,
        body: input.request.body,
      },
      reponseResolve: input.responseResolves,
      data,
      attConditions: "",
      timestamp: 1700000000000n, // ms
      additionParams: input.additionParams,
      attestors: [],
      signatures: [],
    };
    return att;
  };
}

describe("runJob", () => {
  it("executes a single-step job and returns deliverable + encoded optParams", async () => {
    const job: JobDefinition = {
      steps: [{
        method: "GET",
        url: "https://api.example.com/x",
        responseResolves: [{ keyName: "p", parseType: "json", parsePath: "$.p" }],
        attMode: "proxytls",
      }],
      bindings: [],
    };

    const result = await runJob(job, {
      recipient: PROVIDER,
      attestor: mockAttestor(['{"p":42}']),
    });

    expect(result.attestations).toHaveLength(1);
    expect(result.attestations[0]!.request.url).toBe("https://api.example.com/x");
    expect(result.deliverable).toBe(keccak256(toBytes('{"p":42}')));
    expect(result.submitOptParams.startsWith("0x")).toBe(true);
  });

  it("substitutes <<id>> across steps before calling the attestor", async () => {
    const job: JobDefinition = {
      steps: [
        {
          method: "GET",
          url: "https://api.example.com/coins/bitcoin",
          responseResolves: [{ keyName: "id", parseType: "json", parsePath: "$.id" }],
        },
        {
          method: "GET",
          url: "https://api.example.com/coins/<<id>>/history",
          responseResolves: [{ keyName: "price", parseType: "json", parsePath: "$.p" }],
        },
      ],
      bindings: [
        { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url", value: "bitcoin" },
      ],
    };

    const attestor = vi.fn(mockAttestor(['{"id":"bitcoin"}', '{"p":67234.51}']));
    await runJob(job, { recipient: PROVIDER, attestor });

    // Step 1's URL is the substituted form, not the template.
    expect(attestor.mock.calls[1]![0].request.url).toBe(
      "https://api.example.com/coins/bitcoin/history",
    );
  });

  it("uses the explicit deliverableSourceStep when set", async () => {
    const job: JobDefinition = {
      steps: [
        {
          method: "GET",
          url: "https://x/a",
          responseResolves: [],
        },
        {
          method: "GET",
          url: "https://x/b",
          responseResolves: [],
        },
      ],
      bindings: [],
      deliverableSourceStep: 0,
    };
    const result = await runJob(job, {
      recipient: PROVIDER,
      attestor: mockAttestor(["first-step", "second-step"]),
    });
    expect(result.deliverable).toBe(keccak256(toBytes("first-step")));
  });

  it("rejects an attestor that returns a tampered URL", async () => {
    const job: JobDefinition = {
      steps: [{
        method: "GET",
        url: "https://expected.example/x",
        responseResolves: [],
      }],
      bindings: [],
    };
    const badAttestor: AttestorFn = async input => ({
      recipient: input.recipient,
      request: { url: "https://malicious.example/x", header: "", method: "GET", body: "" },
      reponseResolve: [],
      data: "x",
      attConditions: "",
      timestamp: 0n,
      additionParams: input.additionParams,
      attestors: [],
      signatures: [],
    });
    await expect(runJob(job, { recipient: PROVIDER, attestor: badAttestor })).rejects.toThrow(
      /wrong url/,
    );
  });

  it("rejects deliverableSourceStep out of range", async () => {
    const job: JobDefinition = {
      steps: [{
        method: "GET",
        url: "https://x",
        responseResolves: [],
      }],
      bindings: [],
      deliverableSourceStep: 5,
    };
    await expect(runJob(job, { recipient: PROVIDER, attestor: mockAttestor([]) })).rejects.toThrow(
      /out of range/,
    );
  });

  it("propagates attestor errors", async () => {
    const job: JobDefinition = {
      steps: [{
        method: "GET",
        url: "https://x",
        responseResolves: [],
      }],
      bindings: [],
    };
    const failing: AttestorFn = async () => {
      throw new Error("primus offline");
    };
    await expect(runJob(job, { recipient: PROVIDER, attestor: failing })).rejects.toThrow(
      /primus offline/,
    );
  });
});
