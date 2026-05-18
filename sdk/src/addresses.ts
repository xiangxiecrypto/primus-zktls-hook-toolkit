import type { Address } from "./types.js";

/**
 * Live deployments on Base Sepolia (chainId 84532).
 *
 * The active addresses below are for the **v2 hook** — the
 * review-fixes deployment matching `feature/zktls-attestation-hook-review-fixes`
 * on xiangxiecrypto/hook-contracts. The constructor is 3-arg
 * `(erc8183Core, zkTlsVerifier, owner)` and the spec model includes
 * cross-job binding, quorum, dynamic data bindings, and the
 * trusted-extension allowlist.
 *
 * Historical v1 addresses are preserved under `baseSepoliaV1` so the
 * 5 completed v1 job lifecycles (jobs 2-7 on the old hook) remain
 * documentable.
 */

export const baseSepolia = {
  chainId: 84532,
  rpcUrl: "https://sepolia.base.org",
  basescanUrl: "https://sepolia.basescan.org",

  /** Primus PrimusZKTLS verifier — operated by Primus, pre-existing. Unchanged across v1/v2. */
  primusVerifier: "0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE" as Address,

  /** ERC-8183 core (UUPS proxy), v2 deployment. */
  erc8183Core: "0xe823C8f28C469D44FbD07294FBdc1F21eb7e7cC3" as Address,
  /** ERC-8183 implementation behind the v2 proxy. */
  erc8183Impl: "0x091Fefe9225ab565aEdFb4f5c965dd1c8928c36a" as Address,

  /** Mock USDC payment token (6 decimals), v2 deployment. */
  mockUsdc: "0xC2371E1af7497D4A4D91dB5dF99e2a91C5fd4Ed3" as Address,

  /** The vendor-neutral zkTLS attestation hook, v2 (review-fixes). */
  hook: "0xfB761Ad1bffa503bbEC1b39BAED4A6Bc2cf47bA3" as Address,

  /**
   * Reference `LLMAnswerLengthVerifier` instances, both wired against the
   * v2 hook and **already allowlisted** via
   * `setTrustedExtensionVerifier`. They target step index 1 and key
   * `"answer"`, differing only in the byte-length band.
   */
  llmAnswerLengthVerifier_loose: "0x3AE0316827f7855f4dcc2C5034CecdDfeF002183" as Address,
  llmAnswerLengthVerifier_tight: "0x0EA7F1FA6516Eca119644EC60c58F6DAA4ebb3Ed" as Address,
} as const;

/**
 * Historical v1 deployment (pre-review-fixes). Kept so the 5 completed
 * v1 lifecycles in `docs/05-deployment.md` remain inspectable. Cannot
 * accept new specs — the spec ABI shape has changed.
 */
export const baseSepoliaV1 = {
  chainId: 84532,
  hook: "0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A" as Address,
  erc8183Core: "0x2cF22D4013F7228090c6a77B134114aD0761C138" as Address,
  erc8183Impl: "0xa76a62721Ffd0f90403dEBDB0ED14C484daD1C23" as Address,
  mockUsdc: "0xC4980666C64C570FdC31e3a3c9eEbf441d99f0A4" as Address,
  llmAnswerLengthVerifier_loose: "0x1145636e77f107212dd3c76b0d43ec53dcc5e393" as Address,
  llmAnswerLengthVerifier_tight: "0x8fcd75c11068d09ca775762290516bd33374074f" as Address,
} as const;

/** Stable identities used in the demo lifecycle. Same across v1/v2. */
export const demoWallets = {
  /** Plays admin + client + evaluator in the demo flows; also the hook owner under v2. */
  deployer: "0x89BBf3451643eef216c3A60d5B561c58F0D8adb9" as Address,
  /** Plays the provider role (must differ from client per ERC-8183). */
  provider: "0xe8e923c3bAAD4298fC7BfF78a06f7F63C09dE955" as Address,
} as const;
