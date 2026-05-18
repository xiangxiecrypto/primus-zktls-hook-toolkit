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

// Two CoinGecko calls bridged by the static value "bitcoin".
//
// v2 NOTE: the hook uses _containsBounded, requiring matches to be bracketed
// by `" , } : & = /`. Step 0 must therefore produce parsed data where
// "bitcoin" is itself a quote-delimited JSON value (not part of a longer
// identifier like "bitcoin_usd_value"). We resolve `$[0].id` from
// /coins/markets, which yields att.data = {"coin_id":"bitcoin"} — the
// `"bitcoin"` substring is properly bracketed by `"` on both sides.
// Step 1's URL has the value bracketed by `=` and `&`.
const job: JobDefinition = {
  steps: [
    {
      method: "GET",
      url: "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=bitcoin&per_page=1",
      header: { "user-agent": "Mozilla/5.0" },
      responseResolves: [
        { keyName: "coin_id", parseType: "json", parsePath: "$[0].id" },
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
      // Step 0 data → {"coin_id":"bitcoin"} : "bitcoin" bounded by `"`/`"`
      // Step 1 URL → ?ids=bitcoin&... : "bitcoin" bounded by `=`/`&`
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
