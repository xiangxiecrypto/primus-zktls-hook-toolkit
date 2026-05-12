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

// Body sent to the LLM. <<id>> is substituted to "bitcoin" by the SDK from
// the binding. The user prompt deliberately phrases the LLM's task narrowly
// so the response is short and predictable; we are testing the attestation
// pipeline, not LLM quality.
const llmBody = JSON.stringify({
  model: llmModel,
  messages: [
    { role: "system", content: "Reply in one short sentence." },
    { role: "user", content: "Name one quirky fact about <<id>>." },
  ],
  // temperature: 0 helps reproducibility a bit, though LLMs aren't fully
  // deterministic. The hook doesn't check semantic content — only that the
  // request shape and response data flow match the pinned spec.
  temperature: 0,
});

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
      // Static binding value: "bitcoin" appears in step 0 data (substring
      // of keyName "bitcoin_usd_value") and in step 1's POST body (the
      // substituted <<id>> in the user prompt).
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
