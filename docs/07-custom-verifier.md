# 7. Custom verifiers (extension layer)

> **Audience.** Anyone who needs to enforce business invariants the hook's
> built-in checks cannot express — price bands, output-length constraints,
> threshold logic, cross-step aggregation, etc.

A **customVerifier** is a contract you write per-job (or per-use-case) that
plugs into the hook's `customVerifier` slot. The hook calls it after every
unified-layer check passes. If it reverts, the entire `submit` reverts.

This doc walks through writing one, using the deployed
`LLMAnswerLengthVerifier` as a worked example.

---

## 7.1 When you need a customVerifier (and when you don't)

| Constraint | Built into hook? | Needs customVerifier? |
|---|---|---|
| Provider really called URL X with method Y and body Z | yes (unified layer) | no |
| The response has exactly these fields parsed out | yes | no |
| Static value flowed from step N's data to step M's URL | yes (binding) | no |
| Deliverable hash = keccak(step M's data) | yes | no |
| Attestation isn't stale | yes (maxAge) | no |
| Attestor is the specific PADO signer we chose | yes (pinnedAttestor) | no |
| **The response price is between $X and $Y** | no | yes |
| **The LLM answer is at least 20 bytes** | no | yes |
| **Two prices from two exchanges agree within 5%** | no | yes |
| **A sum of multiple step values exceeds a threshold** | no | yes |
| **Dynamic per-execution data (e.g. a session token)** | no | yes (or skip the check) |

Anything that requires *interpreting* the bytes of `att.data` belongs in
a customVerifier, not the hook.

---

## 7.2 The interface

```solidity
interface IAttestationExtensionVerifier {
    function verify(
        uint256 jobId,
        bytes32 deliverable,
        Attestation[] calldata attestations,
        bytes calldata customCalldata
    ) external view;
}
```

Three things to know:

1. **It's `view`.** The hook calls it via `staticcall`. The EVM forbids
   state mutations during a staticcall, so even a malicious customVerifier
   cannot corrupt the hook's, the core's, or the verifier's storage.

2. **It receives everything.** The full `Attestation[]` array, the
   deliverable, the jobId, and any `customCalldata` the provider passed in
   via `encodeSubmitOptParams(atts, customCalldata)`.

3. **It signals failure by reverting.** Any revert (custom error, require
   failure, division by zero — anything) propagates to the hook as
   `staticcall` returning false, and the hook then reverts with
   `ExtensionVerifierFailed()`. The original revert reason is lost — only
   the wrapper error reaches the user.

---

## 7.3 Step-by-step: writing a customVerifier

### 7.3.1 Scope

Decide:

- **Which step's attestation** carries the data you want to check
  (`sourceStep`).
- **Which key** inside that step's `att.data` JSON contains the value
  (`keyName`).
- **What invariant** you want to enforce.

For the example here: `step 1` (the LLM step), `keyName = "answer"`,
invariant `byteLength ∈ [minBytes, maxBytes]`.

### 7.3.2 Imports

You only need two things from the hook contract: the `Attestation` struct
shape and the interface to implement.

```solidity
import {
    Attestation,
    IAttestationExtensionVerifier
} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";
```

This is the only file in the SDK that ever imports from the hook. Your
customVerifier deliberately does *not* depend on the core, on ERC-8183,
or on any other contract.

### 7.3.3 Skeleton

```solidity
contract MyVerifier is IAttestationExtensionVerifier {
    // Configuration — set in the constructor, ideally immutable.
    uint8 public immutable sourceStep;
    // … your params …

    // Errors — named for the specific failure case.
    error InvalidConfig();
    error WrongAttestationCount();
    error MyConstraintViolated();

    constructor(uint8 sourceStep_) {
        // … validate config …
        sourceStep = sourceStep_;
    }

    function verify(
        uint256 /*jobId*/,
        bytes32 /*deliverable*/,
        Attestation[] calldata attestations,
        bytes calldata /*customCalldata*/
    ) external view override {
        if (attestations.length <= sourceStep) revert WrongAttestationCount();
        // … your checks …
    }
}
```

Five suggestions:

- **Validate the constructor.** A wrong config baked into an
  un-upgradeable contract is permanently broken; revert clearly.
- **Bounds-check `sourceStep` against `attestations.length`** before
  indexing.
- **One revert per failure case.** Specific custom errors are vastly
  easier to debug than generic strings.
- **Don't read storage you don't need.** customVerifiers should be tiny;
  every SLOAD is gas the provider pays at submit time.
- **Stay deterministic.** Don't use `block.timestamp`, `block.coinbase`,
  or any state that varies between simulation and execution. The
  customVerifier's verdict should depend solely on the attestations and
  the constants in storage.

### 7.3.4 Worked example: `LLMAnswerLengthVerifier`

The full code is in `contracts/extensions/LLMAnswerLengthVerifier.sol`.
Annotated highlights:

```solidity
contract LLMAnswerLengthVerifier is IAttestationExtensionVerifier {
    uint8   public immutable sourceStep;     // which attestation has the answer
    string  public keyName;                  // JSON key holding the answer
    uint256 public immutable minBytes;       // inclusive lower bound
    uint256 public immutable maxBytes;       // inclusive upper bound

    error InvalidConfig();
    error WrongAttestationCount();
    error KeyNotFound();
    error UnterminatedString();
    error MalformedEscape();
    error AnswerTooShort();
    error AnswerTooLong();

    constructor(uint8 sourceStep_, string memory keyName_, uint256 min_, uint256 max_) {
        if (bytes(keyName_).length == 0) revert InvalidConfig();
        if (min_ > max_)                  revert InvalidConfig();
        sourceStep = sourceStep_;
        keyName    = keyName_;
        minBytes   = min_;
        maxBytes   = max_;
    }

    function verify(
        uint256, bytes32,
        Attestation[] calldata attestations,
        bytes calldata
    ) external view override {
        if (attestations.length <= sourceStep) revert WrongAttestationCount();
        uint256 len = _stringFieldLength(attestations[sourceStep].data, keyName);
        if (len < minBytes) revert AnswerTooShort();
        if (len > maxBytes) revert AnswerTooLong();
    }

    // Internal: parse `"keyName":"<value>"` out of a JSON string and
    // return the byte length of <value>, handling backslash escapes.
    function _stringFieldLength(string memory dataStr, string memory key)
        internal pure returns (uint256) { /* … */ }
}
```

Notes on the JSON-ish parsing:

- We do **not** ship a full JSON tokenizer. We scan for the literal
  substring `"<keyName>":"` and then read bytes until an unescaped quote.
- Backslash escapes (`\"`, `\\`, `\n`, …) are counted as 2 raw bytes each.
  For a length check this is the natural definition.
- Unterminated strings or trailing backslashes revert specifically — they
  don't silently parse to zero.

This is enough for well-formed LLM JSON. If you need full JSON semantics,
write your own parser (or accept that on-chain JSON parsing is generally
a bad idea and pre-process off-chain).

---

## 7.4 Wiring a customVerifier into a job

Three places it gets referenced:

```ts
// 1. Set in JobDefinition.customVerifier
import { baseSepolia } from "@primus-zktls/hook-sdk";

const job: JobDefinition = {
  steps: [...],
  bindings: [...],
  customVerifier: baseSepolia.llmAnswerLengthVerifier_loose,
};

// 2. Compiled into the AttestationSpec at fund time:
const fundOptParams = encodeFundOptParams(buildSpec(job));
await erc8183.fund(jobId, 0, fundOptParams);

// 3. Read by the hook at submit time:
//    hook._specs[jobId].customVerifier  →  staticcall(verify, …)
```

After fund, the customVerifier address is **locked in** for that job; you
can verify with:

```bash
cast call <hook-addr> \
  "getSpec(uint256)((bytes32,bytes32,bytes32,bytes32,bytes32,uint64,address)[],(uint8,uint8,uint8,bytes)[],uint8,address,bool)" \
  <jobId> --rpc-url https://sepolia.base.org
```

The fourth element of the tuple is `customVerifier`.

---

## 7.5 Demonstrating acceptance and rejection on chain

We deployed two `LLMAnswerLengthVerifier` instances on Base Sepolia for
this purpose:

| Address | Bounds | Outcome |
|---|---|---|
| [`0x1145…e393`](https://sepolia.basescan.org/address/0x1145636e77f107212dd3c76b0d43ec53dcc5e393) | [20, 800] bytes | typical DeepSeek answer (~115 bytes) passes |
| [`0x8fcd…074f`](https://sepolia.basescan.org/address/0x8fcd75c11068d09ca775762290516bd33374074f) | [1, 10] bytes | any LLM answer with normal content fails |

Run the **acceptance** path:

```bash
cd sdk
VERIFIER_ADDR=0x1145636e77f107212dd3c76b0d43ec53dcc5e393 \
PRIVATE_KEY=... PROVIDER_KEY=... \
PRIMUS_APP_ID=... PRIMUS_APP_SECRET=... \
LLM_URL=https://api.deepseek.com/v1 LLM_MODEL=deepseek-chat LLM_API_KEY=sk-... \
  pnpm tsx scripts/onchain-llm-with-verifier.ts
```

The hook validates and `isValidated(jobId) == true`.

Run the **rejection** path:

```bash
VERIFIER_ADDR=0x8fcd75c11068d09ca775762290516bd33374074f \
… same env …
  pnpm tsx scripts/onchain-llm-with-verifier.ts
```

The submit transaction reverts at preflight with
`ExtensionVerifierFailed()` (selector `0x6dffd34b`). Viem decodes this as
"submit reverted with unknown signature 0x6dffd34b" — that selector is the
hook's wrapper error around our customVerifier's underlying
`AnswerTooLong()`.

This is the full extension-layer round trip working on a real chain
against a real LLM response.

---

## 7.6 Deploying your customVerifier

A minimal Forge script:

```solidity
// script/DeployMyVerifier.s.sol
import {Script, console2} from "forge-std/Script.sol";
import {MyVerifier} from "../contracts/extensions/MyVerifier.sol";

contract DeployMyVerifier is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MyVerifier v = new MyVerifier(/* constructor args */);
        vm.stopBroadcast();
        console2.log("MyVerifier:", address(v));
    }
}
```

Deploy:

```bash
PRIVATE_KEY=0x... forge script script/DeployMyVerifier.s.sol:DeployMyVerifier \
  --rpc-url base_sepolia --broadcast
```

Then either:
- Use the new address directly in your `JobDefinition.customVerifier`.
- Add it to `sdk/src/addresses.ts` for ergonomic imports.

The hook does **not** need to whitelist customVerifiers — the spec author
(the client) chooses one, and it's the client's responsibility to choose
one they trust. There's no on-chain registry.

---

## 7.7 Patterns that work well

### Single-field threshold (the easiest pattern)

```
extract one numeric field → compare to a constant → revert if out of range
```

`LLMAnswerLengthVerifier` is this pattern.

### Cross-step comparison

```
extract one field from att[i] → extract another from att[j] → compare them
```

`PriceDeviationVerifier` (in `contracts/extensions/` for reference) is
this pattern: two prices, must agree within X basis points.

### Signed external claim

```
attestation carries a base64-encoded signature → recover signer →
require signer is a configured trusted address
```

Useful when the verifier wants to enforce "this answer was signed by an
oracle we trust". Combine with the attestation's
`att.attestors[0].attestorAddr` for double-cryptographic binding.

### Aggregation (sum / median / etc.)

```
extract one numeric field from each step → sum / median → compare to limit
```

Reasonable for ≤ 5 steps. For larger sets, prefer off-chain aggregation
with an oracle attestation.

---

## 7.8 Patterns to avoid

### Reading mutable state

A customVerifier that reads `block.timestamp`, oracle prices, or other
mutable on-chain state has a non-deterministic verdict — the simulation
result may diverge from the broadcast result. This breaks viem-style
preflight validation and is a footgun.

### Calling external contracts (other than read-only)

You can `staticcall` an oracle if you must, but understand: every external
call is a step on which the customVerifier can fail unrelated to the
attestation. Prefer pre-baked constants.

### Trying to enforce semantic correctness of LLM output

Detecting "the LLM was helpful" or "the LLM answered correctly" is not
something a Solidity contract can do. Use a customVerifier only for
structural / quantitative invariants. Semantic correctness belongs in the
evaluator's complete/reject decision.

---

## 7.9 Testing your customVerifier

Two layers, mirroring the toolkit's pattern:

1. **Solidity unit tests against a mocked hook setup.** See
   `test/integration/LLMAnswerLengthVerifier.t.sol` for a template — it
   tests the verifier through the **real** hook contract (so the
   staticcall + revert-wrapping path is exercised), but uses an
   always-accept mock zkTLS verifier so the test doesn't need real Primus
   signatures.

2. **An on-chain E2E** to confirm the verifier is callable in the wild.
   Add a scenario script under `sdk/scripts/` modelled on
   `onchain-llm-with-verifier.ts`.

The unit-test scaffold takes about 30 minutes; the on-chain run takes about
60 seconds and costs a few thousand gas.

---

Continue to [08 — Troubleshooting](08-troubleshooting.md) for the catalog
of gotchas we hit during the toolkit's development.
