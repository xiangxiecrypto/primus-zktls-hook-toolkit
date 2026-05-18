# 8. Troubleshooting

> **Audience.** Anyone debugging a failing test, a reverting submit, or a
> head-scratcher between the SDK and the hook. This is the catalog of
> non-obvious gotchas we hit while bringing the toolkit up.

Each entry: symptom, root cause, fix. Skim the symptoms first.

> **v2 review-fixes — new gotchas to know about.** In addition to the v1
> entries below:
>
> - **`SpecRequired()`** — fund tx reverts because optParams was empty.
>   Was a silent no-op in v1; now hard error. Always pass
>   `encodeFundOptParams(buildSpec(job, ctx))`.
> - **`JobBindingMissing()`** — the attestation's `additionParams`
>   doesn't contain the hex of the per-job binding. Cause: client and
>   provider used different `ctx` objects, or the provider's attestor
>   stripped/altered `additionParams`. Solution: pin the JobDefinition
>   in shared storage, derive `ctx` identically on both sides.
> - **`InvalidJobBinding()`** — at fund time, `step.expectedJobBinding`
>   doesn't equal `keccak256(jobId, address(this), chainid)`. Cause:
>   client built the spec for a different jobId / chain / hook.
> - **`InvalidMaxAge()`** — `maxAge` is 0 or > 24 hours.
> - **`UnsatisfiableStep()`** — all three of `methodHash` / `urlHash` /
>   `bodyHash` are zero — almost certainly a misconfig. Pin at least one.
> - **`AttestorQuorumNotMet()`** — `step.minAttestorsRequired` not
>   satisfied by `att.attestors ∩ step.allowedAttestors`.
> - **`ExtensionVerifierNotTrusted()`** — customVerifier is not on the
>   hook's allowlist. Owner must call `setTrustedExtensionVerifier`.
> - **`NotAContract()`** — verifier or customVerifier address has no
>   code (an EOA, or a destroyed contract).
> - **`RotationDelayNotElapsed()` / `NoPendingVerifier()`** — verifier
>   rotation flow: propose, wait 7 days, then activate.

---

## 8.1 Decoding hook revert selectors

When a submit fails on chain, you see something like:

```
Encoded error signature "0x7ae89a4c" not found on ABI.
```

The 4-byte selector tells you exactly which check failed. Look it up:

| Selector | Error | Layer |
|---|---|---|
| `0x6dffd34b` | `ExtensionVerifierFailed()` | extension |
| `0xfb7a01ac` | `AttestationVerifierFailed()` | unified (Primus reject) |
| `0xc0c2bdf3` | `AttestationStale()` | unified |
| `0x?` | `MethodHashMismatch()` | unified |
| `0x?` | `UrlHashMismatch()` | unified |
| `0x?` | `BodyHashMismatch()` | unified |
| `0x?` | `ResponseResolveHashMismatch()` | unified |
| `0x?` | `AdditionParamsHashMismatch()` | unified |
| `0x?` | `PinnedAttestorMismatch()` | unified |
| `0x?` | `DataBindingViolated()` | unified |
| `0x?` | `DeliverableMismatch()` | unified |
| `0x?` | `StepCountMismatch()` | unified |
| `0x?` | `SpecAlreadyConfigured()` | unified (config) |
| `0x7ae89a4c` | `SpecNotConfigured()` | unified (config) |
| `0x?` | `AlreadyValidated()` | unified |
| `0x?` | `EmptySteps()` | spec validation |
| `0x?` | `TooManySteps()` | spec validation |
| `0x?` | `TooManyBindings()` | spec validation |
| `0x?` | `InvalidDeliverableSourceStep()` | spec validation |
| `0x?` | `InvalidBinding()` | spec validation |
| `0x?` | `InvalidLocation()` | spec validation |

To resolve any of the `0x?` entries:

```bash
cast keccak "YourError()" | head -c 10
```

Or, paste into Foundry's `cast 4byte` (public selector DB, may not have
our custom errors yet).

---

## 8.2 `SpecNotConfigured` despite fund tx succeeding

**Symptom.** `fund(jobId, …, spec)` lands on chain successfully — you can
see the `SpecConfigured` event in BaseScan — but the immediately following
`submit(jobId, …)` reverts at preflight with `SpecNotConfigured`
(`0x7ae89a4c`).

**Root cause.** Public load-balanced RPCs (like `https://sepolia.base.org`)
sometimes serve stale state for a block or two. Viem's
`writeContract` runs an `eth_estimateGas` simulation before broadcasting;
that simulation can land on a different node than the one that mined your
fund tx.

**Fix.** Wait for more confirmations on the fund tx, or use a private RPC.
The shipped lifecycle uses `confirmations: 2`:

```ts
await publicClient.waitForTransactionReceipt({
  hash: fundTx,
  confirmations: 2,        // ← critical
});
```

This adds a few seconds of latency but eliminates the lag.

**Verifying it's an RPC issue and not a real bug.** Read the spec
directly on the latest block:

```bash
cast call <hook> "getSpec(uint256)((...),...)" <jobId> --rpc-url ...
```

If the spec is configured, the chain is fine — it was just the
preflight node that was behind.

---

## 8.3 `AttestationStale` on a fresh attestation

**Symptom.** Primus produced an attestation milliseconds ago, but submit
reverts with `AttestationStale` (`0xc0c2bdf3`).

**Root cause.** `att.timestamp` from Primus is in **milliseconds since
epoch** (e.g. `1778591226082`). `block.timestamp` in the EVM is in
**seconds** (e.g. `1778591226`). An early hook version compared them
directly, treating the millisecond timestamp as a far-future second
timestamp, triggering the staleness underflow guard.

**Fix.** The current hook divides `att.timestamp` by 1000 before
comparing:

```solidity
uint256 attTsSec = uint256(att.timestamp) / 1000;
if (block.timestamp < attTsSec) revert AttestationStale();
if (block.timestamp - attTsSec > step.maxAge) revert AttestationStale();
```

`maxAge` stays in seconds — the natural Solidity time unit.

**If you're writing test fixtures by hand,** use millisecond timestamps
(e.g. `1700000000000n`, not `1700000000n`) or the hook will reject them.

---

## 8.4 `ResponseResolveHashMismatch` on a real Primus attestation

**Symptom.** Spec is built from a `JobDefinition` with
`responseResolves: [{ keyName: "x", parseType: "json", parsePath: "$.y" }]`.
Primus returns a real signed attestation. submit reverts with
`ResponseResolveHashMismatch`.

**Root cause.** Primus's signed `Attestation` has `parseType` **cleared**
to the empty string `""`. Our SDK was hashing with `parseType: "json"`, so
the spec's hash didn't match what the hook recomputed from
`att.reponseResolve`.

**Fix.** SDK's `hashResponseResolves` now uses an empty string for
`parseType`:

```ts
const leaves = resolves.map(r =>
  keccak256(encodeAbiParameters(
    [{ type: "string" }, { type: "string" }, { type: "string" }],
    [r.keyName, "", r.parsePath],    // ← always "" for the hash
  )),
);
```

The developer-facing JobDefinition still accepts `parseType: "json"` —
Primus uses it off-chain to know how to parse the response. The
normalisation is hash-only.

**Why Primus clears it:** speculative — likely because the parsing already
happened off-chain by the time the attestation is signed; storing the
type would be redundant. Either way, we have to match what they sign, not
what we send in.

---

## 8.5 `DataBindingViolated` on a multi-step run

**Symptom.** Two-step job. The binding value clearly appears in both
attestations (you can see the bytes in the trace). Submit reverts with
`DataBindingViolated`.

**Root cause(s), in order of likelihood:**

1. **URL encoding.** If the binding location is `"url"` and the value
   contains characters that need percent-encoding (e.g. spaces), the SDK
   percent-encodes the value when substituting into the URL — but the
   binding's `value` in the spec is the raw string, and the hook does a
   raw substring check. The raw string won't appear in the encoded URL.

   **Fix:** for now, use URL-safe ASCII for binding values. (A future SDK
   could canonicalize both sides; tracked as future work.)

2. **JSON escaping in body.** Similar story with body location and
   characters like `"`, `\`, `\n` — the SDK does JSON-aware escape, the
   binding's raw value won't substring-match the escaped form.

3. **Wrong location.** Easy to set `toLocation: "url"` when you actually
   meant `"body"`.

4. **Wrong step indices.** Off-by-one between SDK's 0-based and your own
   mental 1-based numbering.

**Debugging tip:** decode the submitted Attestation array from the failing
submit tx's calldata. The raw bytes of `att.request.url` / `body` are
right there.

---

## 8.6 Primus "Unstable internet connection. Please try again."

**Symptom.** `runJob` throws with that error mid-attestation.

**Root cause.** Transient TLS / WebSocket failure to Primus's attestor.

**Fix.** Retry. We wrap `runJob` in an exponential-backoff retry loop in
the demo lifecycle (4 attempts, 3 / 6 / 9 seconds backoff). Anywhere from
1 retry to 4 retries is typical.

If you hit the limit consistently, your network can't reach
`api1.padolabs.org` — check DNS resolution.

---

## 8.7 `getaddrinfo ENOTFOUND api1.padolabs.org` crashes Node

**Symptom.** Process exits with this error before any retry can catch it.

**Root cause.** Primus's underlying WebSocket emits an unhandled `error`
event on DNS failure, which Node turns into an uncaught exception. The
SDK's retry loop wraps a Promise that hasn't been rejected yet — the
process dies on the side channel.

**Workaround.** Wrap the script in a bash retry loop, or install a
process-level handler:

```ts
process.on("uncaughtException", err => {
  if (/ENOTFOUND|getaddrinfo|EAI_AGAIN/.test(err.message ?? "")) return;
  throw err;
});
```

This works inconsistently in Node 25 — sometimes the WebSocket error
bypasses even this. The robust fix is a shell-level retry:

```bash
for i in 1 2 3 4 5; do
  pnpm tsx scripts/onchain-...ts && break
  sleep 5
done
```

---

## 8.8 viem: "function does not exist on ABI"

**Symptom.** `pnpm tsx scripts/...ts` fails with
`The requested module 'viem' does not provide an export named 'privateKeyToAccount'`.

**Root cause.** `privateKeyToAccount` lives in `viem/accounts`, not
`viem`. Easy import mistake.

**Fix.** `import { privateKeyToAccount } from "viem/accounts"`.

---

## 8.9 `AccessControlUnauthorizedAccount` during deploy script

**Symptom.** `forge script DeployTestnet.s.sol --broadcast` fails with
`AccessControlUnauthorizedAccount(0x1804…1f38, 0xa498…1775)`.

**Root cause.** `vm.startBroadcast()` with no argument uses Forge's
**DefaultSender** during simulation, not the address derived from
`vm.envUint("PRIVATE_KEY")`. The proxy was initialized with the
deployer-from-env as admin, but the post-init `setHookWhitelist` was
called by the DefaultSender — who has no role.

**Fix.** Pass the key to `startBroadcast`:

```solidity
uint256 deployerKey = vm.envUint("PRIVATE_KEY");
vm.startBroadcast(deployerKey);    // ← key here
…
vm.stopBroadcast();
```

This makes simulation and broadcast both use the right signer.

---

## 8.10 `forge install --no-commit` fails

**Symptom.** Forge complains `unexpected argument '--no-commit'`.

**Root cause.** Old vs new Forge CLI. The flag was renamed to `--commit`
(which now exists as the *positive* form, meaning "do commit"); omit it
entirely to not commit.

**Fix.** Just `forge install foundry-rs/forge-std@v1.15.0`.

---

## 8.11 Hook unit tests pass locally but fail after upgrading Forge

**Symptom.** A test that used `timestamp: uint64(block.timestamp)` starts
reverting `AttestationStale` after some Forge update.

**Root cause.** Foundry's default `block.timestamp` increased (or your
test changed warps). The `att.timestamp` test fixtures were too small to
divide by 1000 and still beat the unified-layer underflow guard.

**Fix.** Always set `att.timestamp` in **milliseconds**:

```solidity
timestamp: uint64(block.timestamp * 1000),     // not just block.timestamp
```

---

## 8.12 BaseScan can't decode the hook's revert reason

**Symptom.** BaseScan shows "Internal Transactions" but the revert reason
is just `0x6dffd34b` instead of a human name.

**Root cause.** BaseScan can only decode custom errors when the contract
is **verified** on BaseScan. Our hook isn't verified there yet (see
[05-deployment](05-deployment.md) §"BaseScan source verification").

**Fix.** Verify the source on BaseScan. Until then, look up the selector
manually with `cast keccak`.

---

## 8.13 forge-lint `unsafe-typecast` warning

**Symptom.** `forge build` prints warnings about
`uint8(stepCount)` being potentially truncating.

**Root cause.** forge-lint is correct in general — but we bound
`stepCount` to `MAX_STEPS = 16` and `bindingCount` to `MAX_BINDINGS = 32`,
so the casts are safe by precondition.

**Fix.** We changed the event signature to use `uint256` instead of
`uint8`, sidestepping the warning entirely. If you add new events with
similar fields, use `uint256` or add the inline lint-disable.

---

## 8.14 forge-lint `block-timestamp` warning

**Symptom.** Warnings about `block.timestamp` in comparisons.

**Root cause.** forge-lint flags any `block.timestamp` comparison because
validators can manipulate timestamps within a small window.

**For our use case** — comparing against a `maxAge` of seconds-to-hours —
this is harmless. A validator skewing by 12 seconds doesn't materially
affect an hour-long acceptance window.

**Fix.** Ignore the warning. The same pattern exists across the upstream
ERC-8183 base contracts.

---

## 8.15 Random "fund tx succeeded but spec wasn't set" symptoms

If the symptoms in §8.2 happen on a **fresh** local Anvil instance (no RPC
load balancer), look at:

- Did `fund` revert silently? (Check `cast receipt <fundTx>`.)
- Did the client call `fund` with **non-empty** optParams? (Empty
  optParams is a no-op in `_postFund`.)
- Did the SDK build a spec with **zero steps**? `buildSpec` would reject
  this; check the JobDefinition's `steps` array.

---

## 8.16 SDK ↔ Solidity cross-validation test fails

**Symptom.** `SdkCrossValidation.t.sol` fails after a SDK or hook change.

**Root cause.** The SDK now produces bytes that don't match what the hook
expects. The fixture is stale.

**Fix.** Regenerate:

```bash
cd sdk
pnpm tsx scripts/dump-fixture.ts
cd ..
forge test --match-path 'test/integration/SdkCrossValidation*'
```

If it still fails, the SDK's hashing diverged from the Solidity hook's
hashing. The most likely culprits (in order of how often they bite):

1. `hashResponseResolves` (parseType normalisation — see §8.4).
2. `additionParams` JSON canonical form.
3. ABI encoding of the spec struct itself.

Diff the SDK-generated `sdk-fund.hex` against what the hook recomputes
from on-chain state to localize the issue.

---

## 8.17 "Why did my LLM-with-binding submission fail with `BodyHashMismatch`?"

**Symptom.** Single-step LLM job. submit reverts with
`BodyHashMismatch`.

**Common cause.** The LLM step has a `<<key>>` placeholder in the body
template, but the binding's `value` differs from what actually gets
substituted at run time (e.g. provider's `JobDefinition` differs from
client's). The two sides MUST use the same `JobDefinition` to produce
matching hashes.

**Fix.** Ensure the `JobDefinition` JSON / object is identical on both
sides — it's effectively part of the protocol agreement. Pin it in a file
both sides read.

---

If you hit a problem not in this list, please open an issue. The whole
point of this doc is to convert "I got this weird error" into "we have
notes on this".
