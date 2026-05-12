/**
 * Generate a REAL signed attestation via Primus SaaS and dump bytes for the
 * end-to-end fork test (test/fork/RealAttestationE2E.t.sol).
 *
 * Requires PRIMUS_APP_ID and PRIMUS_APP_SECRET in env. Credentials are
 * never written to disk; only the resulting Attestation (which includes
 * the Primus attestor's public signature, by design) is persisted.
 *
 * Run with:
 *   PRIMUS_APP_ID=0x... PRIMUS_APP_SECRET=0x... pnpm tsx scripts/generate-real-fixture.ts
 *
 * Output (under <toolkit-root>/test/fixtures/, .gitignored):
 *   real-fund.hex           - ABI-encoded AttestationSpec  (fund optParams)
 *   real-submit.hex         - ABI-encoded (Attestation[], bytes) (submit optParams)
 *   real-deliverable.hex    - keccak256(att.data)
 *   real-fixture.json       - human-readable summary
 *
 * Target API: CoinGecko's public simple-price endpoint. Single step,
 * no cross-step binding — keeps the failure surface narrow so any
 * E2E failure is easy to localise.
 */

import { writeFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { PrimusCoreTLS } from "@primuslabs/zktls-core-sdk";
import { runJob } from "../src/runJob.js";
import { buildSpec } from "../src/specBuilder.js";
import { encodeFundOptParams } from "../src/encoding.js";
import { createPrimusAttestor } from "../src/primusAdapter.js";
import type { JobDefinition } from "../src/types.js";

const PROVIDER = "0x000000000000000000000000000000000000b0b1" as const;

const job: JobDefinition = {
  steps: [
    {
      method: "GET",
      url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
      header: { "user-agent": "Mozilla/5.0" },
      responseResolves: [
        { keyName: "btc_usd", parseType: "json", parsePath: "$.bitcoin.usd" },
      ],
      attMode: "proxytls",
      maxAgeSeconds: 3600,
    },
  ],
  bindings: [],
};

async function main() {
  const appId = process.env.PRIMUS_APP_ID;
  const appSecret = process.env.PRIMUS_APP_SECRET;
  if (!appId || !appSecret) {
    console.error("Missing PRIMUS_APP_ID or PRIMUS_APP_SECRET in env.");
    process.exit(2);
  }

  console.log("Initializing PrimusCoreTLS...");
  const primus = new PrimusCoreTLS();
  // The Primus SDK accepts ("auto" | "wasm" | "native"). "auto" tries
  // native first, falls back to wasm — same default the SDK docs use.
  // Type definition in @primuslabs/zktls-core-sdk@0.1.1 is narrower than
  // the runtime accepts, so we cast.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  await primus.init(appId, appSecret, "auto" as any);

  console.log("Building spec...");
  const spec = buildSpec(job);
  const fundOptParams = encodeFundOptParams(spec);

  console.log("Calling Primus SaaS to attest CoinGecko BTC/USD...");
  const attestor = createPrimusAttestor(primus);
  const { attestations, deliverable, submitOptParams } = await runJob(job, {
    recipient: PROVIDER,
    attestor,
  });

  const att = attestations[0]!;

  console.log("Attestation received:");
  console.log("  url            :", att.request.url);
  console.log("  data           :", att.data);
  console.log("  timestamp      :", att.timestamp.toString());
  console.log("  attestor       :", att.attestors[0]?.attestorAddr);
  console.log("  signature[0]   :", att.signatures[0]?.slice(0, 20), "...");
  console.log("  recipient      :", att.recipient);

  const fixturesDir = resolve(import.meta.dirname, "../../test/fixtures");
  mkdirSync(fixturesDir, { recursive: true });
  writeFileSync(`${fixturesDir}/real-fund.hex`, fundOptParams);
  writeFileSync(`${fixturesDir}/real-submit.hex`, submitOptParams);
  writeFileSync(`${fixturesDir}/real-deliverable.hex`, deliverable);
  writeFileSync(
    `${fixturesDir}/real-fixture.json`,
    JSON.stringify(
      {
        provider: PROVIDER,
        job,
        attestation: {
          url: att.request.url,
          method: att.request.method,
          data: att.data,
          timestamp: att.timestamp.toString(),
          attestor: att.attestors[0]?.attestorAddr,
          recipient: att.recipient,
        },
        deliverable,
      },
      (_k, v) => (typeof v === "bigint" ? v.toString() : v),
      2,
    ),
  );

  console.log("");
  console.log("wrote real fixture to", fixturesDir);
  console.log("  real-fund.hex        :", fundOptParams.length, "chars");
  console.log("  real-submit.hex      :", submitOptParams.length, "chars");
  console.log("  real-deliverable.hex :", deliverable);

  // Some Primus SDK builds spawn background workers; explicit exit avoids
  // the process hanging after attestation completes.
  process.exit(0);
}

main().catch(err => {
  console.error("Failed:", err?.message ?? err);
  console.error(err);
  process.exit(1);
});
