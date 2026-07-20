import type { Command } from "commander"
import { resolveDeployment, readContractAddress, getSenderAddress, type SafeExecOptions } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import { loadSetupManifest, smartAccountsFromManifest } from "../lib/setup-smart-accounts/manifest.js"
import {
  buildCommonSteps,
  buildLoansApprovalStep,
  buildOfframpStep,
  buildInvestorNftApprovalStep,
  buildInvestorExchangeRegistrationStep,
  buildShareholderSteps,
  buildOriginatorRegistrationSteps,
  buildOwnershipTransitionSteps,
} from "../lib/setup-smart-accounts/builders.js"
import { assertPreconditions } from "../lib/setup-smart-accounts/preconditions.js"
import { runSteps, groupSteps, lockedSaHint } from "../lib/setup-smart-accounts/runner.js"
import { logProgress } from "../lib/utils.js"
import { rolesManifestPath } from "../lib/roles-manifest.js"
import { collectVerificationFailures, verifySmartAccountsSetup } from "../lib/setup-smart-accounts/verification.js"
import {
  ROLES,
  type SetupContext,
  type StepDef,
  type CategorizedStepResult,
} from "../lib/setup-smart-accounts/types.js"

interface Phase {
  label: string
  /** SA whose threshold is diagnosed when a step in this phase fails. */
  smartAccount?: string
  defs: StepDef[]
}

/**
 * Deterministic phase order: all role-specific configuration runs before any
 * ownership transition, so a run that fails partway can be re-executed without
 * first reaching multisig quorum on a partially-handed-over SA.
 */
function buildPhases(ctx: SetupContext): Phase[] {
  const phases: Phase[] = []

  // Build common steps + role-specific steps for each of the eight SAs
  for (const role of ROLES) {
    const defs = buildCommonSteps(role, ctx)
    switch (role) {
      case "borrower": {
        defs.push(buildLoansApprovalStep(role, ctx))
        const offrampStep = buildOfframpStep(ctx)
        if (offrampStep) defs.push(offrampStep)
        break
      }
      case "investor":
        defs.push(
          buildLoansApprovalStep(role, ctx),
          buildInvestorNftApprovalStep(ctx),
          buildInvestorExchangeRegistrationStep(ctx)
        )
        break
      case "servicer":
        defs.push(buildLoansApprovalStep(role, ctx))
        break
      case "shareholder":
        defs.push(...buildShareholderSteps(ctx))
        break
    }

    phases.push({ label: `[${role}] configuration`, smartAccount: ctx.smartAccounts[role], defs })
  }

  // Add addresses in the originator's address book
  phases.push({
    label: "[originator] peer registrations",
    smartAccount: ctx.smartAccounts.originator,
    defs: buildOriginatorRegistrationSteps(ctx),
  })

  // Ownership transition phases
  for (const role of ROLES) {
    phases.push({
      label: `[${role}] ownership transition`,
      smartAccount: ctx.smartAccounts[role],
      defs: buildOwnershipTransitionSteps(role, ctx),
    })
  }

  return phases
}

export function registerSetupSmartAccounts(program: Command): void {
  program
    .command("setup-smart-accounts")
    .description(
      "Configure all eight role smart accounts from a manifest: hot-proxy delegation, approvals, vault wiring, address-book registrations, and the final ownership transition."
    )
    .option("--input <path>", "Path to the setup manifest JSON (default: derived roles/latest.json)")
    .option("--dry-run", "Check state without executing transactions")
    .option(
      "--skip-preconditions",
      "Skip strict bootstrap-state assertions (required to resume a partial or completed run)"
    )
    .option("--final-threshold <n>", "SA threshold after the ownership transition (local dev keeps 1)", "2")
    .option(
      "--allow-extra-owners",
      "Verify the expected owner set as a subset instead of the exact set (local dev keeps the deployer as an owner)"
    )
    .action(function (
      this: Command,
      opts: {
        input?: string
        dryRun?: boolean
        skipPreconditions?: boolean
        finalThreshold: string
        allowExtraOwners?: boolean
      }
    ) {
      const cmd = this
      const deployment = resolveDeployment(cmd)
      const { config, root } = deployment
      const sender = getSenderAddress(deployment)
      const execOpts: SafeExecOptions = { sender }
      const dryRun = opts.dryRun ?? false

      const finalThreshold = Number.parseInt(opts.finalThreshold, 10)
      if (!Number.isInteger(finalThreshold) || finalThreshold < 1 || finalThreshold > 3) {
        throw new Error(`Invalid --final-threshold: ${opts.finalThreshold}`)
      }

      const manifest = loadSetupManifest(rolesManifestPath(root, config, opts.input))

      const ctx: SetupContext = {
        loans: readContractAddress(root, config, "loans", "Loans"),
        usdc: readContractAddress(root, config, "loans", "USDC"),
        trustedCalls: readContractAddress(root, config, "accounts", "TrustedCalls"),
        trustedSpender: readContractAddress(root, config, "accounts", "TrustedSpender"),
        loansNft: readContractAddress(root, config, "loans", "LoansNFT"),
        loansExchange: readContractAddress(root, config, "loans", "LoansExchange"),
        portfolioVault: readContractAddress(root, config, "vault", "PortfolioVault"),
        vaultShareToken: readContractAddress(root, config, "vault", "VaultShareToken"),
        operationalManagementSafe: manifest.operationalManagementSafe,
        hotProxy: manifest.hotProxy,
        guardianSafe: manifest.guardianSafe,
        offramp: manifest.offramp,
        smartAccounts: smartAccountsFromManifest(manifest),
        deployment,
        execOpts,
        finalThreshold,
        allowExtraOwners: opts.allowExtraOwners ?? false,
      }

      const manifestData = {
        ...ctx.smartAccounts,
        operationalManagementSafe: ctx.operationalManagementSafe,
        hotProxy: ctx.hotProxy,
        guardianSafe: ctx.guardianSafe,
        offramp: ctx.offramp ?? null,
        dryRun,
      }

      // address → label map so human-readable output annotates each address
      // (owners, governance safes, role SAs) without cross-referencing the manifest.
      const addressLabels: Record<string, string> = {}
      for (const [role, address] of Object.entries(ctx.smartAccounts)) {
        addressLabels[address.toLowerCase()] = `${role} SA`
      }
      addressLabels[ctx.operationalManagementSafe.toLowerCase()] = "operationalManagementSafe"
      addressLabels[ctx.hotProxy.toLowerCase()] = "hotProxy"
      addressLabels[ctx.guardianSafe.toLowerCase()] = "guardianSafe"
      if (ctx.offramp) addressLabels[ctx.offramp.toLowerCase()] = "offramp"

      if (!opts.skipPreconditions) {
        logProgress("Checking bootstrap preconditions")
        assertPreconditions(ctx)
      }

      const allResults: CategorizedStepResult[] = []
      let errorMessage: string | undefined

      for (const phase of buildPhases(ctx)) {
        logProgress(`\n${phase.label}`)
        const results = runSteps(phase.defs, dryRun)
        allResults.push(...results)
        const failed = results.find((result) => result.status === "failed")
        if (failed) {
          const hint = phase.smartAccount ? lockedSaHint(phase.smartAccount, ctx) : undefined
          errorMessage = `${failed.step}: ${failed.error}${hint ? ` (${hint})` : ""}`
          break
        }
      }

      if (errorMessage) {
        outputResult(
          cmd,
          {
            status: "error",
            command: "setup-smart-accounts",
            data: {
              message: errorMessage,
              ...manifestData,
              steps: groupSteps(allResults),
            },
          },
          addressLabels
        )
        process.exit(1)
      }

      const verification = verifySmartAccountsSetup(ctx)

      // Fail closed: a completed run whose postconditions don't hold must not
      // exit 0. Dry-run legitimately observes pre-setup state, so it stays
      // informational.
      const failures = dryRun ? [] : collectVerificationFailures(verification, ctx.finalThreshold)
      if (failures.length > 0) {
        outputResult(
          cmd,
          {
            status: "error",
            command: "setup-smart-accounts",
            data: {
              message: `post-setup verification failed, ${failures.length} postcondition(s) not met: ${failures.join("; ")}`,
              failures,
              ...manifestData,
              steps: groupSteps(allResults),
              verification,
            },
          },
          addressLabels
        )
        process.exit(1)
      }

      outputResult(
        cmd,
        {
          status: "ok",
          command: "setup-smart-accounts",
          data: {
            ...manifestData,
            steps: groupSteps(allResults),
            verification,
          },
        },
        addressLabels
      )
    })
}
