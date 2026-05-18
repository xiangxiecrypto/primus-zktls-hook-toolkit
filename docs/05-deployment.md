# 5. Deployed contracts

> **Audience.** Anyone who wants to plug into the existing Base Sepolia
> deployment, redeploy a fresh stack, or move the toolkit to a different
> chain.

> **v2 review-fixes status.** The Base Sepolia deployment at
> `0xd954…9D1A` is the **v1 hook** (the original PR head). The toolkit
> source has since been updated to v2 (see [README](../README.md) —
> "Review-fixes update"). To exercise v2 end-to-end on chain, **redeploy
> with the new 3-arg constructor**: `(erc8183Core, zkTlsVerifier, owner)`.
> v1 lifecycles 2–7 below remain on-chain receipts of the v1 spec model
> and are kept for historical reference.

The toolkit has a live deployment on **Base Sepolia (chainId 84532)** with
every contract verified-by-execution (each one has been used in at least
one real lifecycle). Pinning these addresses lets the SDK, the tests, the
docs, and your downstream code all reference one source of truth.

---

## 5.1 The address book

All addresses live in `sdk/src/addresses.ts`, exported under the name
`baseSepolia`. They are also reproduced here:

### v2 deployment (current — review-fixes branch)

| Role | Address | Code source | Verified on BaseScan |
|---|---|---|---|
| Primus PrimusZKTLS verifier | [`0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE`](https://sepolia.basescan.org/address/0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE) | Primus (pre-existing) | yes (Primus) |
| ERC-8183 core (UUPS proxy) | [`0xe823C8f28C469D44FbD07294FBdc1F21eb7e7cC3`](https://sepolia.basescan.org/address/0xe823C8f28C469D44FbD07294FBdc1F21eb7e7cC3) | `lib/hook-contracts/contracts/erc8183/contracts/ERC8183.sol` | not yet |
| ERC-8183 implementation | [`0x091Fefe9225ab565aEdFb4f5c965dd1c8928c36a`](https://sepolia.basescan.org/address/0x091Fefe9225ab565aEdFb4f5c965dd1c8928c36a) | same | not yet |
| MockUSDC | [`0xC2371E1af7497D4A4D91dB5dF99e2a91C5fd4Ed3`](https://sepolia.basescan.org/address/0xC2371E1af7497D4A4D91dB5dF99e2a91C5fd4Ed3) | `…/erc8183/contracts/mocks/MockUSDC.sol` | not yet |
| **ZkTlsAttestationHook (v2)** | [`0xfB761Ad1bffa503bbEC1b39BAED4A6Bc2cf47bA3`](https://sepolia.basescan.org/address/0xfB761Ad1bffa503bbEC1b39BAED4A6Bc2cf47bA3) | `lib/hook-contracts/contracts/hooks/ZkTlsAttestationHook.sol` (review-fixes branch) | not yet |
| LLMAnswerLengthVerifier (loose [20, 800]) — allowlisted | [`0x3AE0316827f7855f4dcc2C5034CecdDfeF002183`](https://sepolia.basescan.org/address/0x3AE0316827f7855f4dcc2C5034CecdDfeF002183) | `contracts/extensions/LLMAnswerLengthVerifier.sol` | not yet |
| LLMAnswerLengthVerifier (tight [1, 10]) — allowlisted | [`0x0EA7F1FA6516Eca119644EC60c58F6DAA4ebb3Ed`](https://sepolia.basescan.org/address/0x0EA7F1FA6516Eca119644EC60c58F6DAA4ebb3Ed) | same | not yet |

### v1 historical addresses

These are kept on-chain so the 5 completed v1 job lifecycles remain inspectable. The v1 hook cannot accept new specs — the spec ABI shape has changed in v2.

| Role | Address |
|---|---|
| ZkTlsAttestationHook (v1) | [`0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A`](https://sepolia.basescan.org/address/0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A) |
| ERC-8183 core (v1) | [`0x2cF22D4013F7228090c6a77B134114aD0761C138`](https://sepolia.basescan.org/address/0x2cF22D4013F7228090c6a77B134114aD0761C138) |
| MockUSDC (v1) | [`0xC4980666C64C570FdC31e3a3c9eEbf441d99f0A4`](https://sepolia.basescan.org/address/0xC4980666C64C570FdC31e3a3c9eEbf441d99f0A4) |

### Demo wallets

| Role | Address | Has Base Sepolia ETH? |
|---|---|---|
| Deployer / admin / client / evaluator | [`0x89BBf3451643eef216c3A60d5B561c58F0D8adb9`](https://sepolia.basescan.org/address/0x89BBf3451643eef216c3A60d5B561c58F0D8adb9) | yes |
| Provider | [`0xe8e923c3bAAD4298fC7BfF78a06f7F63C09dE955`](https://sepolia.basescan.org/address/0xe8e923c3bAAD4298fC7BfF78a06f7F63C09dE955) | yes (small) |

The deployer holds 1M MockUSDC and ETH for further txes. The provider has
a small ETH balance for submit gas. These wallets are stable for testing —
private keys are held by the toolkit operator.

### Importing in code

```ts
import { baseSepolia, demoWallets } from "@primus-zktls/hook-sdk";

// On-chain addresses:
baseSepolia.erc8183Core    // 0x2cF2…C138
baseSepolia.hook           // 0xd954…9D1A
baseSepolia.mockUsdc       // 0xC498…f0A4
baseSepolia.primusVerifier // 0xCE7c…0afdE
baseSepolia.llmAnswerLengthVerifier_loose  // 0x1145…e393
baseSepolia.llmAnswerLengthVerifier_tight  // 0x8fcd…074f

// Useful constants:
baseSepolia.chainId        // 84532
baseSepolia.rpcUrl         // "https://sepolia.base.org"
baseSepolia.basescanUrl    // "https://sepolia.basescan.org"
```

---

## 5.2 Verifying that the deployment is in a sane state

```bash
# Hook is whitelisted in core
cast call 0x2cF22D4013F7228090c6a77B134114aD0761C138 \
  "whitelistedHooks(address)(bool)" \
  0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A \
  --rpc-url https://sepolia.base.org
# → true

# MockUSDC is on the payment-token allowlist
cast call 0x2cF22D4013F7228090c6a77B134114aD0761C138 \
  "allowedPaymentTokens(address)(bool)" \
  0xC4980666C64C570FdC31e3a3c9eEbf441d99f0A4 \
  --rpc-url https://sepolia.base.org
# → true

# Hook points at the correct Primus verifier
cast call 0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A \
  "zkTlsVerifier()(address)" \
  --rpc-url https://sepolia.base.org
# → 0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE

# Job counter is at least 7 (we ran 7 jobs end to end)
cast call 0x2cF22D4013F7228090c6a77B134114aD0761C138 \
  "jobCounter()(uint256)" \
  --rpc-url https://sepolia.base.org
# → 7  (or higher if you've run more)
```

---

## 5.3 Historical lifecycles you can replay

These are the jobs we ran end to end during the toolkit's bring-up. Each
is a useful reference for "what does X look like on chain?":

| jobId | Scenario | submit tx | Status |
|---|---|---|---|
| 2 | single-step CoinGecko BTC/USD | [`0x678d…d416`](https://sepolia.basescan.org/tx/0x678dba30546f592cb38c736a44fa61cb032e472c6aa2fd0ede0eb2143d31d416) | Completed |
| 3 | multi-step CoinGecko USD → EUR + binding | [`0x738c…6d52`](https://sepolia.basescan.org/tx/0x738c7dbc05fb55f4307b6bab39dace17b75a481e00e4ffcb79502aff521c6d52) | Completed |
| 4 | CoinGecko → DeepSeek LLM + binding | [`0x4d42…ab7c`](https://sepolia.basescan.org/tx/0x4d42518568542e630b879f06c4bf957c6d34ba8dd3aef7ea6590ca77f6f3ab7c) | Completed |
| 5 | LLM + customVerifier (loose, [20, 800]) | [`0x9ac2…bc26`](https://sepolia.basescan.org/tx/0x9ac2b937e8da53a2d75b9c21d4a634472fc73c5bd88c8c51d831d37a1491bc26) | Completed |
| 7 | LLM + customVerifier (tight, [1, 10]) | n/a — preflight reverted `ExtensionVerifierFailed` | Funded (stuck — provider cannot satisfy the spec) |

For each completed job you can inspect the on-chain state:

```bash
# Get the full job tuple
cast call 0x2cF22D4013F7228090c6a77B134114aD0761C138 \
  "getJob(uint256)((address,uint8,address,uint48,address,uint48,uint256,address,address,uint256,string))" \
  4 --rpc-url https://sepolia.base.org

# Get the hook's stored spec
cast call 0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A \
  "getSpec(uint256)((bytes32,bytes32,bytes32,bytes32,bytes32,uint64,address)[],(uint8,uint8,uint8,bytes)[],uint8,address,bool)" \
  4 --rpc-url https://sepolia.base.org

# Hook says "yes, this job validated"
cast call 0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A \
  "isValidated(uint256)(bool)" \
  4 --rpc-url https://sepolia.base.org
# → true
```

---

## 5.4 Running a new job on the existing deployment

You do **not** need to deploy anything to run a fresh job. The hook + core
+ verifier are already in place. The simplest demo:

```bash
cd sdk
PRIVATE_KEY=0x...      PROVIDER_KEY=0x... \
PRIMUS_APP_ID=...      PRIMUS_APP_SECRET=... \
pnpm tsx scripts/onchain-e2e.ts
```

This:
1. Uses the deployer for client + evaluator (must hold Base Sepolia ETH).
2. Uses a separate provider key (also needs a small amount of Base Sepolia
   ETH for the submit tx).
3. Talks to the deployed hook + core + Primus verifier.

The script prints a tx hash for each on-chain action. After completion,
`cast call hook isValidated(jobId)` returns true and the job's status is
`Completed` (= `3`).

### Funding a new provider wallet

If you don't already have a provider keypair you trust, generate one and
fund it:

```bash
# generate
cast wallet new

# fund it with 0.002 ETH (enough for many submits)
cast send <provider-address> --value 0.002ether \
  --rpc-url https://sepolia.base.org \
  --private-key $DEPLOYER_KEY
```

Use the new private key as `PROVIDER_KEY`.

---

## 5.5 Redeploying

If you want a fresh stack (e.g. for a clean ERC-8183 instance), use the
deploy scripts:

```bash
# Full stack: ERC-8183 core (+ impl + proxy) + MockUSDC + Hook, all wired
PRIVATE_KEY=0x... PROVIDER_ADDR=0x... \
  forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url base_sepolia --broadcast

# A customVerifier (e.g. fresh LLMAnswerLengthVerifier)
PRIVATE_KEY=0x... \
LLM_STEP=1 LLM_MIN_BYTES=20 LLM_MAX_BYTES=800 \
  forge script script/DeployLLMVerifier.s.sol:DeployLLMVerifier \
  --rpc-url base_sepolia --broadcast
```

After redeploy, update `sdk/src/addresses.ts` with the new addresses so
the SDK + downstream consumers see them.

### What the `DeployTestnet.s.sol` script does

In order, in one broadcast:

1. `new ERC8183()` — deploys implementation.
2. `new ERC1967Proxy(impl, initData)` — deploys UUPS proxy initialised
   with deployer as both treasury and admin.
3. `new MockUSDC()` and `mint(deployer, 1_000_000 * 1e6)`.
4. `new ZkTlsAttestationHook(core, primusVerifier)` — the
   per-chain Primus address is picked automatically from `block.chainid`.
5. `core.setHookWhitelist(hook, true)`.
6. `core.setPaymentTokenAllowed(usdc, true)`.

Estimated gas: ~8.7M total, well under 0.0001 ETH at testnet gas prices.

---

## 5.6 Moving to a different chain

The deploy script supports the following chains out of the box (per Primus's
published addresses):

| chainId | Network | Primus verifier |
|---|---|---|
| 8453 | Base | `0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE` |
| 84532 | Base Sepolia | `0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE` |
| 11155111 | Sepolia | `0x3760aB354507a29a9F5c65A66C74353fd86393FA` |
| 56 | BNB Chain | `0xF24199D5D431bE869af3Da61162CbBb58C389324` |
| 97 | BNB Testnet | `0xBc074EbE6D39A97Fb35726832300a950e2D94324` |
| 42161 | Arbitrum | `0x982Cef8d9F184566C2BeC48c4fb9b6e7B0b4A58B` |
| 59144 | Linea | `0xe6a7E3d26B898e96fA8bC00fFE6e51b25Dc24d6a` |
| 534352 | Scroll | `0x06c3c00dc556d2493A661E6a929d3E17f5F097a4` |

Adding a chain:

1. Add the RPC to `foundry.toml`'s `[rpc_endpoints]` block.
2. Add the Primus verifier address to `script/DeployTestnet.s.sol`'s
   `primusVerifierFor` mapping.
3. Add a chain-specific entry to `sdk/src/addresses.ts` (the SDK currently
   only pins Base Sepolia).
4. Deploy + update.

---

## 5.7 BaseScan source verification (recommended but not yet done)

For a public-facing deployment you'd want the hook + verifier source
verified on BaseScan so users can read the code there:

```bash
forge verify-contract \
  --rpc-url https://sepolia.base.org \
  --etherscan-api-key $BASESCAN_API_KEY \
  --chain-id 84532 \
  --compiler-version 0.8.28 \
  --num-of-optimizations 200 \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
    0x2cF22D4013F7228090c6a77B134114aD0761C138 \
    0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE) \
  0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A \
  lib/hook-contracts/contracts/hooks/ZkTlsAttestationHook.sol:ZkTlsAttestationHook
```

We have not done this yet — it's tracked as a future task. Source code
matching the bytecode is in our git repo regardless, and bytecode
equivalence was empirically confirmed (see
[06-testing](06-testing.md) §"Bytecode equivalence check").

---

Continue to [06 — Testing](06-testing.md) for the test running guide.
