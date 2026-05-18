/**
 * LLM on-chain E2E: CoinGecko price fetch → OpenAI-compatible LLM call.
 *
 *   step 0:  GET CoinGecko BTC/USD  → att[0].data = {"bitcoin_usd_value":"80724"}
 *   step 1:  POST {LLM_URL}/chat/completions  with the BTC quote embedded
 *            in the user prompt; resolve the LLM response from
 *            $.choices[0].message.content
 *   binding: "bitcoin" appears in both att[0].data and att[1].request.body
 *
 * Authentication: the LLM_API_KEY is passed via the request `Authorization`
 * header. Primus strips request headers from the on-chain attestation
 * (verified empirically — header field comes back empty), so the bearer
 * token does NOT land on chain.
 *
 * Required env:
 *   PRIVATE_KEY        - deployer/client/evaluator
 *   PROVIDER_KEY       - provider role
 *   PRIMUS_APP_ID
 *   PRIMUS_APP_SECRET
 *   LLM_URL            - chat-completions endpoint (e.g. https://api.groq.com/openai/v1)
 *   LLM_MODEL          - model name (e.g. "llama-3.1-8b-instant")
 *   LLM_API_KEY        - bearer token for the LLM provider
 *
 * Optional: JOB_ID=<n> to reuse an existing Open job.
 *
 * Why OpenAI-compatible: most providers (Groq / OpenRouter / DeepSeek /
 * OpenAI proper) expose the same `/chat/completions` shape, so the same
 * spec works across them by just swapping LLM_URL / LLM_MODEL / LLM_API_KEY.
 * Anthropic's `/messages` API has a different schema and is NOT compatible
 * with this scenario as written.
 */

import { runScenario, type ScenarioConfig } from "./lib/lifecycle.js";
import { baseSepolia, type JobDefinition } from "../src/index.js";

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

const llmUrl = req("LLM_URL").replace(/\/$/, ""); // strip trailing slash
const llmModel = req("LLM_MODEL");
const llmKey = req("LLM_API_KEY");

// Body sent to the LLM. The user message content IS just `<<id>>` so after
// substitution it becomes the JSON literal `"bitcoin"` — bounded by `"` on
// both sides, which v2's _containsBounded requires.
//
// The system message carries the actual instruction; the user message is
// the bridging value.
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
      // /coins/markets returns [{"id":"bitcoin","symbol":"btc",...}] —
      // small payload Primus handles reliably and yields a quote-delimited
      // "bitcoin" once we extract $[0].id.
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
        {
          keyName: "answer",
          parseType: "json",
          parsePath: "$.choices[0].message.content",
        },
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
      // Step 0 data → {"coin_id":"bitcoin"}        : bounded by `"`
      // Step 1 body→ ...,"content":"bitcoin"},...  : bounded by `"`
      value: "bitcoin",
    },
  ],
  deliverableSourceStep: 1,
};

const scenario: ScenarioConfig = {
  name: `LLM scenario: CoinGecko → ${llmUrl} (${llmModel})`,
  job,
  description: "LLM zkTLS demo: CoinGecko price → LLM summary",
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
