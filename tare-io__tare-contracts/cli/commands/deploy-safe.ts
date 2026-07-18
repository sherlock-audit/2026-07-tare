import type { Command } from "commander"
import { resolveDeployment, readContractAddress, castSend, castCalldata } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import { parseAddressList } from "../lib/utils.js"
import { ZERO_ADDRESS } from "../lib/constants.js"
import { writeRolesManifest } from "../lib/roles-manifest.js"

// keccak256("ProxyCreation(address,address)") — emitted by SafeProxyFactory v1.4.1
// with the new proxy address as the first (indexed) topic.
const PROXY_CREATION_TOPIC = "0x4f51faf6c4561ff95f067657e43439f0f856d97c04d9ec9070a6199ad418e235"

export function registerDeploySafe(program: Command): void {
  program
    .command("deploy-safe")
    .description("Deploy a plain Gnosis Safe via SafeProxyFactory (governance/stand-in Safe, not a role smart account)")
    .requiredOption("--owners <addresses>", "Comma-separated owner addresses")
    .requiredOption("--threshold <number>", "Safe threshold")
    .option("--salt <nonce>", "saltNonce for createProxyWithNonce (defaults to current timestamp)")
    .option(
      "--manifest-key <fields>",
      "Record the new Safe in the roles manifest under these comma-separated fields (e.g. proposerSafe,guardianSafe)"
    )
    .action(function (
      this: Command,
      opts: {
        owners: string
        threshold: string
        salt?: string
        manifestKey?: string
      }
    ) {
      const deployment = resolveDeployment(this)
      // Prefer the canonical Safe infra from the chain config (set for live chains
      // like avalanche, and present on a mainnet fork). Fall back to the deployed
      // `accounts` manifest for local chains (e.g. foundry) that redeploy Safe infra.
      const factoryAddress =
        deployment.chainConfig.safeProxyFactory ||
        readContractAddress(deployment.root, deployment.config, "accounts", "SafeProxyFactory")
      const singletonAddress =
        deployment.chainConfig.safeSingleton ||
        readContractAddress(deployment.root, deployment.config, "accounts", "SafeSingleton")

      const initializer = castCalldata("setup(address[],uint256,address,bytes,address,address,uint256,address)", [
        parseAddressList(opts.owners),
        opts.threshold,
        ZERO_ADDRESS,
        "0x",
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        "0",
        ZERO_ADDRESS,
      ])

      const saltNonce = opts.salt ?? Date.now().toString()

      const { txHash, receipt } = castSend(
        factoryAddress,
        "createProxyWithNonce(address,bytes,uint256)",
        [singletonAddress, initializer, saltNonce],
        deployment
      )

      const log = (receipt.logs as { topics: string[] }[]).find((l) => l.topics[0] === PROXY_CREATION_TOPIC)
      if (!log) throw new Error("ProxyCreation event not found in transaction receipt")

      const safeAddress = "0x" + log.topics[1].slice(26)

      let manifestPath: string | undefined
      if (opts.manifestKey) {
        const updates = Object.fromEntries(opts.manifestKey.split(",").map((field) => [field.trim(), safeAddress]))
        manifestPath = writeRolesManifest(deployment.root, deployment.config, updates).path
      }

      outputResult(this, {
        status: "ok",
        command: "deploy-safe",
        data: { safeAddress, factoryAddress, singletonAddress, ...(manifestPath ? { manifestPath } : {}) },
        txHash,
      })
    })
}
