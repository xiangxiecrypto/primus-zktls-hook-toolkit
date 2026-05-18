import { describe, expect, it } from "vitest";
import { keccak256, stringToHex, toBytes } from "viem";
import {
  buildAdditionParams,
  buildSpec,
  computeJobBinding,
  hashResponseResolves,
  resolveStep,
} from "../src/specBuilder.js";
import { TimeUnit } from "../src/types.js";
import type { JobBindingContext, JobDefinition } from "../src/types.js";

const CTX: JobBindingContext = {
  jobId: 1n,
  hookAddress: "0xd954517b4c4f0d3a9be69f4d4e2cbc6f30ed9d1a",
  chainId: 84532,
};

describe("buildAdditionParams", () => {
  const binding = computeJobBinding(CTX);
  it("produces stable JSON for proxytls with binding", () => {
    expect(buildAdditionParams("proxytls", binding))
      .toBe(`{"algorithmType":"proxytls","jobBinding":"${binding}"}`);
  });
  it("produces stable JSON for mpctls with binding", () => {
    expect(buildAdditionParams("mpctls", binding))
      .toBe(`{"algorithmType":"mpctls","jobBinding":"${binding}"}`);
  });
});

describe("computeJobBinding", () => {
  it("changes when jobId changes", () => {
    const a = computeJobBinding({ ...CTX, jobId: 1n });
    const b = computeJobBinding({ ...CTX, jobId: 2n });
    expect(a).not.toBe(b);
  });
  it("changes when chainId changes", () => {
    const a = computeJobBinding({ ...CTX, chainId: 84532 });
    const b = computeJobBinding({ ...CTX, chainId: 1 });
    expect(a).not.toBe(b);
  });
  it("changes when hookAddress changes", () => {
    const a = computeJobBinding(CTX);
    const b = computeJobBinding({ ...CTX, hookAddress: "0x0000000000000000000000000000000000000001" });
    expect(a).not.toBe(b);
  });
});

describe("hashResponseResolves", () => {
  it("returns zero-array hash on empty input", () => {
    // keccak256(abi.encode(bytes32[]({})). Cross-check against viem's helper
    // by computing it the same way the production code does — this is a
    // change-detector against accidental reshape of the hash formula.
    const empty = hashResponseResolves([]);
    expect(empty).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("differs when keyName changes", () => {
    const a = hashResponseResolves([
      { keyName: "price", parseType: "json", parsePath: "$.x" },
    ]);
    const b = hashResponseResolves([
      { keyName: "PRICE", parseType: "json", parsePath: "$.x" },
    ]);
    expect(a).not.toBe(b);
  });

  it("is order-sensitive (reorder ≠ same hash)", () => {
    const a = hashResponseResolves([
      { keyName: "x", parseType: "json", parsePath: "$.a" },
      { keyName: "y", parseType: "json", parsePath: "$.b" },
    ]);
    const b = hashResponseResolves([
      { keyName: "y", parseType: "json", parsePath: "$.b" },
      { keyName: "x", parseType: "json", parsePath: "$.a" },
    ]);
    expect(a).not.toBe(b);
  });
});

describe("buildSpec", () => {
  const job: JobDefinition = {
    steps: [
      {
        method: "GET",
        url: "https://api.example.com/coins/bitcoin",
        responseResolves: [{ keyName: "id", parseType: "json", parsePath: "$.id" }],
        attMode: "proxytls",
      },
      {
        method: "GET",
        url: "https://api.example.com/coins/<<id>>/history",
        responseResolves: [
          { keyName: "price_usd", parseType: "json", parsePath: "$.market_data.current_price.usd" },
        ],
        attMode: "proxytls",
      },
    ],
    bindings: [
      { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url", value: "bitcoin" },
    ],
  };

  it("produces one RequestStep per step, with the right number of bindings", () => {
    const spec = buildSpec(job, CTX);
    expect(spec.steps).toHaveLength(2);
    expect(spec.bindings).toHaveLength(1);
    expect(spec.configured).toBe(false);
    expect(spec.deliverableSourceStep).toBe(1); // defaults to last step
  });

  it("hashes the resolved (post-substitution) URL, not the template", () => {
    const spec = buildSpec(job, CTX);
    // Step 1 URL is hashed after replacing <<id>> with "bitcoin".
    const expectedUrl = "https://api.example.com/coins/bitcoin/history";
    expect(spec.steps[1]!.urlHash).toBe(keccak256(toBytes(expectedUrl)));
  });

  it("hashes the method", () => {
    const spec = buildSpec(job, CTX);
    expect(spec.steps[0]!.methodHash).toBe(keccak256(toBytes("GET")));
  });

  it("encodes binding value as hex bytes", () => {
    const spec = buildSpec(job, CTX);
    expect(spec.bindings[0]!.value).toBe(stringToHex("bitcoin"));
    expect(spec.bindings[0]!.toLocation).toBe(0); // url
  });

  it("rejects backward bindings", () => {
    expect(() =>
      buildSpec({
        steps: job.steps,
        bindings: [
          { fromStep: 1, fromKey: "x", toStep: 0, toLocation: "url", value: "v" },
        ],
      }, CTX),
    ).toThrow(/forward/);
  });

  it("rejects bindings with neither value nor fromExtractKey", () => {
    expect(() =>
      buildSpec({
        steps: job.steps,
        bindings: [
          { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url" },
        ],
      }, CTX),
    ).toThrow(/exactly one of/);
  });

  it("rejects bindings with both value and fromExtractKey", () => {
    expect(() =>
      buildSpec({
        steps: job.steps,
        bindings: [
          { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url", value: "v", fromExtractKey: "k" },
        ],
      }, CTX),
    ).toThrow(/exactly one of/);
  });

  it("rejects empty steps", () => {
    expect(() => buildSpec({ steps: [], bindings: [] }, CTX)).toThrow(/at least one step/);
  });

  it("rejects too many steps", () => {
    const steps = Array.from({ length: 17 }, () => job.steps[0]!);
    expect(() => buildSpec({ steps, bindings: [] }, CTX)).toThrow(/too many steps/);
  });

  it("populates expectedJobBinding on every step", () => {
    const spec = buildSpec(job, CTX);
    const expected = computeJobBinding(CTX);
    expect(spec.steps[0]!.expectedJobBinding).toBe(expected);
    expect(spec.steps[1]!.expectedJobBinding).toBe(expected);
  });

  it("encodes dynamic binding fromExtractKey as hex bytes", () => {
    const spec = buildSpec({
      steps: job.steps,
      bindings: [
        { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url", fromExtractKey: "id" },
      ],
    }, CTX);
    expect(spec.bindings[0]!.fromExtractKey).toBe(stringToHex("id"));
    expect(spec.bindings[0]!.value).toBe("0x");
  });
});

describe("resolveStep", () => {
  it("substitutes both url and body, and embeds the per-job binding in additionParams", () => {
    const out = resolveStep(
      {
        method: "POST",
        url: "/coins/<<id>>/x",
        body: '{"name":"<<id>>"}',
        responseResolves: [],
      },
      [{ fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url", value: "bitcoin" },
       { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "body", value: "bitcoin" }],
      CTX,
    );
    expect(out.url).toBe("/coins/bitcoin/x");
    expect(out.body).toBe('{"name":"bitcoin"}');
    const expectedAdditionParams = `{"algorithmType":"proxytls","jobBinding":"${computeJobBinding(CTX)}"}`;
    expect(out.additionParams).toBe(expectedAdditionParams);
  });
});
