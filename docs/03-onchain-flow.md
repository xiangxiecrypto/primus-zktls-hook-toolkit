# 3. On-chain lifecycle

> **Audience.** Anyone who needs to know exactly what happens on chain at
> each stage of a job, what calldata each tx carries, what events fire, and
> what reverts mean.

This document walks through `createJob → fund → submit → complete` for a
job using `ZkTlsAttestationHook`. It assumes you have read
[02-architecture](02-architecture.md) and know the players.

> **v2 review-fixes deltas to the flow below.** Substantive changes from
> the original v1 narrative:
> - **`fund` with empty `optParams`** now reverts `SpecRequired()`; it was
>   a silent no-op in v1.
> - **`_postFund`** now also validates each step's `expectedJobBinding`
>   equals `keccak256(jobId, address(this), block.chainid)`, that
>   `maxAge ∈ [1, 24 h]`, that at least one of `methodHash` / `urlHash` /
>   `bodyHash` is non-zero, and that the customVerifier is on the
>   `trustedExtensionVerifiers` allowlist (or is `address(0)`).
> - **`_preSubmit`** uses `spec.zkTlsVerifierSnapshot` instead of the live
>   `zkTlsVerifier` (so verifier rotation doesn't break in-flight jobs).
>   The `AlreadyValidated` check has been removed (core state machine
>   already prevents resubmission); the `envelopeCommitments` write stays
>   for indexing.
> - **Quorum check**: the old single-`pinnedAttestor` is gone, replaced by
>   counting `att.attestors ∩ step.allowedAttestors` against
>   `step.minAttestorsRequired`.
> - **Staleness**: the timestamp unit is now `step.timeUnit` (Seconds or
>   Milliseconds), with a 30-second forward-skew tolerance.
> - **Data bindings**: substring search uses `_containsBounded` (delimiter
>   set `" , } : & = /`), and a binding can be dynamic via `fromExtractKey`
>   (extracting from `atts[fromStep].data` at submit time).

---

## 3.1 The four canonical transactions

Every job's happy path is four transactions, signed by three distinct
roles:

| # | Tx | Signer | Effect |
|---|---|---|---|
| 1 | `createJob` | client | Allocates a `jobId`, ties the hook to it. |
| 2 | `fund` | client | Locks in the `AttestationSpec`, advances `Open → Funded`. |
| 3 | `submit` | provider | Hands in attestations + deliverable. Hook validates. `Funded → Submitted`. |
| 4 | `complete` | evaluator | Approves. Money flows. `Submitted → Completed`. |

Off-chain, between (2) and (3), the provider runs through Primus to
produce one signed `Attestation` per step in the spec. That production
takes a few seconds per step and is the only step that talks to the
external world.

---

## 3.2 Step 1 — `createJob`

```solidity
ERC8183.createJob(
    address provider,       // can be address(0) to assign later
    address evaluator,      // != provider
    uint48  expiredAt,
    string  description,
    address hook,           // 0xd954…9D1A — must be whitelisted
    uint256 providerAgentId
) returns (uint256 jobId);
```

**Effect:**
- Reverts if hook isn't whitelisted (`HookNotWhitelisted`) or doesn't
  advertise `IERC8183Hook` via ERC165 (`InvalidHook`).
- Allocates `jobId = ++jobCounter`.
- Writes `jobs[jobId]` with `status = Open`, `hook = <hook>`.
- Emits `JobCreated(jobId, client, provider, evaluator, expiredAt, hook)`.

**No hook callback fires.** `createJob` is intentionally not hookable
because the hook isn't trusted yet at this point — admin only whitelisted
the address but the hook hasn't done anything observable.

The job is now in `Open` state. It has a hook attached but no spec.

---

## 3.3 Step 2 — `fund` (the spec-binding moment)

```solidity
ERC8183.fund(
    uint256 jobId,
    uint256 expectedBudget,
    bytes   optParams     // <-- ABI-encoded AttestationSpec
) external;
```

`optParams` is **not** opaque to the hook — it's where the entire
`AttestationSpec` rides into `_postFund`.

**Internal call graph:**

```
client → ERC8183.fund(jobId, expectedBudget, optParams)
         │
         │ require msg.sender == job.client
         │ require job.status == Open
         │ require !expired
         │ require job.budget == expectedBudget
         │
         ├─ _beforeHook(hook, jobId, fund_selector, abi.encode(client, optParams))
         │  └─ hook.beforeAction(jobId, fund_selector, ...)
         │     └─ BaseERC8183Hook routes to _preFund(jobId, client, optParams)
         │        └─ NO-OP (our hook doesn't override _preFund)
         │
         │ job.status := Funded
         │ (if budget > 0) safeTransferFrom(client → escrow, budget)
         │
         │ emit JobFunded(jobId, client, budget)
         │
         └─ _afterHook(hook, jobId, fund_selector, abi.encode(client, optParams))
            └─ hook.afterAction(jobId, fund_selector, ...)
               └─ BaseERC8183Hook routes to _postFund(jobId, client, optParams)
                  └─ our hook:
                     │ if optParams.length == 0: return  (allow zero-spec jobs)
                     │ require !_specs[jobId].configured
                     │ s := abi.decode(optParams, (AttestationSpec))
                     │ require s.steps.length > 0
                     │ require s.steps.length <= MAX_STEPS (16)
                     │ require s.bindings.length <= MAX_BINDINGS (32)
                     │ require s.deliverableSourceStep < s.steps.length
                     │ for each binding b:
                     │   require b.fromStep < b.toStep
                     │   require b.toStep < s.steps.length
                     │   require b.toLocation in {0,1,2}
                     │   require b.value.length > 0
                     │ _specs[jobId].push(s.steps[i]) for each i
                     │ _specs[jobId].push(s.bindings[i]) for each i
                     │ _specs[jobId].deliverableSourceStep = s.deliverableSourceStep
                     │ _specs[jobId].customVerifier = s.customVerifier
                     │ _specs[jobId].configured = true
                     │ emit SpecConfigured(jobId, stepCount, bindingCount, customVerifier)
```

**The job is now in `Funded` state with `_specs[jobId].configured == true`.**

What if `optParams` is empty? `_postFund` returns immediately. The job is
funded but no spec is stored — `submit` will then revert with
`SpecNotConfigured`. This intentionally lets a client *not* use the hook on
a particular job (subject to whitelist policy) but at the cost of being
unable to submit.

What if the client tries to fund twice with two different specs? Core
guards against double-fund (`status != Open`) so this can only happen if
some hypothetical future ERC-8183 version permits multi-fund — even then,
our hook's `if (stored.configured) revert SpecAlreadyConfigured()` makes
the spec write-once.

---

## 3.4 Off-chain — generating attestations

This phase has no on-chain calls. The provider:

1. Reads the spec (from chain or from the client's off-chain hand-off).
2. Computes the **resolved** URL and body for each step by substituting
   binding values into `<<keyName>>` placeholders.
3. For each step, drives `@primuslabs/zktls-core-sdk` against the resolved
   request shape and the spec's `responseResolves`. Primus's SaaS:
   - opens a TLS connection to the target host through its TEE attestor,
   - relays the bytes back to the provider,
   - parses the response according to `responseResolves`,
   - signs the resulting `Attestation` struct with the PADO key.
4. Receives one `Attestation` per step. Each has a real 65-byte ECDSA
   signature; the signer (`0xdb73…8ef6`) is in Primus's verifier
   `_attestors` set.

The result is an `Attestation[]` array, ready to ABI-encode and pass to
`submit`. The SDK handles all this — see [04-sdk-guide](04-sdk-guide.md).

Important per-attestation invariants the SDK enforces on the way back in:
- `att.request.url` matches the resolved URL (defence against attestor
  swapping URLs).
- `att.request.method` matches the spec's method.
- `att.additionParams` matches our canonical
  `'{"algorithmType":"proxytls"}'`.

If any check fails, the SDK throws before the provider can submit.

---

## 3.5 Step 3 — `submit` (the validation moment)

```solidity
ERC8183.submit(
    uint256 jobId,
    bytes32 deliverable,         // keccak256(att[sourceStep].data)
    bytes   optParams            // <-- abi.encode(Attestation[], bytes customCalldata)
) external;
```

**Internal call graph (the meat of this entire toolkit):**

```
provider → ERC8183.submit(jobId, deliverable, optParams)
           │
           │ require msg.sender == job.provider
           │ require job.status in {Funded, Open with budget==0}
           │ require !expired
           │
           ├─ _beforeHook(hook, jobId, submit_selector, data)
           │  └─ hook.beforeAction(jobId, submit_selector, abi.encode(provider, deliverable, optParams))
           │     └─ BaseERC8183Hook routes to _preSubmit(jobId, provider, deliverable, optParams)
           │        └─ our hook:
           │           │ require _specs[jobId].configured
           │           │ require envelopeCommitments[jobId] == 0
           │           │
           │           │ (atts, customCalldata) = abi.decode(optParams, (Attestation[], bytes))
           │           │ require atts.length == spec.steps.length
           │           │
           │           │ for i in 0..stepCount-1:
           │           │   _verifyOneStep(atts[i], spec.steps[i]):
           │           │     │
           │           │     ├──── staticcall ────►  Primus.verifyAttestation(atts[i])
           │           │     │                       ├ check signatures.length == 1
           │           │     │                       ├ check signature length == 65
           │           │     │                       ├ check v in {27,28}
           │           │     │                       ├ recover signer from encodeAttestation
           │           │     │                       └ require signer in _attestors
           │           │     │
           │           │     │ block.timestamp - att.timestamp/1000 <= step.maxAge
           │           │     │ keccak256(att.request.method)   == step.methodHash
           │           │     │ keccak256(att.request.url)      == step.urlHash
           │           │     │ keccak256(att.request.body)     == step.bodyHash
           │           │     │ _hashResponseResolves(att.reponseResolve) == step.responseResolveHash
           │           │     │ keccak256(att.additionParams)   == step.additionParamsHash
           │           │     │ (optional pinnedAttestor check)
           │           │
           │           │ for each binding b in spec.bindings:
           │           │   src := atts[b.fromStep].data
           │           │   dst := atts[b.toStep].request.<location matching b.toLocation>
           │           │   require _contains(src, b.value)
           │           │   require _contains(dst, b.value)
           │           │
           │           │ require keccak256(atts[spec.deliverableSourceStep].data) == deliverable
           │           │
           │           │ if spec.customVerifier != address(0):
           │           │   ─── staticcall ────►  customVerifier.verify(jobId, deliverable, atts, customCalldata)
           │           │     (verifier reverts on business-rule failure → !ok → revert ExtensionVerifierFailed)
           │           │
           │           │ envelopeCommitments[jobId] := keccak256(jobId, deliverable, atts)
           │           │ emit AttestationsValidated(jobId, deliverable, envelope, stepCount)
           │
           │ job.status := Submitted
           │ job.submittedAt := block.timestamp
           │ emit JobSubmitted(jobId, provider, deliverable)
           │
           └─ _afterHook(...) → _postSubmit → NO-OP
```

If anything inside the box marked "our hook" reverts, the entire `submit`
transaction reverts — `job.status` stays at `Funded`, no fee is paid, no
on-chain commitment is written. The provider can fix the problem and try
again with the *same* spec; only the attestations need regenerating (or
not, depending on what failed).

The most useful revert reasons to recognise:

| Selector | Error | Likely cause |
|---|---|---|
| `0x7ae89a4c` | `SpecNotConfigured` | submit happened before fund, or with empty optParams at fund. |
| `0x4dc73aaf` | `AlreadyValidated` | the hook already validated this job; cannot resubmit. |
| `0x4adba2fc` | `StepCountMismatch` | wrong number of attestations submitted. |
| `0xfb7a01ac` | `AttestationVerifierFailed` | Primus verifier said no — bad signature, signer not in `_attestors`. |
| `0xc0c2bdf3` | `AttestationStale` | the attestation timestamp is outside `maxAge`. |
| `0x???????` | `MethodHashMismatch` / `UrlHashMismatch` / `BodyHashMismatch` / `ResponseResolveHashMismatch` / `AdditionParamsHashMismatch` | the provider didn't follow the spec exactly. |
| `0xb1b48c54` | `DataBindingViolated` | a binding value was missing from source or destination. |
| `0x70e08820` | `DeliverableMismatch` | the deliverable bytes32 doesn't match `keccak256(att.data)`. |
| `0x6dffd34b` | `ExtensionVerifierFailed` | the customVerifier rejected. |

Selectors are computed in [08-troubleshooting](08-troubleshooting.md).

---

## 3.6 Step 4 — `complete` (or `reject`)

```solidity
ERC8183.complete(uint256 jobId, bytes32 reason, bytes optParams) external;
```

**Effect:**
- Reverts if msg.sender isn't the evaluator, or status isn't `Submitted`.
- Pays platform fee (none in our deployment), evaluator fee (none),
  remainder to provider.
- Fires `_preComplete` (no-op for us) and `_postComplete` (no-op).
- Emits `JobCompleted`.

The hook contributes **nothing** to the completion logic. Evaluator's
decision is final at this stage; the hook's role was upstream.

Alternative paths:

- `reject(jobId, reason, optParams)` by the evaluator — refunds the
  client.
- `claimRefund(jobId)` by anyone, *after* `expiredAt` — refunds the client.
  This is the failsafe that ensures a misbehaving hook can never trap
  funds permanently.

`reject` and `claimRefund` both call hook callbacks (`_preReject` /
`_postReject`), which our hook overrides to no-op. `claimRefund` is *not*
hookable (no callback) — an intentional safety net.

---

## 3.7 The `optParams` channel — what flows where

The fact that ERC-8183 has a `bytes optParams` argument on every
state-changing function is what makes the hook architecture work without
modifying ERC-8183. Three of the five lifecycle functions use it:

| Call | Sender | optParams content |
|---|---|---|
| `setBudget(jobId, token, amount, optParams)` | provider | unused by our hook |
| `fund(jobId, expectedBudget, optParams)` | client | `abi.encode(AttestationSpec)` |
| `submit(jobId, deliverable, optParams)` | provider | `abi.encode(Attestation[], bytes customCalldata)` |
| `complete(jobId, reason, optParams)` | evaluator | unused by our hook |
| `reject(jobId, reason, optParams)` | evaluator | unused by our hook |

Note especially: **the spec is announced by the client (fund), the
attestations are produced by the provider (submit), and the two
independently land in the hook's storage at different times.** This
separation is what makes the protocol replay-resistant: the spec is
committed before the provider knows what attestations they will produce.

The SDK's encoding helpers (`encodeFundOptParams`,
`encodeSubmitOptParams`) wrap this serialisation so you never touch the
raw ABI strings.

---

## 3.8 Events you can index

Useful events that a subgraph or off-chain indexer would track:

| Event | Source | When |
|---|---|---|
| `JobCreated(jobId, client, provider, evaluator, expiredAt, hook)` | ERC-8183 | createJob |
| `JobFunded(jobId, client, amount)` | ERC-8183 | fund |
| `SpecConfigured(jobId, stepCount, bindingCount, customVerifier)` | Hook | fund (our spec is stored) |
| `JobSubmitted(jobId, provider, deliverable)` | ERC-8183 | submit |
| `AttestationsValidated(jobId, deliverable, envelope, stepCount)` | Hook | submit (our validation passed) |
| `JobCompleted(jobId, evaluator, reason)` | ERC-8183 | complete |
| `JobRejected(jobId, by, reason)` | ERC-8183 | reject |
| `JobExpired(jobId)` | ERC-8183 | claimRefund post-expiry |

The `envelope` in `AttestationsValidated` is `keccak256(jobId, deliverable,
attestations)`, giving you a compact on-chain commitment to the full set
of attestations without storing them in storage.

---

Continue to [04 — SDK guide](04-sdk-guide.md) to see how the TypeScript
side builds the right `optParams` for each of these calls.
