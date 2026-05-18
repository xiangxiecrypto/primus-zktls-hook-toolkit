/**
 * Shared on-chain lifecycle runner for all the e2e demo scripts.
 *
 * Given a JobDefinition + signers + Primus credentials, walks the full
 * createJob → fund(spec) → submit(real attestation) → complete flow on
 * Base Sepolia and prints BaseScan links at each step.
 */

// The Primus SDK's WASM bridge opens raw WebSockets to api1.padolabs.org
// and emits unhandled `error` events on DNS / TCP failures, which would
// otherwise crash the process before our retry loop sees them. Swallow
// only DNS-class errors here; anything else propagates as usual.
process.on("uncaughtException", err => {
  const m = (err as { message?: string })?.message ?? String(err);
  const isDns =
    /ENOTFOUND|getaddrinfo|ECONNREFUSED|ECONNRESET|EAI_AGAIN/.test(m);
  if (isDns) {
    console.log(`  (swallowed primus transient: ${m.slice(0, 80)})`);
    return;
  }
  throw err;
});

import { PrimusCoreTLS } from "@primuslabs/zktls-core-sdk";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type WalletClient,
  type PublicClient,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { runJob, createPrimusAttestor, buildSpec } from "../../src/index.js";
import { encodeFundOptParams } from "../../src/encoding.js";
import type { JobDefinition } from "../../src/types.js";

/** Hand-rolled ABI subset for the lifecycle. */
export const erc8183Abi = [
  {
    type: "function",
    name: "createJob",
    inputs: [
      { name: "provider", type: "address" },
      { name: "evaluator", type: "address" },
      { name: "expiredAt", type: "uint48" },
      { name: "description", type: "string" },
      { name: "hook", type: "address" },
      { name: "providerAgentId", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "fund",
    inputs: [
      { name: "jobId", type: "uint256" },
      { name: "expectedBudget", type: "uint256" },
      { name: "optParams", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "submit",
    inputs: [
      { name: "jobId", type: "uint256" },
      { name: "deliverable", type: "bytes32" },
      { name: "optParams", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "complete",
    inputs: [
      { name: "jobId", type: "uint256" },
      { name: "reason", type: "bytes32" },
      { name: "optParams", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

export const hookAbi = [
  {
    type: "function",
    name: "isValidated",
    inputs: [{ name: "jobId", type: "uint256" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const;

export interface ScenarioConfig {
  /** Human-readable name printed at the start. */
  name: string;
  /** The job definition to attest + submit. */
  job: JobDefinition;
  /** Description string passed to createJob. */
  description: string;
}

export interface RunOpts {
  scenario: ScenarioConfig;
  core: Address;
  hook: Address;
  rpcUrl: string;
  /** If set, skip createJob and reuse this job id. */
  jobId?: bigint;
  /** ms backoff between Primus retries. */
  primusRetryMs?: number;
  primusRetryAttempts?: number;
}

export async function runScenario(opts: RunOpts) {
  const {
    scenario,
    core,
    hook,
    rpcUrl,
    primusRetryAttempts = 4,
    primusRetryMs = 3000,
  } = opts;

  const deployerKey = req("PRIVATE_KEY") as `0x${string}`;
  const providerKey = req("PROVIDER_KEY") as `0x${string}`;
  const appId = req("PRIMUS_APP_ID");
  const appSecret = req("PRIMUS_APP_SECRET");

  const deployer = privateKeyToAccount(deployerKey);
  const provider = privateKeyToAccount(providerKey);

  console.log("=== Scenario:", scenario.name, "===");
  console.log("deployer (client + evaluator):", deployer.address);
  console.log("provider                     :", provider.address);

  const transport = http(rpcUrl);
  const publicClient = createPublicClient({ chain: baseSepolia, transport });
  const deployerWallet = createWalletClient({ account: deployer, chain: baseSepolia, transport });
  const providerWallet = createWalletClient({ account: provider, chain: baseSepolia, transport });

  // 1) createJob (or reuse)
  let jobId: bigint;
  if (opts.jobId !== undefined) {
    jobId = opts.jobId;
    console.log("\n[1/5] reusing job id", jobId.toString());
  } else {
    const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 24 * 3600);
    console.log("\n[1/5] createJob...");
    const txHash = await deployerWallet.writeContract({
      address: core,
      abi: erc8183Abi,
      functionName: "createJob",
      args: [provider.address, deployer.address, Number(expiredAt), scenario.description, hook, 0n],
    });
    console.log("  tx:", basescanTx(txHash));
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    // JobCreated has the jobId as the first indexed param (topics[1]).
    const log = receipt.logs.find(l => l.address.toLowerCase() === core.toLowerCase());
    if (!log) throw new Error("createJob: no log from core contract");
    jobId = BigInt(log.topics[1]!);
    console.log("  jobId:", jobId.toString());
  }

  // 2) Build the per-job binding context. Must be derived BEFORE we call
  //    Primus — the binding hash needs to land in the signed attestation's
  //    additionParams so the v2 hook's _verifyOneStep finds it.
  const ctx = {
    jobId,
    hookAddress: hook,
    chainId: baseSepolia.id,
  };
  console.log("  job binding ctx :", { jobId: jobId.toString(), hookAddress: hook, chainId: baseSepolia.id });

  // 3) Real Primus attestation
  console.log("\n[2/5] generating real Primus attestation(s)...");
  const primus = new PrimusCoreTLS();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  await primus.init(appId, appSecret, "auto" as any);
  const attResult = await retry(
    () => runJob(scenario.job, {
      recipient: provider.address,
      attestor: createPrimusAttestor(primus),
      ctx,
    }),
    { attempts: primusRetryAttempts, backoffMs: primusRetryMs },
  );
  const { attestations, deliverable, submitOptParams } = attResult;
  attestations.forEach((a, i) => {
    console.log(`  step ${i}: ${a.request.method} ${truncate(a.request.url, 60)}`);
    console.log(`           data: ${truncate(a.data, 80)}`);
  });

  // 4) fund (client) — builds spec with the same ctx so spec hashes match
  //    the attestor-signed additionParams.
  const spec = buildSpec(scenario.job, ctx);
  const fundOptParams = encodeFundOptParams(spec);
  console.log("\n[3/5] fund (client locks spec into hook)...");
  const fundTx = await deployerWallet.writeContract({
    address: core,
    abi: erc8183Abi,
    functionName: "fund",
    args: [jobId, 0n, fundOptParams],
  });
  console.log("  tx:", basescanTx(fundTx));
  // Confirmations=2 ensures the fund tx is fully propagated across the
  // load-balanced public RPC before we issue the submit. Without this, the
  // submit's preflight simulation can land on a node that hasn't yet
  // observed the state change, surfacing as a phantom SpecNotConfigured.
  await publicClient.waitForTransactionReceipt({ hash: fundTx, confirmations: 2 });

  // 4) submit (provider)
  console.log("\n[4/5] submit (provider — hook runs against real Primus verifier)...");
  const submitTx = await providerWallet.writeContract({
    address: core,
    abi: erc8183Abi,
    functionName: "submit",
    args: [jobId, deliverable, submitOptParams],
  });
  console.log("  tx:", basescanTx(submitTx));
  await publicClient.waitForTransactionReceipt({ hash: submitTx });

  // 5) complete (evaluator)
  console.log("\n[5/5] complete (evaluator)...");
  const completeTx = await deployerWallet.writeContract({
    address: core,
    abi: erc8183Abi,
    functionName: "complete",
    args: [jobId, "0x0000000000000000000000000000000000000000000000000000000000000000", "0x"],
  });
  console.log("  tx:", basescanTx(completeTx));
  await publicClient.waitForTransactionReceipt({ hash: completeTx });

  const validated = await publicClient.readContract({
    address: hook,
    abi: hookAbi,
    functionName: "isValidated",
    args: [jobId],
  });

  console.log("\n=== Result ===");
  console.log("hook.isValidated(jobId):", validated);
  console.log("hook                   :", basescanAddr(hook));
  console.log("provider               :", basescanAddr(provider.address as Address));

  return { jobId, validated, attestations, deliverable };
}

// ----- helpers ---------------------------------------------------------------

function req(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env: ${name}`);
  return v;
}

async function retry<T>(
  fn: () => Promise<T>,
  opts: { attempts: number; backoffMs: number },
): Promise<T> {
  let lastErr: unknown;
  for (let i = 0; i < opts.attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      const msg = (e as { message?: string })?.message ?? String(e);
      console.log(`  attempt ${i + 1}/${opts.attempts} failed: ${msg.slice(0, 120)}`);
      if (i < opts.attempts - 1) await new Promise(r => setTimeout(r, opts.backoffMs * (i + 1)));
    }
  }
  throw lastErr;
}

function basescanTx(h: `0x${string}`): string {
  return `https://sepolia.basescan.org/tx/${h}`;
}
function basescanAddr(h: Address): string {
  return `https://sepolia.basescan.org/address/${h}`;
}
function truncate(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n - 1) + "…";
}

void (createPublicClient as unknown as (..._: unknown[]) => PublicClient);
void (createWalletClient as unknown as (..._: unknown[]) => WalletClient);
