# @primus-zktls/hook-sdk

TypeScript companion SDK for the
[`ZkTlsAttestationHook`](../contracts) ERC-8183 hook. Builds the
on-chain `AttestationSpec` a client must pass to `fund(...)`, drives the
provider's zkTLS attestation sequence via `@primuslabs/zktls-core-sdk`, and
ABI-encodes the result for `submit(...)`.

## Install

```bash
pnpm add @primus-zktls/hook-sdk viem
# only needed on the provider side
pnpm add @primuslabs/zktls-core-sdk
```

## Client side — building the spec

```ts
import { buildSpec, encodeFundOptParams, baseSepolia } from "@primus-zktls/hook-sdk";
import type { JobBindingContext, JobDefinition } from "@primus-zktls/hook-sdk";

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
        { keyName: "price_usd", parseType: "json",
          parsePath: "$.market_data.current_price.usd" },
      ],
      attMode: "proxytls",
    },
  ],
  bindings: [
    { fromStep: 0, fromKey: "id", toStep: 1, toLocation: "url", value: "bitcoin" },
  ],
};

// Required: the per-job binding context the hook will check at submit time.
const ctx: JobBindingContext = {
  jobId: jobIdFromCreateJob,
  hookAddress: baseSepolia.hook,
  chainId: 84532,
};

const fundOptParams = encodeFundOptParams(buildSpec(job, ctx));
// pass `fundOptParams` as the third arg to erc8183.fund(jobId, expectedBudget, ...)
```

## Provider side — running the job

The provider needs Primus credentials. Create an app at
**[dev.primuslabs.xyz](https://dev.primuslabs.xyz/)**, copy the generated
`appId` and `appSecret`, and pass them via env:

```bash
export PRIMUS_APP_ID="0x..."
export PRIMUS_APP_SECRET="0x..."
```

Then:

```ts
import { PrimusCoreTLS } from "@primuslabs/zktls-core-sdk";
import { runJob, createPrimusAttestor } from "@primus-zktls/hook-sdk";

const primus = new PrimusCoreTLS();
await primus.init(process.env.PRIMUS_APP_ID!, process.env.PRIMUS_APP_SECRET!, "auto");

const result = await runJob(job, {
  recipient: providerAddress,
  attestor: createPrimusAttestor(primus),
  ctx,    // SAME context the client used in buildSpec
});

// erc8183.submit(jobId, result.deliverable, result.submitOptParams)
```

## What's guaranteed

- **ABI compatibility with the hook.** Field names, struct ordering, the
  `reponseResolve` typo — all matched. Tested via the 42 SDK unit tests
  covering struct field population, hash invariants, and ABI round-trips
  (`pnpm test`).
- **Hash agreement with Solidity.** `keccak256(toBytes(...))` in TS produces
  identical bytes to `keccak256(bytes(...))` in Solidity for the same UTF-8
  input. Tested directly in [`test/specBuilder.test.ts`](./test/specBuilder.test.ts).
- **Placeholder substitution safety.** Per-location escaping (percent-encode
  for url, JSON-aware for body, raw for header) follows design-doc §5.9(c)
  exactly; LLM-style JSON-body substitution is tested with quotes,
  backslashes, and newlines.
- **No vendor lock-in.** The Primus integration lives in
  [`primusAdapter.ts`](./src/primusAdapter.ts) behind an `AttestorFn`
  interface; any zkTLS attestor that produces a compatible `Attestation`
  can be plugged in.

## API surface

| Export | Purpose |
|---|---|
| `buildSpec(job)` | `JobDefinition` → on-chain `AttestationSpec` (hashes everything). |
| `encodeFundOptParams(spec)` | ABI-encode spec for `fund()` optParams. |
| `runJob(job, opts)` | Provider-side orchestrator. Returns `{ attestations, deliverable, submitOptParams }`. |
| `createPrimusAttestor(primus)` | Wrap a `PrimusCoreTLS` instance to plug into `runJob`. |
| `encodeSubmitOptParams(atts, custom?)` | ABI-encode `(Attestation[], bytes)` for `submit()`. |
| `computeDeliverable(atts, sourceStep?)` | Reproduce the hook's deliverable hash. |
| `applySubstitutions(template, subs, location)` | Per-location-safe `<<key>>` replacement. |
| `hashResponseResolves(resolves)` | Compute `responseResolveHash` exactly as the hook does. |

## Testing

```bash
pnpm install
pnpm test           # 35 unit tests
pnpm typecheck      # strict TS
```

To regenerate the Solidity cross-validation fixture (after changing the SDK
or the hook):

```bash
pnpm tsx scripts/dump-fixture.ts
# from the toolkit root, then:
forge test --match-path 'test/integration/SdkCrossValidation*'
```

## License

MIT
