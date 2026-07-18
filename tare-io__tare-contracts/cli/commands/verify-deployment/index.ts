import type { Command } from "commander"
import chalk from "chalk"
import { getAddress, type Address } from "viem"
import { DEFAULT_ANVIL_ADDR, getDeploymentConfig, getChainConfig } from "../../lib/deployment-configs.js"
import { DEFAULT_ANVIL_RPC } from "../../lib/constants.js"
import { loadDeploymentManifest } from "../../lib/utils.js"
import { rolesManifestPath } from "../../lib/roles-manifest.js"
import { loadSetupManifest, smartAccountsFromManifest } from "../../lib/setup-smart-accounts/manifest.js"
import { collectVerificationFailures, verifySmartAccountsSetup } from "../../lib/setup-smart-accounts/verification.js"
import type { SetupContext } from "../../lib/setup-smart-accounts/types.js"
import type { GlobalOpts } from "../../lib/cast.js"
import { Checker } from "./checker.js"
import { verifyManifests, verifyDeployment, verifyWiring, verifyConfiguration, verifyTimelock } from "./phases.js"
import { printResults } from "./output.js"
import type { DeploymentManifest, Addresses, Addr, TimelockExpectations } from "./types.js"

function addr(manifest: DeploymentManifest | null, key: string): Addr {
  return (manifest?.contracts[key] as Addr) ?? ""
}

export function registerVerifyDeployment(program: Command): void {
  program
    .command("verify-deployment")
    .description("Verify deployed contracts are properly wired, configured, and accessible")
    .option("-r, --rpc-url <url>", "RPC URL", process.env.ANVIL_RPC ?? DEFAULT_ANVIL_RPC)
    .option("--admin <address>", "Expected admin address")
    .option("--guardian <address>", "Expected guardian address (defaults to deployment config guardian)")
    .option(
      "--deployer <address>",
      "Deployer EOA — asserted to no longer hold privileged roles (default: anvil EOA for foundry, $DEPLOYER_ADDR otherwise; required)"
    )
    .option(
      "--recovery-address <address>",
      "Expected Rescuable recoveryAddress (defaults to guardian, matching DEPLOY_RECOVERY_ADDRESS default)"
    )
    .option(
      "--whitelister <address>",
      "Expected VaultShareToken WHITELISTER_ROLE holder — if equal to --deployer the deployer-renounce check is skipped"
    )
    .option("--timelock-min-delay <seconds>", "Expected TimelockController minDelay in seconds")
    .option("--sa-threshold <n>", "Expected role smart-account threshold (production: 2; local dev: 1)", "2")
    .option(
      "--sa-allow-extra-owners",
      "Verify the expected SA owner set as a subset instead of the exact set (local dev keeps the deployer as an owner)"
    )
    .action(async function (
      this: Command,
      opts: {
        rpcUrl: string
        admin?: string
        guardian?: string
        deployer?: string
        recoveryAddress?: string
        whitelister?: string
        timelockMinDelay?: string
        saThreshold: string
        saAllowExtraOwners?: boolean
      }
    ) {
      const globals = this.optsWithGlobals() as GlobalOpts
      const { name, chain, root } = globals
      const jsonOutput = globals.json ?? false

      const deploymentName = `${chain ?? "foundry"}-${name}`
      const deploymentConfig = getDeploymentConfig(deploymentName)

      const rawAdmin = opts.admin ?? deploymentConfig.admin
      if (!rawAdmin) throw new Error("admin address is required (--admin or deployment config)")
      const resolvedAdmin = getAddress(rawAdmin)
      const resolvedGuardian = getAddress(opts.guardian ?? deploymentConfig.guardian ?? rawAdmin)

      const rawDeployer =
        opts.deployer ?? (deploymentConfig.chain === "foundry" ? DEFAULT_ANVIL_ADDR : process.env.DEPLOYER_ADDR)
      if (!rawDeployer) throw new Error("deployer address is required (--deployer or $DEPLOYER_ADDR)")
      const resolvedDeployer = getAddress(rawDeployer)
      const resolvedRecoveryAddress = getAddress(opts.recoveryAddress ?? resolvedGuardian)
      const resolvedWhitelister = opts.whitelister ? getAddress(opts.whitelister) : undefined

      const saThreshold = Number.parseInt(opts.saThreshold, 10)
      if (!Number.isInteger(saThreshold) || saThreshold < 1 || saThreshold > 3) {
        throw new Error(`Invalid --sa-threshold: ${opts.saThreshold}`)
      }

      const chainConfig = getChainConfig(deploymentConfig.chain)
      const rpcUrl = opts.rpcUrl !== DEFAULT_ANVIL_RPC ? opts.rpcUrl : (chainConfig.rpc() ?? opts.rpcUrl)

      console.log(chalk.bold(`Verifying deployment: ${deploymentName}`))
      console.log(chalk.dim(`Chain: ${deploymentConfig.chain} | RPC: ${rpcUrl}`))
      console.log(
        chalk.dim(
          `Admin: ${resolvedAdmin} | Guardian: ${resolvedGuardian} | Recovery: ${resolvedRecoveryAddress} | Deployer: ${resolvedDeployer}`
        )
      )

      const loans = loadDeploymentManifest(root, deploymentConfig.chain, deploymentConfig.shortName, "loans", true)
      const accounts = loadDeploymentManifest(
        root,
        deploymentConfig.chain,
        deploymentConfig.shortName,
        "accounts",
        true
      )
      const vault = loadDeploymentManifest(root, deploymentConfig.chain, deploymentConfig.shortName, "vault", true)
      const timelock = loadDeploymentManifest(
        root,
        deploymentConfig.chain,
        deploymentConfig.shortName,
        "timelock",
        true
      )

      const addresses: Addresses = {
        loans: addr(loans, "Loans"),
        loansNFT: addr(loans, "LoansNFT"),
        exchange: addr(loans, "LoansExchange"),
        usdc: addr(loans, "USDC"),
        trustedCalls: addr(accounts, "TrustedCalls"),
        trustedSpender: addr(accounts, "TrustedSpender"),
        saf: addr(accounts, "SmartAccountFactory"),
        safeSingleton: addr(accounts, "SafeSingleton"),
        safeProxyFactory: addr(accounts, "SafeProxyFactory"),
        navCalculator: addr(vault, "NavCalculator"),
        vaultShareToken: addr(vault, "VaultShareToken"),
        portfolioVault: addr(vault, "PortfolioVault"),
        timelock: addr(timelock, "TimelockController"),
      }

      const timelockExpectations: TimelockExpectations = {
        minDelay: opts.timelockMinDelay !== undefined ? BigInt(opts.timelockMinDelay) : undefined,
      }

      const checker = new Checker(rpcUrl)
      verifyManifests(checker, loans, accounts, vault, timelock)
      const deployed = await verifyDeployment(checker, addresses)
      await verifyWiring(checker, addresses, deployed)
      await verifyConfiguration(
        checker,
        addresses,
        deployed,
        resolvedAdmin,
        resolvedGuardian,
        resolvedRecoveryAddress,
        resolvedDeployer,
        resolvedWhitelister
      )
      await verifyTimelock(checker, {
        timelock: addresses.timelock,
        timelockManifest: timelock,
        expectations: timelockExpectations,
      })

      // Hard gate on smart-account state: the roles manifest is required — a
      // missing or invalid manifest means SA owners/thresholds cannot be
      // verified, so the gate fails rather than silently passing.
      const saSection = "5. smart accounts"
      try {
        const rolesManifest = loadSetupManifest(rolesManifestPath(root, deploymentConfig))
        const ctx: SetupContext = {
          loans: addresses.loans,
          usdc: addresses.usdc,
          trustedCalls: addresses.trustedCalls,
          trustedSpender: addresses.trustedSpender,
          loansNft: addresses.loansNFT,
          loansExchange: addresses.exchange,
          portfolioVault: addresses.portfolioVault,
          vaultShareToken: addresses.vaultShareToken,
          operationalManagementSafe: rolesManifest.operationalManagementSafe,
          hotProxy: rolesManifest.hotProxy,
          guardianSafe: rolesManifest.guardianSafe,
          offramp: rolesManifest.offramp,
          smartAccounts: smartAccountsFromManifest(rolesManifest),
          deployment: { config: deploymentConfig, chainConfig, rpcUrl, root },
          execOpts: { sender: resolvedDeployer }, // read-only verification — never sends
          finalThreshold: saThreshold,
          allowExtraOwners: opts.saAllowExtraOwners ?? false,
        }
        const verification = verifySmartAccountsSetup(ctx)
        const failures = collectVerificationFailures(verification, saThreshold)
        for (const failure of failures) checker.fail(saSection, failure, "postcondition not met")
        for (const role of Object.keys(verification)) {
          if (!failures.some((failure) => failure.startsWith(`[${role}]`))) {
            checker.pass(saSection, `${role} SA: owners, threshold, modules, delegates, approvals OK`)
          }
        }
      } catch (err) {
        checker.fail(saSection, "roles manifest loaded and role SAs verified", String(err))
      }

      printResults(checker.results, jsonOutput)
    })
}
