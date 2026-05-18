/**
 * On-chain E2E with a customVerifier on the extension layer.
 *
 * Same CoinGecko → DeepSeek pipeline as `onchain-llm.ts`, but the spec's
 * `customVerifier` field now points at the deployed
 * `LLMAnswerLengthVerifier` (Base Sepolia
 * 0x1145636e77f107212dd3c76b0d43ec53dcc5e393). The hook will staticcall
 * that verifier after every generic check passes; if the LLM answer's byte
 * length is outside the deployed [minBytes, maxBytes] band, the submit
 * transaction reverts with ExtensionVerifierFailed.
 *
 * Two run modes, controlled by env:
 *
 *   1. happy path (default):
 *        VERIFIER_ADDR=0x1145636e77f107212dd3c76b0d43ec53dcc5e393
 *        → uses the originally-deployed verifier (min=20, max=800)
 *        → the typical DeepSeek one-sentence reply lands in-band → passes.
 *
 *   2. failing path:
 *        Deploy a SECOND verifier with tight bounds (e.g. max=10) and pass
 *        its address via VERIFIER_ADDR. The same DeepSeek reply will exceed
 *        the cap and submit() will revert.
 */

import { runScenario, type ScenarioConfig } from "./lib/lifecycle.js";
import { baseSepolia, type Address, type JobDefinition } from "../src/index.js";

const CORE = baseSepolia.erc8183Core;
const HOOK = baseSepolia.hook;

function req(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required env: ${name}`);
    process.exit(2);
  }
  return v;
}

const llmUrl = req("LLM_URL").replace(/\/$/, "");
const llmModel = req("LLM_MODEL");
const llmKey = req("LLM_API_KEY");
const verifierAddr = (process.env.VERIFIER_ADDR ??
  baseSepolia.llmAnswerLengthVerifier_loose) as Address;

// Same v2 bounded-substring shape as onchain-llm.ts: user content is just
// `<<id>>` so it lands as a quote-delimited JSON value; step 0 extracts
// $[0].id from /coins/markets so the parsed data carries "bitcoin" between
// quotes.
const llmBody = JSON.stringify({
  model: llmModel,
  messages: [
    { role: "system", content: "The user message is a cryptocurrency name. Reply with one quirky fact about it in one short sentence." },
    { role: "user", content: "<<id>>" },
  ],
  temperature: 0,
});

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
      method: "POST",
      url: `${llmUrl}/chat/completions`,
      header: {
        "user-agent": "Mozilla/5.0",
        "content-type": "application/json",
        authorization: `Bearer ${llmKey}`,
      },
      body: llmBody,
      responseResolves: [
        { keyName: "answer", parseType: "json", parsePath: "$.choices[0].message.content" },
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
      toLocation: "body",
      value: "bitcoin",
    },
  ],
  deliverableSourceStep: 1,
  // Extension verifier: the hook will staticcall this after all generic
  // checks pass. The verifier extracts att[1].data's "answer" field and
  // enforces byte length ∈ [minBytes, maxBytes].
  customVerifier: verifierAddr,
};

const scenario: ScenarioConfig = {
  name: `LLM + customVerifier (${verifierAddr}): CoinGecko → ${llmUrl}`,
  job,
  description: "LLM zkTLS demo with customVerifier on answer length",
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
