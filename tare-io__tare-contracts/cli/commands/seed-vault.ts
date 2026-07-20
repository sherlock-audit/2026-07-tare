import type { Command } from "commander"
import {
  resolveDeployment,
  readContractAddress,
  castCall,
  castCalldata,
  castSend,
  getSenderAddress,
  safeExec,
} from "../lib/cast.js"
import { isZero } from "../lib/onchain.js"
import { outputResult } from "../lib/output.js"
import { logProgress } from "../lib/utils.js"
import { castSendUnlocked, withImpersonation } from "../lib/anvil-rpc.js"
import { readRolesManifest, rolesManifestPath, requireManifestField } from "../lib/roles-manifest.js"

export function registerSeedVault(program: Command): void {
  program
    .command("seed-vault")
    .description(
      "NAV bootstrap: donate a small USDC amount to the PortfolioVault and run updateNav once so the first approveDeposit does not revert with ZeroNav. The donation accrues to DEAD_SHARES — treat it as sunk."
    )
    .option("--input <path>", "Roles manifest path (default: derived roles/latest.json)")
    .option("--amount <usdc>", "Donation in whole USDC", "1")
    .option(
      "--impersonate",
      "Anvil only: run updateNav by impersonating the Investor Manager SA instead of the hot-proxy TrustedCalls path"
    )
    .action(function (this: Command, opts: { input?: string; amount: string; impersonate?: boolean }) {
      const cmd = this
      const deployment = resolveDeployment(cmd)
      const { root, config } = deployment

      const vault = readContractAddress(root, config, "vault", "PortfolioVault")
      const usdc = readContractAddress(root, config, "loans", "USDC")
      const trustedCalls = readContractAddress(root, config, "accounts", "TrustedCalls")
      const manifestPath = rolesManifestPath(root, config, opts.input)
      const manifest = readRolesManifest(manifestPath)
      const investorManagerSa = requireManifestField(manifest, "investorManagerSa", manifestPath)

      const lastNav = () => castCall(vault, "lastNav()(uint256)", [], deployment)
      if (!isZero(lastNav())) {
        outputResult(cmd, {
          status: "ok",
          command: "seed-vault",
          data: { vault, lastNav: lastNav(), status: "skipped", message: "lastNav is already non-zero" },
        })
        return
      }

      const amount = BigInt(opts.amount)
      if (amount <= 0n) throw new Error(`Invalid --amount: ${opts.amount}`)
      const units = (amount * 1_000_000n).toString()

      // MockUSDC has a public mint; real USDC (forks) does not — fall back to a
      // plain transfer from the sender's balance (fund-usdc mints it a minter).
      let donationTx: string
      let donationMethod: "mint" | "transfer"
      try {
        donationTx = castSend(usdc, "mint(address,uint256)", [vault, units], deployment).txHash
        donationMethod = "mint"
      } catch {
        logProgress("USDC mint unavailable; transferring from sender balance")
        donationTx = castSend(usdc, "transfer(address,uint256)", [vault, units], deployment).txHash
        donationMethod = "transfer"
      }

      // Curated loan list is empty at bootstrap, so a single updateNav(1)
      // finalizes in one call, setting lastNav = balanceOf(vault).
      const inner = castCalldata("updateNav(uint256)", ["1"])
      let updateNavTxs: string[]
      if (opts.impersonate) {
        updateNavTxs = [
          withImpersonation(investorManagerSa, deployment, () =>
            castSendUnlocked(investorManagerSa, vault, "updateNav(uint256)", ["1"], deployment)
          ),
        ]
      } else {
        // Production path: updateNav is on the TrustedCalls whitelist, so the
        // Hot-Proxy Safe (registered delegate) routes it through the Investor
        // Manager SA — the sender must be a hot-proxy owner.
        const hotProxy = requireManifestField(manifest, "hotProxy", manifestPath)
        const outer = castCalldata("executeTrustedCall(address,address,bytes)", [investorManagerSa, vault, inner])
        updateNavTxs = safeExec(hotProxy, trustedCalls, outer, deployment, {
          sender: getSenderAddress(deployment),
        }).txHashes
      }

      const nav = lastNav()
      if (isZero(nav)) {
        outputResult(cmd, {
          status: "error",
          command: "seed-vault",
          data: { message: "lastNav is still 0 after updateNav", vault, donationTx, updateNavTxs },
        })
        process.exit(1)
      }

      outputResult(cmd, {
        status: "ok",
        command: "seed-vault",
        data: { vault, donatedUsdc: opts.amount, donationMethod, donationTx, updateNavTxs, lastNav: nav },
      })
    })
}
