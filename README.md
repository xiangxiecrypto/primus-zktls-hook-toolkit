# primus-zktls-hook-toolkit

A complete, end-to-end-validated toolkit for using
[Primus zkTLS](https://docs.primuslabs.xyz/) with the
[ERC-8183 Agentic Commerce](https://github.com/erc-8183) job protocol via a
vendor-neutral attestation hook.

The toolkit packages four things:

1. **A Solidity hook** (`ZkTlsAttestationHook`) that binds an ERC-8183 job's
   deliverable to one or more zkTLS attestations of the off-chain HTTPS
   calls the provider promised to make. *The hook lives upstream in
   [erc-8183/hook-contracts](https://github.com/erc-8183/hook-contracts) and
   is consumed here as a git submodule — never duplicated.*
2. **A TypeScript SDK** (`@primus-zktls/hook-sdk`) that translates a
   developer-friendly `JobDefinition` into the on-chain `AttestationSpec`
   the hook expects, drives the provider's multi-step attestation pipeline
   through `@primuslabs/zktls-core-sdk`, and ABI-encodes the result for
   ERC-8183's `fund()` and `submit()` calls.
3. **A reference extension verifier** (`LLMAnswerLengthVerifier`) that
   plugs into the hook's `customVerifier` slot to enforce business
   invariants (here: an LLM answer's byte length).
4. **A live Base Sepolia deployment** of everything above — ERC-8183 core,
   the hook, the verifier — paired with five completed on-chain job
   lifecycles you can replay or extend.

The hook itself is vendor-neutral (no Primus naming inside the `.sol`, per
the [upstream contribution
rules](https://github.com/erc-8183/hook-contracts/blob/main/CONTRIBUTING.md)).
This repo is where the Primus-specific wiring, real attestations, and
end-to-end demos live.

---

## Documentation map

Start here if you want to understand the system. Each doc is written to be
read top-to-bottom; later docs assume the earlier ones.

| # | Doc | What it covers |
|---|-----|----------------|
| 1 | [Introduction](docs/01-introduction.md) | The problem we solve, the actors, and the key concepts (`Job`, hook, attestation, spec, customVerifier). Start here if you have not seen ERC-8183 or zkTLS before. |
| 2 | [Architecture](docs/02-architecture.md) | The two-layer design (unified layer in the hook + extension layer in the customVerifier). Who stores what, where the trust boundaries are. |
| 3 | [On-chain lifecycle](docs/03-onchain-flow.md) | `createJob → fund → submit → complete`, with every internal `staticcall`/event diagrammed. Read this before writing your own scenarios. |
| 4 | [**SDK guide**](docs/04-sdk-guide.md) | **The big one.** How to build a spec, encode it, drive Primus to produce real attestations, and pass everything to ERC-8183 from TypeScript. With copy-pastable examples. |
| 5 | [Deployed contracts](docs/05-deployment.md) | Live Base Sepolia addresses, what they are, how to plug into them, how to redeploy if needed. |
| 6 | [Tests](docs/06-testing.md) | All seven test layers (Solidity unit / integration / fork / SDK / on-chain) and how to run / extend each. |
| 7 | [Custom verifiers](docs/07-custom-verifier.md) | Writing your own `IAttestationExtensionVerifier`, walking through `LLMAnswerLengthVerifier` as a worked example. |
| 8 | [Troubleshooting](docs/08-troubleshooting.md) | Every non-obvious gotcha we hit on the road to a green end-to-end, with the fix for each. |

## Quick start

```bash
git clone https://github.com/<you>/primus-zktls-hook-toolkit
cd primus-zktls-hook-toolkit

# 1. Solidity deps + build
forge install
forge build

# 2. SDK deps + build
cd sdk
pnpm install
pnpm build
cd ..

# 3. Run all Solidity tests (unit + integration; fork tests auto-skip
#    without BASE_SEPOLIA_RPC_URL set)
forge test

# 4. Run SDK tests
cd sdk && pnpm test
```

To reach the live Base Sepolia tests:

```bash
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test
```

To run a real on-chain job lifecycle against the **already-deployed** hook +
core on Base Sepolia (needs Primus credentials and a Base-Sepolia-funded
deployer key + a separate provider key — see [`docs/05-deployment.md`](docs/05-deployment.md)):

```bash
cd sdk
PRIVATE_KEY=0x...      PROVIDER_KEY=0x... \
PRIMUS_APP_ID=...      PRIMUS_APP_SECRET=... \
pnpm tsx scripts/onchain-e2e.ts
```

---

## Project layout

```
primus-zktls-hook-toolkit/
├── contracts/
│   └── extensions/
│       └── LLMAnswerLengthVerifier.sol     # reference IAttestationExtensionVerifier
├── docs/                                   # 8 chapters of documentation
├── lib/
│   └── hook-contracts/                     # submodule → erc-8183/hook-contracts
├── script/
│   ├── DeployTestnet.s.sol                 # full ERC8183 + Hook + USDC deploy
│   └── DeployLLMVerifier.s.sol             # standalone customVerifier deploy
├── sdk/                                    # TypeScript SDK
│   ├── src/
│   │   ├── addresses.ts                    # pinned Base Sepolia addresses
│   │   ├── types.ts                        # mirrors of Solidity structs
│   │   ├── placeholder.ts                  # <<key>> substitution
│   │   ├── specBuilder.ts                  # JobDefinition → AttestationSpec
│   │   ├── encoding.ts                     # ABI helpers for fund/submit
│   │   ├── runJob.ts                       # multi-step orchestrator
│   │   ├── primusAdapter.ts                # @primuslabs/zktls-core-sdk wrapper
│   │   └── index.ts
│   ├── test/                               # 35 vitest tests
│   └── scripts/                            # on-chain E2E + fixture generators
└── test/
    ├── unit/                               # 33 hook-isolated tests
    ├── integration/                        # 16 tests across full ERC8183 + hook + extension + SDK round-trip
    ├── fork/                               # 6 tests against the live Primus verifier
    └── fixtures/                           # SDK-generated bytes for cross-validation
```

---

## Status

| Item | State |
|---|---|
| Hook contract upstream PR | [erc-8183/hook-contracts#46](https://github.com/erc-8183/hook-contracts/pull/46) — 12 review items addressed in fork branch `feature/zktls-attestation-hook-review-fixes` |
| Solidity unit tests (hook) | 43 / 43 passing |
| Solidity integration tests (real ERC8183 + extension verifiers) | 15 / 15 passing |
| Solidity fork tests vs live Primus verifier on Base Sepolia | 6 / 6 passing |
| TypeScript SDK tests | 42 / 42 passing |
| Reference extension verifier | `LLMAnswerLengthVerifier` |
| Multi-chain deploy script | 7 chains wired (Base / Base Sepolia / Sepolia / BNB / BNB Testnet / Arbitrum / Linea / Scroll) |
| End-to-end on Base Sepolia | 5 completed jobs against the **v1** hook deployment at `0xd954…9D1A` |

### Review-fixes update (v2)

The hook has been rewritten to address the 12 items from PR #46's review. The updated source lives at `lib/hook-contracts/contracts/hooks/ZkTlsAttestationHook.sol`. Highlights:

- **Cross-job binding** — `RequestStep.expectedJobBinding` = `keccak256(jobId, hookAddress, chainId)`; provider embeds it in `additionParams`; hook checks via `_contains`.
- **EOA-verifier rejection** — `_requireContract` (extcodesize) at constructor, fund, and admin paths.
- **Quorum** — `pinnedAttestor` replaced with `allowedAttestors[]` + `minAttestorsRequired`.
- **maxAge bounds** — `[1, 24 h]` enforced.
- **Empty `optParams` reverts `SpecRequired`** — no silent no-op.
- **`trustedExtensionVerifiers`** — Ownable allowlist; customVerifier must be on it (or `address(0)`).
- **`TimeUnit` enum** — per-step Seconds | Milliseconds, plus 30-s forward-skew tolerance.
- **Dynamic data bindings** — `DataBinding.fromExtractKey` lifts the static-only restriction.
- **`_containsBounded`** — match must be bracketed by `" , } : & = /`.
- **Two-step verifier rotation** — Ownable propose/activate with 7-day delay; per-job snapshot in spec.

The hook constructor is now 3-arg: `(erc8183Core, zkTlsVerifier, owner)`. The SDK's `buildSpec(job)` is now `buildSpec(job, ctx)` where `ctx = { jobId, hookAddress, chainId }`; `runJob(job, opts)` requires the same `ctx`.

### Live deployment vs. updated code

The Base Sepolia deployment at `0xd954…9D1A` is the **v1 hook** — the original PR head. The toolkit source is now **v2**. To use v2 end-to-end, redeploy via `forge script script/DeployTestnet.s.sol:DeployTestnet`. The historical v1 lifecycles in [docs/05-deployment.md](docs/05-deployment.md) remain on-chain receipts for the original spec model.

---

## License

MIT
