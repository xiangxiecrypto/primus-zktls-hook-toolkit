/**
 * On-chain end-to-end lifecycle on Base Sepolia.
 *
 * Walks createJob → fund(spec) → submit(attestations) → complete, signing
 * real transactions from real wallets:
 *
 *   - deployer (PRIVATE_KEY)  acts as admin, client, and evaluator
 *   - provider (PROVIDER_KEY) is a separate keypair (ERC8183 disallows
 *                             client == provider)
 *
 * Required env:
 *   PRIVATE_KEY        - deployer/client/evaluator
 *   PROVIDER_KEY       - provider role
 *   PRIMUS_APP_ID      - Primus SaaS credentials
 *   PRIMUS_APP_SECRET
 *
 * Contract addresses are baked in from the prior DeployTestnet.s.sol run.
 * Re-deploy and update CORE / HOOK / USDC if the addresses change.
 */

import { PrimusCoreTLS } from "@primuslabs/zktls-core-sdk";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount as pkToAccount } from "viem/accounts";
import { runJob, createPrimusAttestor, buildSpec } from "../src/index.js";
import { encodeFundOptParams } from "../src/encoding.js";
import type { JobDefinition } from "../src/types.js";

// Live addresses live in src/addresses.ts; imported here so the demo script
// and downstream consumers reference one source of truth.
import { baseSepolia } from "../src/addresses.js";
const CORE = baseSepolia.erc8183Core;
const HOOK = baseSepolia.hook;
const USDC = baseSepolia.mockUsdc;

// Hand-rolled ABI for the four lifecycle calls we make.
const erc8183Abi = [
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
  {
    type: "function",
    name: "getJob",
    inputs: [{ name: "jobId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "client", type: "address" },
          { name: "status", type: "uint8" },
          { name: "provider", type: "address" },
          { name: "expiredAt", type: "uint48" },
          { name: "evaluator", type: "address" },
          { name: "submittedAt", type: "uint48" },
          { name: "budget", type: "uint256" },
          { name: "hook", type: "address" },
          { name: "paymentToken", type: "address" },
          { name: "providerAgentId", type: "uint256" },
          { name: "description", type: "string" },
        ],
      },
    ],
    stateMutability: "view",
  },
] as const;

const hookAbi = [
  {
    type: "function",
    name: "isValidated",
    inputs: [{ name: "jobId", type: "uint256" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const;

async function main() {
  const appId = req("PRIMUS_APP_ID");
  const appSecret = req("PRIMUS_APP_SECRET");
  const deployerKey = req("PRIVATE_KEY") as `0x${string}`;
  const providerKey = req("PROVIDER_KEY") as `0x${string}`;

  const deployer = pkToAccount(deployerKey);
  const provider = pkToAccount(providerKey);

  console.log("deployer (client+evaluator):", deployer.address);
  console.log("provider                  :", provider.address);

  const transport = http("https://sepolia.base.org");
  const publicClient = createPublicClient({ chain: baseSepolia, transport });
  const deployerWallet = createWalletClient({ account: deployer, chain: baseSepolia, transport });
  const providerWallet = createWalletClient({ account: provider, chain: baseSepolia, transport });

  // ----- 1) createJob (client) — or reuse an existing one ---------------------

  let jobId: bigint;
  if (process.env.JOB_ID) {
    jobId = BigInt(process.env.JOB_ID);
    console.log("\n[1/5] Reusing existing job:", jobId.toString());
  } else {
    // Give ourselves an hour of slack — the hook compares att.timestamp/1000
    // against block.timestamp under maxAge=3600.
    const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 24 * 3600);

    console.log("\n[1/5] createJob...");
    const createTx = await deployerWallet.writeContract({
      address: CORE,
      abi: erc8183Abi,
      functionName: "createJob",
      args: [provider.address, deployer.address, Number(expiredAt), "Primus zkTLS hook demo", HOOK, 0n],
    });
    console.log("  tx:", basescan(createTx));
    const receipt = await publicClient.waitForTransactionReceipt({ hash: createTx });

    // Parse the JobCreated event from the receipt logs — more reliable than
    // re-reading `jobCounter`, which can lag behind on load-balanced RPCs.
    const jobCreatedTopic =
      "0x" +
      // keccak256("JobCreated(uint256,address,address,address,uint48,address)")
      "c2ad77b7e2eb19c1eaadb0e0a96f8e89c2c1e0bfc4d72d3b0c5b73aebe1b6c70";
    void jobCreatedTopic;
    // Indexed jobId is in topics[1] of the JobCreated log. Find the log
    // whose address is the core contract.
    const log = receipt.logs.find(l => l.address.toLowerCase() === CORE.toLowerCase());
    if (!log) throw new Error("createJob: no log from core contract");
    jobId = BigInt(log.topics[1]!);
    console.log("  jobId:", jobId.toString());
  }

  // ----- 2) Generate real Primus attestation w/ provider as recipient ---------

  console.log("\n[2/5] Generating real Primus attestation (with retries)...");
  const job: JobDefinition = {
    steps: [{
      method: "GET",
      url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
      header: { "user-agent": "Mozilla/5.0" },
      responseResolves: [
        { keyName: "btc_usd", parseType: "json", parsePath: "$.bitcoin.usd" },
      ],
      attMode: "proxytls",
      maxAgeSeconds: 3600,
    }],
    bindings: [],
  };

  const primus = new PrimusCoreTLS();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  await primus.init(appId, appSecret, "auto" as any);

  // Primus SaaS occasionally returns transient "unstable internet" errors —
  // retry a few times with backoff before giving up.
  const attResult = await retry(
    () => runJob(job, { recipient: provider.address, attestor: createPrimusAttestor(primus) }),
    { attempts: 4, backoffMs: 3000 },
  );
  const { attestations, deliverable, submitOptParams } = attResult;
  console.log("  attested data:", attestations[0]!.data);
  console.log("  attestor     :", attestations[0]!.attestors[0]?.attestorAddr);

  // ----- 3) fund (client) — passes the spec to the hook -----------------------

  const spec = buildSpec(job);
  const fundOptParams = encodeFundOptParams(spec);

  console.log("\n[3/4] fund (client locks spec into hook)...");
  const fundTx = await deployerWallet.writeContract({
    address: CORE,
    abi: erc8183Abi,
    functionName: "fund",
    args: [jobId, 0n, fundOptParams],
  });
  console.log("  tx:", basescan(fundTx));
  await publicClient.waitForTransactionReceipt({ hash: fundTx });

  // ----- 4) submit (provider) — passes the real attestation to the hook -------

  console.log("\n[4/4] submit (provider — runs hook + real Primus verifier)...");
  const submitTx = await providerWallet.writeContract({
    address: CORE,
    abi: erc8183Abi,
    functionName: "submit",
    args: [jobId, deliverable, submitOptParams],
  });
  console.log("  tx:", basescan(submitTx));
  await publicClient.waitForTransactionReceipt({ hash: submitTx });

  // ----- 5) complete (evaluator) ----------------------------------------------

  console.log("\n[5/5] complete (evaluator)...");
  const completeTx = await deployerWallet.writeContract({
    address: CORE,
    abi: erc8183Abi,
    functionName: "complete",
    args: [jobId, "0x0000000000000000000000000000000000000000000000000000000000000000", "0x"],
  });
  console.log("  tx:", basescan(completeTx));
  await publicClient.waitForTransactionReceipt({ hash: completeTx });

  // ----- Verify final state ---------------------------------------------------

  const validated = await publicClient.readContract({
    address: HOOK,
    abi: hookAbi,
    functionName: "isValidated",
    args: [jobId],
  });
  const finalJob = await publicClient.readContract({
    address: CORE,
    abi: erc8183Abi,
    functionName: "getJob",
    args: [jobId],
  });

  console.log("\n=== Final state ===");
  console.log("hook.isValidated(jobId):", validated);
  console.log("job.status (4 = Completed, 3 = Submitted):", finalJob.status);
  console.log("\nDone. Job lifecycle ran end-to-end on Base Sepolia.");
  console.log("Provider:", basescan(provider.address as Address, "address"));
  console.log("Hook    :", basescan(HOOK as Address, "address"));

  process.exit(0);
}

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
      console.log(`  attempt ${i + 1}/${opts.attempts} failed: ${msg.slice(0, 80)}`);
      if (i < opts.attempts - 1) {
        await new Promise(r => setTimeout(r, opts.backoffMs * (i + 1)));
      }
    }
  }
  throw lastErr;
}

function basescan(h: `0x${string}`, kind: "tx" | "address" = "tx"): string {
  return `https://sepolia.basescan.org/${kind}/${h}`;
}

main().catch(err => {
  console.error("\nFAILED:", err?.shortMessage ?? err?.message ?? err);
  if (err?.cause) console.error("cause :", err.cause);
  if (err?.metaMessages) console.error("meta  :", err.metaMessages);
  process.exit(1);
});
