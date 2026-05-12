import type { Address } from "./types.js";

/**
 * Live deployments on Base Sepolia (chainId 84532).
 *
 * Pinning these as constants in the SDK lets every demo script, every doc
 * snippet, and every consumer talk about the same on-chain reality without
 * re-typing 40-character addresses. To redeploy and refresh, update both
 * this file and `docs/05-deployment.md`.
 *
 * All addresses are checksummed.
 */

export const baseSepolia = {
  chainId: 84532,
  rpcUrl: "https://sepolia.base.org",
  basescanUrl: "https://sepolia.basescan.org",

  /** Primus PrimusZKTLS verifier — operated by Primus, pre-existing. */
  primusVerifier: "0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE" as Address,

  /** ERC-8183 core (UUPS proxy). Deployed by this toolkit, owned by deployer. */
  erc8183Core: "0x2cF22D4013F7228090c6a77B134114aD0761C138" as Address,
  /** ERC-8183 implementation behind the proxy. */
  erc8183Impl: "0xa76a62721Ffd0f90403dEBDB0ED14C484daD1C23" as Address,

  /** Mock USDC payment token (6 decimals). */
  mockUsdc: "0xC4980666C64C570FdC31e3a3c9eEbf441d99f0A4" as Address,

  /** The vendor-neutral zkTLS attestation hook. */
  hook: "0xd954517B4C4f0D3A9be69F4d4e2Cbc6f30ed9D1A" as Address,

  /**
   * Reference `LLMAnswerLengthVerifier` instances. Both target step index 1
   * (the LLM step in our demos) and key `"answer"`; they differ only in the
   * byte-length band they enforce.
   */
  llmAnswerLengthVerifier_loose: "0x1145636e77f107212dd3c76b0d43ec53dcc5e393" as Address,
  llmAnswerLengthVerifier_tight: "0x8fcd75c11068d09ca775762290516bd33374074f" as Address,
} as const;

/** Stable identities used in the demo lifecycle. */
export const demoWallets = {
  /** Plays admin + client + evaluator in the demo flows. */
  deployer: "0x89BBf3451643eef216c3A60d5B561c58F0D8adb9" as Address,
  /** Plays the provider role (must differ from client per ERC-8183). */
  provider: "0xe8e923c3bAAD4298fC7BfF78a06f7F63C09dE955" as Address,
} as const;
