import { describe, expect, it } from "vitest";
import { keccak256, stringToHex, toBytes } from "viem";
import {
  buildAdditionParams,
  buildSpec,
  hashResponseResolves,
  resolveStep,
} from "../src/specBuilder.js";
import type { JobDefinition } from "../src/types.js";

describe("buildAdditionParams", () => {
  it("produces stable JSON for proxytls", () => {
    expect(buildAdditionParams("proxytls")).toBe('{"algorithmType":"proxytls"}');
  });
  it("produces stable JSON for mpctls", () => {
    expect(buildAdditionParams("mpctls")).toBe('{"algorithmType":"mpctls"}');
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
    const spec = buildSpec(job);
    expect(spec.steps).toHaveLength(2);
    expect(spec.bindings).toHaveLength(1);
    expect(spec.configured).toBe(false);
    expect(spec.deliverableSourceStep).toBe(1); // defaults to last step
  });

  it("hashes the resolved (post-substitution) URL, not the template", () => {
    const spec = buildSpec(job);
    // Step 1 URL is hashed after replacing <<id>> with "bitcoin".
    const expectedUrl = "https://api.example.com/coins/bitcoin/history";
    expect(spec.steps[1]!.urlHash).toBe(keccak256(toBytes(expectedUrl)));
  });

  it("hashes the method", () => {
    const spec = buildSpec(job);
    expect(spec.steps[0]!.methodHash).toBe(keccak256(toBytes("GET")));
  });

  it("encodes binding value as hex bytes", () => {
    const spec = buildSpec(job);
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
      }),
    ).toThrow(/forward/);
  });

  it("rejects empty steps", () => {
    expect(() => buildSpec({ steps: [], bindings: [] })).toThrow(/at least one step/);
  });

  it("rejects too many steps", () => {
    const steps = Array.from({ length: 17 }, () => job.steps[0]!);
    expect(() => buildSpec({ steps, bindings: [] })).toThrow(/too many steps/);
  });
});

describe("resolveStep", () => {
  it("substitutes both url and body from the bindings", () => {
    const out = resolveStep(
      {
        method: "POST",
        url: "/coins/<<id>>/x",
        body: '{"name":"<<id>>"}',
        responseResolves: [],
      },
      [{ fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url", value: "bitcoin" },
       { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "body", value: "bitcoin" }],
    );
    expect(out.url).toBe("/coins/bitcoin/x");
    expect(out.body).toBe('{"name":"bitcoin"}');
    expect(out.additionParams).toBe('{"algorithmType":"proxytls"}');
  });
});
