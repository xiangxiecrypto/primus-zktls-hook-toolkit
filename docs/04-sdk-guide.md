# 4. SDK guide

> **Audience.** Anyone integrating this toolkit into their application. You
> have read [01](01-introduction.md), [02](02-architecture.md),
> [03](03-onchain-flow.md) and understand what data has to land on chain at
> each step; now you want to know how to produce that data from TypeScript.

The SDK is in `sdk/` and exports under the package name
`@primus-zktls/hook-sdk`. The TypeScript surface is small (~10 functions)
but each function has a precise role in the on-chain protocol. This guide
goes function by function with copy-pastable examples.

---

## 4.1 Installation

```bash
pnpm add @primus-zktls/hook-sdk viem
# only needed on the provider side:
pnpm add @primuslabs/zktls-core-sdk
```

The SDK has one hard runtime dep (`viem`) and one **optional** peer
(`@primuslabs/zktls-core-sdk`). Client-side code that only builds and
encodes specs doesn't need the Primus SDK at all — only the provider needs
it to actually drive Primus's attestor service.

---

## 4.2 Mental model

There are three computations the SDK does and one external call it makes:

1. **`buildSpec(job)`** — turn a developer-friendly `JobDefinition` into
   the on-chain `AttestationSpec`. Pure function, no network. Runs on the
   **client side** to produce the bytes that go into `fund()`.

2. **`runJob(job, opts)`** — drive Primus to produce one signed
   `Attestation` per step, then ABI-encode them. Runs on the **provider
   side**. Makes external calls to Primus's SaaS via the
   `@primuslabs/zktls-core-sdk` adapter.

3. **`encodeFundOptParams(spec)` / `encodeSubmitOptParams(atts, custom)`**
   — pure ABI-encoding helpers. Both sides use these to produce the
   `bytes` that ERC-8183's `fund` and `submit` accept.

4. **`computeDeliverable(atts, sourceStep?)`** — reproduce the `bytes32`
   the hook expects. The provider needs this to call `submit`.

In the rest of this guide we follow the data, top to bottom:

```
client side:
    JobDefinition  ──buildSpec──►  AttestationSpec  ──encodeFundOptParams──►  bytes
                                                                                │
                                                                  fund(jobId, 0, bytes)
                                                                                ▼
                                                                            on chain
provider side:
    JobDefinition  ──runJob──►  Attestation[]  ──encodeSubmitOptParams──►  bytes
                                       │                                       │
                                       ├─computeDeliverable─►  bytes32         │
                                                                               ▼
                                                              submit(jobId, deliverable, bytes)
```

---

## 4.3 Defining a job

Everything starts with a `JobDefinition`. This is the SDK's
developer-friendly representation of "what is the provider supposed to
do?". It is **not** the on-chain spec — `buildSpec` lowers it to that
form. You write the JobDefinition once, and both sides (client building
spec, provider running steps) consume it.

### 4.3.1 Single-step example

The simplest possible job: fetch the BTC/USD price.

```ts
import type { JobDefinition } from "@primus-zktls/hook-sdk";

const job: JobDefinition = {
  steps: [
    {
      method: "GET",
      url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
      header: { "user-agent": "Mozilla/5.0" },
      responseResolves: [
        // key under which Primus stores the extracted field
        { keyName: "btc_usd", parseType: "json", parsePath: "$.bitcoin.usd" },
      ],
      attMode: "proxytls",         // default; alternative: "mpctls"
      maxAgeSeconds: 3600,         // attestation must be ≤ 1h old at submit
    },
  ],
  bindings: [],
};
```

### 4.3.2 Multi-step with a static binding

A two-step pipeline where the value `"bitcoin"` flows from step 0's parsed
data into step 1's URL:

```ts
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
    },
    {
      method: "GET",
      url: "https://api.coingecko.com/api/v3/simple/price?ids=<<id>>&vs_currencies=eur",
      //                                                          ^^^^^^^^
      // `<<id>>` is a placeholder. The SDK substitutes the binding value
      // ("bitcoin") here BEFORE hashing for the spec, so the spec's URL
      // hash matches the URL Primus will eventually attest.
      header: { "user-agent": "Mozilla/5.0" },
      responseResolves: [
        { keyName: "rate_eur", parseType: "json", parsePath: "$.bitcoin.eur" },
      ],
      attMode: "proxytls",
    },
  ],
  bindings: [
    {
      fromStep: 0,
      fromKey: "id",        // logical name; can match a keyName or be arbitrary
      toStep: 1,
      toLocation: "url",    // where in step 1 the value lands (url|header|body)
      value: "bitcoin",     // the static byte string the hook will verify is in both atts
    },
  ],
  deliverableSourceStep: 1, // optional; defaults to last step
};
```

Three rules for bindings:

1. **`fromStep < toStep`.** Forward only; data can flow only in lifecycle
   order.
2. **`value` is static.** The client and provider both know it at spec
   time. Dynamic values (e.g. one-time tokens) need a `customVerifier`
   instead — the hook itself cannot bind values it didn't know in advance.
3. **`value` must appear as a substring in both `att[fromStep].data` and
   `att[toStep].request.<location>`.** The SDK arranges this via placeholder
   substitution + Primus's parsed data; the hook validates via
   `_contains()`.

### 4.3.3 With LLM step and customVerifier

```ts
const llmBody = JSON.stringify({
  model: "deepseek-chat",
  messages: [
    { role: "system", content: "Reply in one short sentence." },
    { role: "user", content: "Name one quirky fact about <<id>>." },
  ],
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
    },
    {
      method: "POST",
      url: "https://api.deepseek.com/v1/chat/completions",
      header: {
        "user-agent": "Mozilla/5.0",
        "content-type": "application/json",
        // The Authorization header lives in the OUTGOING request. Primus
        // strips it from the signed attestation (we verified empirically
        // — see docs/08-troubleshooting.md §"parseType / header normalisation"),
        // so the bearer token does NOT land on chain.
        authorization: `Bearer ${process.env.LLM_API_KEY}`,
      },
      body: llmBody,
      responseResolves: [
        { keyName: "answer", parseType: "json", parsePath: "$.choices[0].message.content" },
      ],
      attMode: "proxytls",
    },
  ],
  bindings: [
    {
      fromStep: 0,
      fromKey: "id",
      toStep: 1,
      toLocation: "body",                  // <<id>> is inside the JSON body
      value: "bitcoin",
    },
  ],
  deliverableSourceStep: 1,
  customVerifier: "0x1145636e77f107212dd3c76b0d43ec53dcc5e393",  // optional
};
```

The placeholder substitution for `body` is **JSON-aware**: the SDK runs
`JSON.stringify(value).slice(1, -1)` so quotes/backslashes/newlines inside
the value get the right JSON escaping. This matters for LLM use cases
because dynamic prompts often contain those characters.

---

## 4.4 Client side: building & encoding the spec

The client takes the `JobDefinition` and produces two artifacts:

```ts
import { buildSpec, encodeFundOptParams } from "@primus-zktls/hook-sdk";

const spec = buildSpec(job);             // AttestationSpec (Solidity-shaped object)
const fundOptParams = encodeFundOptParams(spec);  // Hex bytes for fund()
```

That's it. Now the client can call `ERC8183.fund(jobId, 0, fundOptParams)`.

### What `buildSpec` actually does

For each step in `job.steps`:

1. **Resolves placeholders.** Substitutes `<<key>>` in the URL and body
   with the binding values. Uses per-location escaping (percent-encode for
   URL, JSON-aware for body).
2. **Hashes every pinned field:**
   - `methodHash = keccak256(method)`
   - `urlHash = keccak256(resolvedUrl)`
   - `bodyHash = keccak256(resolvedBody)`
   - `responseResolveHash = keccak256(encodeAbiParameters(...))` — using the
     **Primus normalisation** of `parseType = ""` (see §4.10).
   - `additionParamsHash = keccak256('{"algorithmType":"…"}')`
3. **Stores the deliverable source step** (default: last step).
4. **Hex-encodes binding values** as `0x…` and records the binding
   metadata.
5. **Records the customVerifier address** (or `0x0` if none).

The output struct mirrors `AttestationSpec` field-for-field. Then
`encodeFundOptParams` ABI-encodes that struct.

### A common gotcha: identical specs produce identical bytes

`buildSpec` is deterministic. Two clients that write the same
`JobDefinition` produce byte-identical `fundOptParams`, so a stable hash
of these bytes is a useful "spec ID" for indexers.

---

## 4.5 Provider side: running the job

The provider needs `@primuslabs/zktls-core-sdk` *and* this SDK's
`runJob`. They wire together like this:

```ts
import { PrimusCoreTLS } from "@primuslabs/zktls-core-sdk";
import { runJob, createPrimusAttestor } from "@primus-zktls/hook-sdk";

const primus = new PrimusCoreTLS();
await primus.init(
  process.env.PRIMUS_APP_ID!,
  process.env.PRIMUS_APP_SECRET!,
  "auto",                                  // "auto" picks native/wasm at runtime
);

const result = await runJob(job, {
  recipient: providerAddress,              // baked into att.recipient
  attestor: createPrimusAttestor(primus),  // swap-out point — see §4.9
});

// result has:
//   attestations:    Attestation[]                 // one per step
//   deliverable:     `0x${string}` (bytes32)       // ready for submit
//   submitOptParams: `0x${string}` (bytes)         // ready for submit
```

What `runJob` does:

1. For each step in `job.steps`:
   - Resolves placeholders against bindings → real URL and body.
   - Invokes the supplied `attestor(input)` with the resolved request
     shape. (`createPrimusAttestor(primus)` routes this through the Primus
     SaaS.)
   - **Sanity-checks** the returned `Attestation`: URL matches the resolved
     URL, method matches, additionParams matches. A misbehaving attestor
     cannot smuggle in a different request shape.
2. Computes the deliverable: `keccak256(atts[sourceStep].data)`.
3. ABI-encodes `(atts, customCalldata)` as `submitOptParams`.

The output is everything the provider needs to call `submit`:

```ts
await erc8183.submit(jobId, result.deliverable, result.submitOptParams);
```

### Retries and transient errors

Primus's SaaS occasionally returns `"Unstable internet connection. Please
try again."` errors. `runJob` itself does **not** retry — give it your own
retry policy or use the one we ship with the demo lifecycle (`scripts/lib/lifecycle.ts`,
which wraps `runJob` in a 4-attempt exponential backoff).

---

## 4.6 Encoding helpers in depth

### `encodeFundOptParams(spec): Hex`

Wraps `encodeAbiParameters` against the canonical `AttestationSpec` tuple
ABI string. The output is the exact bytes the hook's `_postFund` will
`abi.decode` back into the struct.

### `encodeSubmitOptParams(atts, customCalldata = "0x"): Hex`

Wraps `encodeAbiParameters` against `(Attestation[], bytes)`. The
`customCalldata` parameter is opaque — it's forwarded verbatim to the
`customVerifier` if one is configured, and ignored otherwise. Typical
usage:

```ts
// no customVerifier or it needs no extra data
encodeSubmitOptParams(atts);

// customVerifier reads e.g. an oracle reference id
encodeSubmitOptParams(atts, "0x" + oracleId.toString(16).padStart(64, "0"));
```

### `computeDeliverable(atts, sourceStep?): Hex`

```ts
const deliverable = computeDeliverable(result.attestations);
// or, if your spec sets a non-default sourceStep:
const deliverable = computeDeliverable(result.attestations, 0);
```

This is `keccak256(toBytes(atts[sourceStep].data))`. It must match exactly
what `submit`'s `deliverable` parameter is set to, or the hook reverts
`DeliverableMismatch`. `runJob` already returns this in `result.deliverable`,
so you only need `computeDeliverable` if you're submitting attestations
without going through `runJob`.

---

## 4.7 Live demo: full lifecycle in 60 lines

This is the actual code that powers `scripts/onchain-llm.ts`. It runs
against the deployed contracts on Base Sepolia.

```ts
import {
  createPublicClient, createWalletClient, http,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { PrimusCoreTLS } from "@primuslabs/zktls-core-sdk";

import {
  runJob, createPrimusAttestor, buildSpec,
  encodeFundOptParams,
  baseSepolia as deployment,            // pinned Base Sepolia addresses
} from "@primus-zktls/hook-sdk";

const job = { /* JobDefinition from §4.3 */ };

const deployer = privateKeyToAccount(process.env.PRIVATE_KEY! as `0x${string}`);
const provider = privateKeyToAccount(process.env.PROVIDER_KEY! as `0x${string}`);
const transport = http(deployment.rpcUrl);
const pub = createPublicClient({ chain: baseSepolia, transport });
const clientWallet = createWalletClient({ account: deployer, chain: baseSepolia, transport });
const providerWallet = createWalletClient({ account: provider, chain: baseSepolia, transport });

// 1) createJob — client
const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 24 * 3600);
const createTx = await clientWallet.writeContract({
  address: deployment.erc8183Core, abi: erc8183Abi, functionName: "createJob",
  args: [provider.address, deployer.address, Number(expiredAt), "demo",
         deployment.hook, 0n],
});
const receipt = await pub.waitForTransactionReceipt({ hash: createTx });
const log = receipt.logs.find(l => l.address.toLowerCase() === deployment.erc8183Core.toLowerCase())!;
const jobId = BigInt(log.topics[1]!);   // topic[1] is the indexed jobId

// 2) Primus does the work — provider
const primus = new PrimusCoreTLS();
await primus.init(process.env.PRIMUS_APP_ID!, process.env.PRIMUS_APP_SECRET!, "auto" as any);
const { deliverable, submitOptParams } = await runJob(job, {
  recipient: provider.address,
  attestor: createPrimusAttestor(primus),
});

// 3) fund (spec lands on chain) — client
const fundOptParams = encodeFundOptParams(buildSpec(job));
const fundTx = await clientWallet.writeContract({
  address: deployment.erc8183Core, abi: erc8183Abi, functionName: "fund",
  args: [jobId, 0n, fundOptParams],
});
await pub.waitForTransactionReceipt({ hash: fundTx, confirmations: 2 });

// 4) submit — provider
const submitTx = await providerWallet.writeContract({
  address: deployment.erc8183Core, abi: erc8183Abi, functionName: "submit",
  args: [jobId, deliverable, submitOptParams],
});
await pub.waitForTransactionReceipt({ hash: submitTx });

// 5) complete — evaluator (= deployer in this demo)
await clientWallet.writeContract({
  address: deployment.erc8183Core, abi: erc8183Abi, functionName: "complete",
  args: [jobId, "0x" + "00".repeat(32), "0x"],
});
```

Notes:

- **`confirmations: 2`** on the fund receipt is the empirical workaround
  for load-balanced public RPCs that occasionally serve stale state
  between the fund and submit (see [08-troubleshooting](08-troubleshooting.md)
  §"RPC consistency lag"). Skip it on private RPCs.
- The roles overlap: deployer plays admin + client + evaluator. This is
  not a protocol requirement — ERC-8183 just insists client ≠ provider.

---

## 4.8 The Attestation struct (TypeScript ↔ Solidity correspondence)

Knowing this table by heart will save you a debug session sooner or later.

| TS field | Solidity field | Note |
|---|---|---|
| `recipient` | `address recipient` | Provider's address, passed in at attestation request. |
| `request.url` | `string url` | Resolved URL after placeholder substitution. |
| `request.header` | `string header` | JSON-encoded headers. **Primus clears this on the signed attestation**, so the hook never has a useful value here. |
| `request.method` | `string method` | "GET" / "POST" etc. |
| `request.body` | `string body` | Request body string (often canonical JSON). |
| `reponseResolve[]` | `(string,string,string)[]` | **Typo `reponse` preserved** for ABI compatibility with deployed verifiers. Field order: `keyName, parseType, parsePath`. **Primus clears parseType on the signed attestation.** |
| `data` | `string data` | The extracted response in JSON form: `{"<keyName>": "<value>"}`. |
| `attConditions` | `string attConditions` | Carries the resolve operations as a JSON array. |
| `timestamp` | `uint64 timestamp` | **Milliseconds** since epoch. Hook divides by 1000 before comparing to `block.timestamp`. |
| `additionParams` | `string additionParams` | Canonical algorithm-type JSON, e.g. `{"algorithmType":"proxytls"}`. |
| `attestors[]` | `(address,string)[]` | Primus PADO list (currently length 1, address `0xdb73…8ef6`). |
| `signatures[]` | `bytes[]` | One 65-byte signature. |

If you ever need to construct an `Attestation` by hand (e.g. for tests
without Primus), keep `parseType` empty in `reponseResolve` and `timestamp`
in milliseconds — otherwise the hook's hashes won't match.

---

## 4.9 Replacing the attestor (vendor neutrality, from the TS side)

`runJob` doesn't know about Primus. It accepts any `AttestorFn`:

```ts
import type { AttestorFn, AttestorInput, Attestation } from "@primus-zktls/hook-sdk";

const myMockAttestor: AttestorFn = async (input: AttestorInput): Promise<Attestation> => {
  // do whatever — call your own attestor, return a synthetic Attestation
  return {
    recipient: input.recipient,
    request: {
      url: input.request.url,
      header: JSON.stringify(input.request.header),
      method: input.request.method,
      body: input.request.body,
    },
    reponseResolve: input.responseResolves.map(r => ({ ...r, parseType: "" })),
    data: "{}",
    attConditions: "",
    timestamp: BigInt(Date.now()),
    additionParams: input.additionParams,
    attestors: [],
    signatures: [],
  };
};

await runJob(job, { recipient: providerAddress, attestor: myMockAttestor });
```

This is how the SDK tests work without any Primus credentials. It's also
how you could plug in a different zkTLS vendor — just write an adapter
that produces attestations in the same struct shape.

`createPrimusAttestor(primus)` is the canonical Primus implementation; its
~30 lines are in `sdk/src/primusAdapter.ts` and are the only Primus-aware
code in the SDK.

---

## 4.10 The `parseType` quirk

You might notice the SDK clears `parseType` in `hashResponseResolves`:

```ts
// sdk/src/specBuilder.ts
const leaves = resolves.map(r =>
  keccak256(encodeAbiParameters(
    [{ type: "string" }, { type: "string" }, { type: "string" }],
    [r.keyName, "", r.parsePath],   // ← empty string, not r.parseType
  )),
);
```

This is on purpose. Primus's signed `Attestation` has `parseType` cleared
(empirically verified — it's consumed during off-chain parsing and not
preserved on chain). So the hook, when it recomputes the hash from the
attestation, would never see `parseType = "json"`. The SDK matches
Primus's behaviour so the spec's hash equals the hook's recomputed hash.

The developer-facing `JobDefinition` still accepts `parseType: "json"` —
Primus uses it off-chain to know how to parse the response. It's just the
on-chain hash that ignores it.

This is the most surprising design corner in the SDK. See
[08-troubleshooting](08-troubleshooting.md) for the full story.

---

## 4.11 Cross-validation guarantee

The SDK does not invent its own format. Every encoding it produces is
verified by a Solidity test that feeds SDK-generated bytes through the
real hook contract:

`test/integration/SdkCrossValidation.t.sol` reads
`test/fixtures/sdk-fund.hex`, `sdk-submit.hex`, `sdk-deliverable.hex` —
all generated by `sdk/scripts/dump-fixture.ts` — and pushes them into
the compiled hook. If any encoding ever drifts, that test fails.

To regenerate the fixture after changing the SDK or the hook:

```bash
cd sdk && pnpm tsx scripts/dump-fixture.ts
forge test --match-path 'test/integration/SdkCrossValidation*'
```

---

## 4.12 API surface reference

| Export | Pure? | Used by | Purpose |
|---|---|---|---|
| `buildSpec(job)` | yes | client | `JobDefinition → AttestationSpec` |
| `encodeFundOptParams(spec)` | yes | client | spec → bytes for `fund()` |
| `runJob(job, opts)` | no (calls attestor) | provider | drive all steps, return atts + deliverable + encoded submit bytes |
| `createPrimusAttestor(primus)` | no | provider | wrap `PrimusCoreTLS` into an `AttestorFn` |
| `encodeSubmitOptParams(atts, custom?)` | yes | provider | `(atts, custom)` → bytes for `submit()` |
| `computeDeliverable(atts, sourceStep?)` | yes | provider | reproduce hook's deliverable check |
| `applySubstitutions(template, subs, location)` | yes | both | `<<key>>` resolution with per-location escape |
| `extractPlaceholders(template)` | yes | both | list `<<key>>` keys in a string |
| `hashResponseResolves(resolves)` | yes | both | compute the on-chain responseResolveHash |
| `resolveStep(step, bindings)` | yes | both | resolve a single step's URL + body + additionParams |
| `baseSepolia` | const | both | pinned deployed addresses |
| `demoWallets` | const | testing | stable test addresses |

Continue to [05 — Deployed contracts](05-deployment.md) for the live
on-chain addresses and how to plug into them, or skip to
[06 — Testing](06-testing.md) for the test-running guide.
