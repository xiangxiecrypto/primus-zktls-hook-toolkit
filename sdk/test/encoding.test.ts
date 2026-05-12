import { describe, expect, it } from "vitest";
import { decodeAbiParameters, keccak256, parseAbiParameters, toBytes } from "viem";
import {
  computeDeliverable,
  encodeFundOptParams,
  encodeSubmitOptParams,
} from "../src/encoding.js";
import type { Attestation, AttestationSpec } from "../src/types.js";

const sampleAtt: Attestation = {
  recipient: "0x000000000000000000000000000000000000b0b1",
  request: { url: "https://x", header: "", method: "GET", body: "" },
  reponseResolve: [{ keyName: "price", parseType: "json", parsePath: "$.p" }],
  data: '{"price":42}',
  attConditions: "",
  timestamp: 1700000000000n, // ms (Primus convention)
  additionParams: '{"algorithmType":"proxytls"}',
  attestors: [],
  signatures: [],
};

describe("encodeSubmitOptParams", () => {
  it("round-trips through ABI decode", () => {
    const encoded = encodeSubmitOptParams([sampleAtt], "0xdeadbeef");
    const params = parseAbiParameters(
      "(address,(string,string,string,string),(string,string,string)[],string,string,uint64,string,(address,string)[],bytes[])[] atts, bytes customCalldata",
    );
    const [decoded, custom] = decodeAbiParameters(params, encoded) as [
      unknown[],
      string,
    ];
    expect(decoded).toHaveLength(1);
    expect(custom).toBe("0xdeadbeef");
  });

  it("defaults customCalldata to 0x", () => {
    const encoded = encodeSubmitOptParams([sampleAtt]);
    expect(encoded.startsWith("0x")).toBe(true);
    expect(encoded.length).toBeGreaterThan(2);
  });
});

describe("encodeFundOptParams", () => {
  it("emits non-empty hex for a minimal spec", () => {
    const spec: AttestationSpec = {
      steps: [
        {
          methodHash: keccak256(toBytes("GET")),
          urlHash: keccak256(toBytes("https://x")),
          bodyHash: keccak256(toBytes("")),
          responseResolveHash: keccak256(toBytes("")),
          additionParamsHash: keccak256(toBytes('{"algorithmType":"proxytls"}')),
          maxAge: 300n,
          pinnedAttestor: "0x0000000000000000000000000000000000000000",
        },
      ],
      bindings: [],
      deliverableSourceStep: 0,
      customVerifier: "0x0000000000000000000000000000000000000000",
      configured: false,
    };
    const encoded = encodeFundOptParams(spec);
    expect(encoded.startsWith("0x")).toBe(true);
    expect(encoded.length).toBeGreaterThan(2);
  });
});

describe("computeDeliverable", () => {
  it("hashes the source step's data bytes", () => {
    const d = computeDeliverable([sampleAtt], 0);
    expect(d).toBe(keccak256(toBytes(sampleAtt.data)));
  });
  it("defaults to last step", () => {
    const first: Attestation = { ...sampleAtt, data: "first" };
    const last: Attestation = { ...sampleAtt, data: "last" };
    expect(computeDeliverable([first, last])).toBe(keccak256(toBytes("last")));
  });
});
