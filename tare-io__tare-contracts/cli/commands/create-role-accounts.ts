import type { Command } from "commander"
import { resolveDeployment, isContract, type ResolvedDeployment } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import { logProgress } from "../lib/utils.js"
import { NO_EXPIRY } from "../lib/constants.js"
import { deploySmartAccountViaFactory } from "../lib/smart-account.js"
import { readRolesManifest, rolesManifestPath, writeRolesManifest } from "../lib/roles-manifest.js"

const SA_FIELDS = [
  "originatorSa",
  "borrowerSa",
  "investorSa",
  "servicerSa",
  "shareholderSa",
  "portfolioManagerSa",
  "investorManagerSa",
  "calculatingAgentSa",
] as const

const SAFE_FIELD_BY_OPTION = {
  opsMgmtSafe: "operationalManagementSafe",
  hotProxy: "hotProxy",
  guardianSafe: "guardianSafe",
  proposerSafe: "proposerSafe",
  whitelisterSafe: "whitelisterSafe",
} as const

interface Opts {
  opsMgmtSafe?: string
  hotProxy?: string
  guardianSafe?: string
  proposerSafe?: string
  whitelisterSafe?: string
  salt?: string
  offramp?: string
  owners?: string
  threshold: string
  delegates?: string
  currencies?: string
  trustedRecipients?: string
  validUntil: string
  output?: string
}

/**
 * Resolve every governance Safe field: explicit flag wins, else the value
 * already recorded in the roles manifest (by `deploy-safe --manifest-key` or
 * `manifest set`). All five must resolve; a flag contradicting the manifest is
 * caught by `writeRolesManifest`.
 */
function resolveSafes(
  opts: Opts,
  existing: Record<string, string> | null,
  manifestPath: string,
  deployment: ResolvedDeployment
): Record<string, string> {
  const resolved: Record<string, string> = {}
  const missing: string[] = []
  for (const [option, field] of Object.entries(SAFE_FIELD_BY_OPTION)) {
    const value = opts[option as keyof typeof SAFE_FIELD_BY_OPTION] ?? existing?.[field]
    if (!value) {
      missing.push(field)
      continue
    }
    if (!isContract(value, deployment)) {
      throw new Error(`${field} ${value} has no code on chain`)
    }
    resolved[field] = value
  }
  if (missing.length > 0) {
    throw new Error(
      `missing governance Safe(s): ${missing.join(", ")} — pass the flag(s) or record them in ${manifestPath} ` +
        `via 'deploy-safe --manifest-key' / 'manifest set'`
    )
  }
  return resolved
}

export function registerCreateRoleAccounts(program: Command): void {
  program
    .command("create-role-accounts")
    .description(
      "Create all eight role smart accounts via SmartAccountFactory and record them in the roles manifest (idempotent: roles already in the manifest are skipped)."
    )
    .option("--ops-mgmt-safe <address>", "Operational Management Safe (default: roles manifest)")
    .option("--hot-proxy <address>", "Hot-Proxy Safe (default: roles manifest)")
    .option("--guardian-safe <address>", "Multisig co-owner added during setup (default: roles manifest)")
    .option("--proposer-safe <address>", "Timelock proposer Safe (default: roles manifest)")
    .option("--whitelister-safe <address>", "Whitelister Safe (default: roles manifest)")
    .option("--salt <string>", "grant-roles operation salt (default: <chain>-<name>:setup-grants:v1)")
    .option("--offramp <address>", "Borrower offramp allowance target")
    .option("--owners <addresses>", "Initial SA owners (default: the Operational Management Safe)")
    .option("--threshold <n>", "Initial SA threshold", "1")
    .option("--delegates <addresses>", "Delegates configured at creation (local dev convenience)")
    .option("--currencies <addresses>", "Currencies approved at creation (local dev convenience)")
    .option("--trusted-recipients <addresses>", "Trusted recipients configured at creation (local dev convenience)")
    .option("--valid-until <uint48>", "Validity timestamp for allowances (defaults to no expiry)", NO_EXPIRY)
    .option("--output <path>", "Manifest path (default: derived roles/latest.json)")
    .action(function (this: Command, opts: Opts) {
      const deployment = resolveDeployment(this)
      const manifestPath = rolesManifestPath(deployment.root, deployment.config, opts.output)
      const existing = readRolesManifest(manifestPath)

      const safes = resolveSafes(opts, existing, manifestPath, deployment)
      const salt =
        opts.salt ?? existing?.salt ?? `${deployment.config.chain}-${deployment.config.shortName}:setup-grants:v1`
      const owners = opts.owners ?? safes.operationalManagementSafe

      const results: Record<string, { address: string; status: "created" | "skipped" }> = {}
      const created: Record<string, string> = {}
      for (const field of SA_FIELDS) {
        const recorded = existing?.[field]
        if (recorded) {
          results[field] = { address: recorded, status: "skipped" }
          continue
        }
        logProgress(`Creating ${field}`)
        const { smartAccountAddress } = deploySmartAccountViaFactory(deployment, {
          owners,
          threshold: opts.threshold,
          delegates: opts.delegates,
          currencies: opts.currencies,
          trustedRecipients: opts.trustedRecipients,
          validUntil: opts.validUntil,
        })
        created[field] = smartAccountAddress
        results[field] = { address: smartAccountAddress, status: "created" }
      }

      const { path, versionedPath } = writeRolesManifest(
        deployment.root,
        deployment.config,
        { ...safes, salt, ...(opts.offramp ? { offramp: opts.offramp } : {}), ...created },
        { output: opts.output }
      )

      outputResult(this, {
        status: "ok",
        command: "create-role-accounts",
        data: {
          manifestPath: path,
          versionedPath,
          salt,
          created: Object.keys(created).length,
          skipped: SA_FIELDS.length - Object.keys(created).length,
          accounts: results,
        },
      })
    })
}
