import type { Command } from "commander"
import { resolveDeployment } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import { NO_EXPIRY } from "../lib/constants.js"
import { deploySmartAccountViaFactory } from "../lib/smart-account.js"
import { writeRolesManifest } from "../lib/roles-manifest.js"

export function registerCreateSmartAccount(program: Command): void {
  program
    .command("create-smart-account")
    .description("Deploy a smart account via SmartAccountFactory")
    .requiredOption("--owners <addresses>", "Comma-separated owner addresses")
    .requiredOption("--threshold <number>", "Safe threshold")
    .option("--delegates <addresses>", "Comma-separated delegate addresses")
    .option("--currencies <addresses>", "Comma-separated currency addresses")
    .option(
      "--nft-collections <addresses>",
      "Comma-separated ERC721 collection addresses to pre-approve for TrustedSpender"
    )
    .option("--trusted-recipients <addresses>", "Comma-separated trusted recipient addresses")
    .option("--valid-until <uint48>", "Validity timestamp for allowances (defaults to no expiry)", NO_EXPIRY)
    .option("--manifest-key <field>", "Record the new SA in the roles manifest under this field (e.g. borrowerSa)")
    .action(function (
      this: Command,
      opts: {
        owners: string
        threshold: string
        delegates?: string
        currencies?: string
        nftCollections?: string
        trustedRecipients?: string
        validUntil: string
        manifestKey?: string
      }
    ) {
      const deployment = resolveDeployment(this)
      const { smartAccountAddress, factoryAddress, txHash } = deploySmartAccountViaFactory(deployment, opts)

      let manifestPath: string | undefined
      if (opts.manifestKey) {
        manifestPath = writeRolesManifest(deployment.root, deployment.config, {
          [opts.manifestKey]: smartAccountAddress,
        }).path
      }

      outputResult(this, {
        status: "ok",
        command: "create-smart-account",
        data: { smartAccountAddress, factoryAddress, ...(manifestPath ? { manifestPath } : {}) },
        txHash,
      })
    })
}
