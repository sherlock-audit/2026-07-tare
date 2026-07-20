import type { Command } from "commander"
import { resolveDeployment, readContractAddress, castCall, castSend, getSenderAddress } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import { logProgress } from "../lib/utils.js"
import { castSendUnlocked, withImpersonation } from "../lib/anvil-rpc.js"
import { readRolesManifest, rolesManifestPath, requireManifestField } from "../lib/roles-manifest.js"

/** Default funding set, in whole USDC — the amounts the baked snapshot has always shipped. */
const DEFAULT_FUNDING = [
  { field: "investorSa", usdc: 100_000_000n },
  { field: "borrowerSa", usdc: 1_000_000n },
  { field: "shareholderSa", usdc: 100_000_000n },
] as const

export function registerFundUsdc(program: Command): void {
  program
    .command("fund-usdc")
    .description(
      "Mint USDC to role smart accounts (anvil only). Defaults to the roles-manifest set: investor 100M, borrower 1M, shareholder 100M."
    )
    .option("--to <address>", "Fund a single address instead of the default set")
    .option("--amount <usdc>", "Amount in whole USDC (required with --to)")
    .option("--input <path>", "Roles manifest path (default: derived roles/latest.json)")
    .option(
      "--impersonate-master-minter",
      "Forked mainnet USDC: impersonate Circle's masterMinter to configure the sender as a minter first"
    )
    .action(function (
      this: Command,
      opts: { to?: string; amount?: string; input?: string; impersonateMasterMinter?: boolean }
    ) {
      const cmd = this
      const deployment = resolveDeployment(cmd)
      const { root, config } = deployment
      const usdc = readContractAddress(root, config, "loans", "USDC")

      let targets: { label: string; address: string; units: string }[]
      if (opts.to) {
        if (!opts.amount) throw new Error("--amount is required with --to")
        targets = [{ label: opts.to, address: opts.to, units: (BigInt(opts.amount) * 1_000_000n).toString() }]
      } else {
        const manifestPath = rolesManifestPath(root, config, opts.input)
        const manifest = readRolesManifest(manifestPath)
        targets = DEFAULT_FUNDING.map(({ field, usdc: amount }) => ({
          label: field,
          address: requireManifestField(manifest, field, manifestPath),
          units: (amount * 1_000_000n).toString(),
        }))
      }

      if (opts.impersonateMasterMinter) {
        // Real USDC has no public mint — configure the sender as a minter with a
        // generous allowance (1B USDC) from Circle's masterMinter, then mint normally.
        const sender = getSenderAddress(deployment)
        const masterMinter = castCall(usdc, "masterMinter()(address)", [], deployment)
        logProgress(`Configuring ${sender} as USDC minter via masterMinter ${masterMinter}`)
        withImpersonation(masterMinter, deployment, () =>
          castSendUnlocked(
            masterMinter,
            usdc,
            "configureMinter(address,uint256)",
            [sender, "1000000000000000"],
            deployment
          )
        )
      }

      const minted: Record<string, { address: string; units: string; txHash: string; balance: string }> = {}
      for (const target of targets) {
        logProgress(`Minting ${target.units} USDC units to ${target.label}`)
        const { txHash } = castSend(usdc, "mint(address,uint256)", [target.address, target.units], deployment)
        const balance = castCall(usdc, "balanceOf(address)(uint256)", [target.address], deployment)
        minted[target.label] = { address: target.address, units: target.units, txHash, balance }
      }

      outputResult(cmd, { status: "ok", command: "fund-usdc", data: { usdc, minted } })
    })
}
