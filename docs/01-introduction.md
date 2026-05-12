# 1. Introduction

> **Audience.** Anyone touching this toolkit for the first time: protocol
> designers, integrators, auditors, curious readers. No prior knowledge of
> ERC-8183 or zkTLS assumed; familiarity with Solidity and TypeScript helps.

## 1.1 What problem does this solve?

ERC-8183 is a minimal protocol for AI-agent-to-agent commerce: a client
escrows funds, a provider does work, an evaluator decides if the work is
good, the protocol releases (or refunds) the money. The escrow is
trustless — funds can never get stuck — but the *correctness* of the work
is not. ERC-8183 only knows about a `deliverableHash` the provider hands in
at submit time. It cannot tell whether the deliverable is real.

That's fine when the work is on-chain (a swap, a signature, a proof). When
the provider is an AI agent calling external HTTPS APIs — pulling prices,
querying an LLM, hitting an oracle — there is no on-chain trace of the
call. The evaluator has to either trust the provider or duplicate the work
off-chain.

zkTLS closes that gap. A zkTLS attestor sits between the provider and the
external server, observes the TLS session, and afterwards signs a structure
that says *"this client really sent that request to that server and got
back exactly this response."* The signed structure — the **attestation** —
can be verified on-chain by a contract belonging to the zkTLS vendor.

This toolkit's job is to make those two protocols cooperate cleanly:

```
        Client                    Provider Agent              Evaluator
          │                            │                          │
          │  fund(jobId, spec)         │                          │
          │ ──────────►                │                          │
          │            ┌───────────────│──────────────┐           │
          │            │ for each step:│              │           │
          │            │   provider hits external API │           │
          │            │   Primus zkTLS attestor signs│           │
          │            └───────────────│──────────────┘           │
          │                            │  submit(jobId, …, atts)  │
          │                            │ ──────────►              │
          │                                                       │
          │                                  complete(jobId)      │
          │ ◄──────────────────────────────────────── (or reject) │
                                ↑
                        all of this enforced by the
                        ZkTlsAttestationHook contract
```

The hook **binds** the deliverable to a set of zkTLS attestations. The
evaluator (and anyone else) can read the spec and the attestations on chain
and replay the validation logic — no trust in the provider required.

---

## 1.2 The five actors

| Actor | Role | Where they appear |
|---|---|---|
| **Client** | Defines the job, escrows the budget, sets the attestation spec at fund time. | `createJob`, `fund` |
| **Provider** | Executes the off-chain work, drives each step through Primus to get a signed attestation, submits the deliverable. | `submit` |
| **Evaluator** | Approves or rejects the submission after the hook has accepted it. Has the final word on payment. | `complete`, `reject` |
| **Primus attestor (PADO)** | Operated by Primus; observes the TLS sessions and signs attestations from inside a TEE. The signer is `0xdb73…8ef6` for the current SaaS deployment. | off-chain |
| **Hook + verifier contracts** | On-chain validators. The hook checks shape/binding/timestamp; the verifier checks the attestor's signature. The hook only releases the job if everything lines up. | `_preSubmit` |

Two of these actors can sometimes collapse into one wallet (e.g. evaluator
and client are often the same address in test scenarios), but **client and
provider must be distinct** — ERC-8183 enforces this at `createJob`.

---

## 1.3 Key concepts (memorize these)

### Job
An ERC-8183 job. Carries `client`, `provider`, `evaluator`, `budget`,
`paymentToken`, `expiredAt`, and a single `hook` address. Created via
`createJob`; transitions through `Open → Funded → Submitted → Completed`
(or `→ Rejected`/`→ Expired`).

### Hook
A contract that ERC-8183 calls before and after every state-changing
action. Our `ZkTlsAttestationHook` is a hook that stores a per-job
attestation specification at fund time and validates submitted
attestations against it at submit time.

### Attestation
A signed assertion from a zkTLS attestor that some HTTPS call really
happened, with these inputs and that response. The on-chain struct shape
matches Primus's deployment: URL, method, body, attestor list, signatures,
plus a parsed `data` field carrying the extracted response fields.

### AttestationSpec
The on-chain object the client locks in at fund time. Says "this job
expects N attestations, the i-th must have these hashes (method, URL, body,
response shape), there must be these inter-step bindings, and optionally a
customVerifier should approve."

### customVerifier
An optional contract that implements `IAttestationExtensionVerifier.verify`.
The hook staticcalls it after all generic checks pass. Used for
business-level invariants the hook itself cannot express
("answer length ≤ 500 bytes", "price within 5% of the oracle", etc.).

### Step
One element of `AttestationSpec.steps`. Pins the shape of one HTTPS call:
its method hash, URL hash, body hash, response-schema hash, additionParams
hash (carrying the zkTLS algorithm mode), a `maxAge` window, and an
optional `pinnedAttestor`.

### Binding
One element of `AttestationSpec.bindings`. Declares that a static byte
sequence must appear *both* in the parsed data of one step and in a
specific location (URL / header / body) of a later step's request. Models
the data flow across a multi-step pipeline.

### Deliverable
The single `bytes32` the provider passes to `submit`. The hook insists
this equals `keccak256(att[sourceStep].data)` — closing the loop between
the off-chain response and the on-chain commitment.

---

## 1.4 What "validate" means in this system

The hook's job is **shape and binding**, not semantics. Concretely:

- **Shape** — the URL/method/body/response-resolves/additionParams of each
  attestation hash to what the spec pinned.
- **Binding** — declared static values appear in both the source step's
  data and the destination step's request.
- **Signature** — every attestation passes the zkTLS verifier (signature is
  valid, signer is in the verifier's whitelist).
- **Freshness** — the attestation's timestamp is within `maxAge` seconds of
  block.timestamp.

What the hook does **not** check:

- Whether the LLM's answer is correct, helpful, or even relevant.
- Whether the price returned by an oracle is "fair".
- Whether the provider's choice of which step alternative to use was wise.

Those are business decisions and live in the `customVerifier` — opt-in, per
job, replaceable.

This is the **two-layer design** that recurs throughout this toolkit:

| Layer | Lives in | Enforces |
|---|---|---|
| Unified layer | The hook itself, identical for every job. | Cryptographic and structural invariants. Audit once, trust everywhere. |
| Extension layer | A `customVerifier` contract, chosen by the spec. | Business-level invariants. Audit per job. |

Section [02-architecture](02-architecture.md) goes deeper on how these two
layers are wired together and where the trust boundaries are.

---

## 1.5 A worked example: "fetch BTC price, summarise with an LLM"

To make the concepts concrete, here is one of the demos this toolkit ships
with — Job #4 on Base Sepolia.

**Off-chain story:**
1. The provider GETs `api.coingecko.com/.../simple/price?ids=bitcoin&vs_currencies=usd`.
2. The provider POSTs the BTC quote to DeepSeek's chat-completions endpoint
   and asks for a one-sentence fun fact about bitcoin.
3. The provider submits the LLM answer as the deliverable.

**On-chain story:**
1. Client calls `createJob`, naming the hook.
2. Client calls `fund`, passing the `AttestationSpec` in `optParams`. The
   spec pins both URLs, both response paths, the binding `"bitcoin"` (which
   appears in step 0's parsed data and step 1's POST body), and points
   `deliverableSourceStep = 1`.
3. Provider hits Primus twice (CoinGecko + DeepSeek), getting one signed
   `Attestation` per call.
4. Provider calls `submit(jobId, keccak256(LLM_answer_data), encoded_atts)`.
5. The hook runs through every check: signature for step 0, signature for
   step 1, hashes, binding, deliverable bind, customVerifier (when one was
   wired). If anything fails the entire `submit` reverts.
6. Evaluator calls `complete`. The job is finished.

That whole flow is one TypeScript script (`sdk/scripts/onchain-llm.ts`) and
took about 30 seconds to run on Base Sepolia. The receipts are linked in
[docs/05-deployment.md](05-deployment.md).

---

## 1.6 What this toolkit is, and is not

It **is**:
- A complete, end-to-end-validated set of working contracts + SDK + tests
  for Primus zkTLS on ERC-8183.
- A vendor-neutral hook (no Primus references in the `.sol`) wrapped by a
  Primus-specific TypeScript SDK.
- A reference for how to write your own `customVerifier`.

It **is not**:
- The official ERC-8183 reference deployment (there isn't one yet on any
  testnet — we deploy our own copy).
- A production-audited release. The unit + integration + fork test suites
  give high confidence, but no third-party audit has been performed.
- Locked to Primus. The hook accepts any `IZkTlsVerifier` implementation;
  swapping vendors means swapping the constructor arg and the off-chain
  attestor library.

---

Continue to [02 — Architecture](02-architecture.md) to see how the pieces
fit together at the contract level.
