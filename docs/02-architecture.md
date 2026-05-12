# 2. Architecture

> **Audience.** Anyone who has read [01-introduction](01-introduction.md)
> and wants to understand where each piece of state lives, who can write it,
> and how the trust boundaries are drawn. After this you should be able to
> answer "where would a bug here surface?" for any component.

## 2.1 The five contracts that make a job run

```
┌─────────────────────────────────────────────────────────────────────┐
│ L0  ERC-8183 core (UPSTREAM, unchanged)                             │
│     - holds jobs[]                                                  │
│     - calls hook.beforeAction / afterAction on every lifecycle step │
└──────────────────────────────────────────────┬──────────────────────┘
                                               │ direct call
                                               │
┌──────────────────────────────────────────────┴──────────────────────┐
│ L1  ZkTlsAttestationHook (this toolkit)                             │
│     - holds _specs[]      (per-job attestation specifications)      │
│     - holds envelopeCommitments[]  (per-job validation receipts)    │
│     - runs unified-layer checks at _preSubmit                       │
└──────────────────────────────────────────────┬──────────────────────┘
                                               │ staticcall per step
                                               │
┌──────────────────────────────────────────────┴──────────────────────┐
│ L2  IZkTlsVerifier (Primus PrimusZKTLS, pre-existing)               │
│     - holds _attestors set                                          │
│     - verifyAttestation() recovers signer & checks set membership   │
└─────────────────────────────────────────────────────────────────────┘

                              and optionally:

┌─────────────────────────────────────────────────────────────────────┐
│ L1+  IAttestationExtensionVerifier (customVerifier, per-job)        │
│      - staticcalled by the hook after L1 passes                     │
│      - enforces business rules                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Five contract roles, three of them ours to build, one Primus's, one
ERC-8183's. Storage is fully segregated by EVM rules: no contract can write
state in any other.

---

## 2.2 What each contract stores

### ERC-8183 core

```solidity
mapping(uint256 => Job) public jobs;     // per-job state machine
mapping(address => bool) public whitelistedHooks;
mapping(address => bool) public allowedPaymentTokens;
uint256 public jobCounter;
```

A `Job` carries `client`, `provider`, `evaluator`, `expiredAt`, `status`,
`budget`, `paymentToken`, `hook`, `description`. The `hook` is the **only
binding** between a job and the hook contract — set at `createJob` and
never modified.

### Hook

```solidity
mapping(uint256 => AttestationSpec) private _specs;
mapping(uint256 => bytes32) public envelopeCommitments;
address public immutable zkTlsVerifier;
```

`_specs[jobId]` is the per-job attestation specification, written exactly
once by `_postFund`. `envelopeCommitments[jobId]` is the commitment to
`(jobId, deliverable, attestations[])` written exactly once by
`_preSubmit` upon successful validation — also acts as a sentinel to
prevent re-submission.

`zkTlsVerifier` is set in the constructor and immutable. Pointing the hook
at a different zkTLS verifier means deploying a new hook.

### Primus PrimusZKTLS verifier

```solidity
mapping(address => bool) internal _attestors;  // (in their contract, not ours)
```

The attestor whitelist is *Primus's* state, not ours. Currently contains
the PADO signer `0xdb73…8ef6`. We do **not** mirror or snapshot it — we
trust whatever Primus says at the moment the hook calls `verifyAttestation`.

This is the trust assumption that lets us avoid maintaining our own
attestor registry: "we trust the verifier's owner not to add malicious
attestors".

### customVerifier (when present)

Whatever state it wants to hold. The hook only calls one read-only function
(`verify`), and via `staticcall`, so even a buggy customVerifier cannot
modify the hook's or core's state.

---

## 2.3 Who can mutate what

| Storage | Who can write | When |
|---|---|---|
| `ERC8183.jobs[jobId].status` | ERC8183 internal | Every state transition |
| `ERC8183.jobs[jobId].hook` | nobody after createJob | Set once at job creation |
| `Hook._specs[jobId]` | Hook internal, called via `_postFund` | Set once at first fund of the job; revert thereafter |
| `Hook.envelopeCommitments[jobId]` | Hook internal, called via `_preSubmit` | Set once on successful submit; subsequent submits revert |
| `Hook.zkTlsVerifier` | nobody | Set once at hook deploy |
| Primus `_attestors` | Primus owner only | Their operational decision |

A few corollaries follow from this:

- **Replay-resistant by construction.** Every per-job storage slot is
  write-once. There is no "modify spec" path, no "re-submit" path.
- **No global lever the hook owner can pull.** Our hook has no admin
  function, no pause, no `setVerifier`. To change behaviour you deploy a
  new hook; existing jobs keep their original hook forever.
- **The only multi-tenant state is `_specs[]`.** Multiple jobs share the
  hook; each gets its own slot. This is the ERC-1155-style pattern (one
  contract, many tenants via a shared mapping).

---

## 2.4 The two layers in detail

### Unified layer (always runs)

Compiled into `ZkTlsAttestationHook._preSubmit`. For every step `i`:

```
0xCE7c…(Primus).verifyAttestation(att[i])            ← signature check
keccak256(bytes(att[i].request.method))   == step.methodHash
keccak256(bytes(att[i].request.url))      == step.urlHash
keccak256(bytes(att[i].request.body))     == step.bodyHash
_hashResponseResolves(att[i].reponseResolve) == step.responseResolveHash
keccak256(bytes(att[i].additionParams))   == step.additionParamsHash
block.timestamp - att[i].timestamp/1000   <= step.maxAge
(optional) att[i].attestors[0]            == step.pinnedAttestor
```

Then for every binding:
```
_contains(att[fromStep].data, binding.value)
_contains(att[toStep].request.<location>, binding.value)
```

Then:
```
keccak256(bytes(att[sourceStep].data)) == deliverable
```

If any line fails, the entire submit reverts. This layer is identical for
every job; it's audited once and trusted everywhere.

### Extension layer (per-job, opt-in)

After everything above succeeds, if `spec.customVerifier != address(0)`:

```solidity
(bool ok, ) = customVerifier.staticcall(
    abi.encodeCall(
        IAttestationExtensionVerifier.verify,
        (jobId, deliverable, atts, customCalldata)
    )
);
if (!ok) revert ExtensionVerifierFailed();
```

The customVerifier sees all the attestations and any
provider-supplied `customCalldata`. It can do whatever it wants — except
mutate state, which `staticcall` forbids at the EVM level.

This is where domain knowledge lives. The hook itself never grows business
logic; new jobs that need new invariants get new customVerifiers. The
audit surface stays small.

---

## 2.5 Why staticcall everywhere

The hook makes two kinds of external calls:

1. `zkTlsVerifier.staticcall(IZkTlsVerifier.verifyAttestation, …)`
2. `customVerifier.staticcall(IAttestationExtensionVerifier.verify, …)`

Both are **read-only by EVM invariant**, not just by convention. Even if a
malicious operator deployed a "verifier" that tried to call back into
ERC-8183 or transfer tokens, the `staticcall` would fail. This bounds the
blast radius of compromised external code: the worst it can do is force a
revert.

The hook itself does **no** `call` (only `staticcall`) and **no** token
transfers. The escrow stays in the ERC-8183 core throughout.

---

## 2.6 Hook callback surface

```
                  setBudget       fund        submit      complete    reject
                  ─────────       ────        ──────      ────────    ──────
  beforeAction     pre*           pre*        pre*         pre*        pre*
  afterAction      post*          post*       post*        post*       post*
                                  ↑           ↑
                            we use this  we use this
```

`ZkTlsAttestationHook` overrides only two of the ten available callbacks:

| Callback | What it does |
|---|---|
| `_postFund(jobId, caller, optParams)` | `abi.decode(optParams)` to extract `AttestationSpec`; write to `_specs[jobId]`; emit `SpecConfigured`. |
| `_preSubmit(jobId, caller, deliverable, optParams)` | `abi.decode(optParams)` to extract `Attestation[]` + custom calldata; run unified layer; optionally call customVerifier; emit `AttestationsValidated`. |

All other callbacks inherit `BaseERC8183Hook`'s no-op defaults. This is
deliberate — every additional overridden callback widens the surface that
auditors must reason about. The hook stays minimal.

`claimRefund` is **not** hookable by design, so a buggy hook cannot trap
funds past expiry.

---

## 2.7 Trust assumptions, enumerated

In decreasing order of how "trust-y" they are:

1. **EVM correctness.** The Ethereum / Base L2 stack doesn't lie.
2. **ERC-8183 core soundness.** The escrow logic is correct (independently
   audited or to be audited by the upstream team).
3. **Hook soundness.** Our 33-test unit suite + 16 integration tests + 6
   fork tests verify the hook's invariants. Not third-party audited yet.
4. **Primus verifier soundness.** The deployed `0xCE7c…0afdE` is correct
   and Primus's contract owner is benign (will not add malicious attestors
   to `_attestors`).
5. **Primus attestor honesty.** The PADO TEE node is honest about the
   TLS sessions it observes. Hardware/software root of trust.
6. **TLS PKI.** The standard web PKI assumption — the certificate
   authorities the attestor checks against are honest about who controls a
   given hostname.

Notice the **provider is not on this list.** The provider is the adversary
we are defending against. They cannot fabricate an attestation (Primus
won't sign), cannot replay an old one (timestamps + recipient binding),
cannot tamper with the response (the TLS session is what it is), and
cannot lie about the deliverable (it's hashed from the same data the
attestation carries).

---

## 2.8 Storage layout summary

```
ERC-8183 core (0x2cF22D…C138)
└── jobs[jobId] = {
        client, provider, evaluator,
        status, budget, paymentToken,
        hook: 0xd954…9D1A,             ← line 1: job → hook
        ...
    }

Hook (0xd954…9D1A)
├── zkTlsVerifier = 0xCE7c…0afdE       ← set at deploy, immutable
├── _specs[jobId] = {                  ← line 2: job → spec
│       steps[], bindings[],
│       deliverableSourceStep,
│       customVerifier: 0x1145…e393,   ← line 3: job → customVerifier
│       configured: true
│   }
└── envelopeCommitments[jobId] = keccak256(jobId, deliverable, atts)

CustomVerifier (e.g. 0x1145…e393)
└── (verifier-specific config, read-only)
```

Continue to [03 — On-chain lifecycle](03-onchain-flow.md) to see how data
moves through these contracts at runtime.
