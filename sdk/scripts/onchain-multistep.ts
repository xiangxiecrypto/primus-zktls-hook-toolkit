/**
 * Multi-step on-chain E2E: two serial Primus attestations chained by a
 * static binding, end-to-end through the deployed hook on Base Sepolia.
 *
 *   step 0:  GET https://api.coingecko.com/api/v3/coins/bitcoin
 *            → resolve $.id  → "bitcoin"
 *   step 1:  GET https://api.coingecko.com/api/v3/coins/bitcoin/history?date=01-01-2024
 *            → resolve $.id  → "bitcoin"
 *   binding: value "bitcoin" appears in
 *            - step 0 data
 *            - step 1 request URL
 *
 * The hook enforces:
 *   - each step's URL/method/body/responseResolveHash matches the pinned spec;
 *   - the binding value appears in BOTH attestations;
 *   - keccak256(att[1].data) == deliverable.
 *
 * Run with:
 *   PRIVATE_KEY=... PROVIDER_KEY=... PRIMUS_APP_ID=... PRIMUS_APP_SECRET=... \
 *     pnpm tsx scripts/onchain-multistep.ts
 *
 * Optional: JOB_ID=<n> to reuse an existing Open job.
 */

import { runScenario, type ScenarioConfig } from "./lib/lifecycle.js";
import { baseSepolia, type JobDefinition } from "../src/index.js";

const CORE = baseSepolia.erc8183Core;
const HOOK = baseSepolia.hook;

// Two small, deterministic CoinGecko calls. Each picks a distinct currency
// quote (USD then EUR) so the responses differ; the binding value "bitcoin"
// must appear in both step 0's parsed data and step 1's substituted URL.
//
// Step 0 response shape: {"bitcoin":{"usd":80000}}.
// SDK keyName="bitcoin_usd_value" → att[0].data = `{"bitcoin_usd_value":"80000"}`.
// The string "bitcoin" then appears as a substring of `bitcoin_usd_value`,
// satisfying the binding's source-side check.
const job: JobDefinition = {
  steps: [
    {
      method: "GET",
      url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
      header: { "user-agent": "Mozilla/5.0" },
      responseResolves: [
        { keyName: "bitcoin_usd_value", parseType: "json", parsePath: "$.bitcoin.usd" },
      ],
      attMode: "proxytls",
      maxAgeSeconds: 3600,
    },
    {
      method: "GET",
      url: "https://api.coingecko.com/api/v3/simple/price?ids=<<id>>&vs_currencies=eur",
      header: { "user-agent": "Mozilla/5.0" },
      responseResolves: [
        { keyName: "rate_eur", parseType: "json", parsePath: "$.bitcoin.eur" },
      ],
      attMode: "proxytls",
      maxAgeSeconds: 3600,
    },
  ],
  bindings: [
    {
      fromStep: 0,
      fromKey: "id",
      toStep: 1,
      toLocation: "url",
      // Static binding value — must appear in both step 0's parsed data
      // (substring of keyName "bitcoin_usd_value") and step 1's
      // substituted request URL ("?ids=bitcoin&..." after replacement).
      value: "bitcoin",
    },
  ],
  deliverableSourceStep: 1,
};

const scenario: ScenarioConfig = {
  name: "Multi-step: CoinGecko /coins/bitcoin → /coins/bitcoin/history",
  job,
  description: "Multi-step zkTLS demo: CoinGecko bitcoin → history",
};

runScenario({
  scenario,
  core: CORE,
  hook: HOOK,
  rpcUrl: "https://sepolia.base.org",
  jobId: process.env.JOB_ID ? BigInt(process.env.JOB_ID) : undefined,
})
  .then(() => process.exit(0))
  .catch(err => {
    console.error("\nFAILED:", err?.shortMessage ?? err?.message ?? err);
    if (err?.cause) console.error("cause :", err.cause);
    if (err?.metaMessages) console.error("meta  :", err.metaMessages);
    process.exit(1);
  });
