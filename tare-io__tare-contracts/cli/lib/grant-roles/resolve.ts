import { castCall, readContractAddress, getSenderAddress, isContract, type ResolvedDeployment } from "../cast.js"
import { getThreshold, hasRole, isOwner, isSafe } from "../onchain.js"
import type { GrantRolesContext, GrantRolesManifest } from "./types.js"

/** Resolve protocol addresses from deployment artifacts and assemble the shared context. */
export function resolveGrantRolesContext(
  deployment: ResolvedDeployment,
  manifest: GrantRolesManifest
): GrantRolesContext {
  const { root, config } = deployment
  return {
    loans: readContractAddress(root, config, "loans", "Loans"),
    portfolioVault: readContractAddress(root, config, "vault", "PortfolioVault"),
    navCalculator: readContractAddress(root, config, "vault", "NavCalculator"),
    vaultShareToken: readContractAddress(root, config, "vault", "VaultShareToken"),
    timelock: readContractAddress(root, config, "timelock", "TimelockController"),
    proposerSafe: manifest.proposerSafe,
    manifest,
    deployment,
    sender: getSenderAddress(deployment),
  }
}

/**
 * Strict pre-flight assertions. Collects every violation and throws once.
 * Run before any encoding or scheduling.
 */
export function assertGrantRolesPreconditions(ctx: GrantRolesContext): void {
  const { deployment } = ctx
  const errors: string[] = []

  // 1. All five protocol targets must be deployed (non-empty bytecode).
  const protocolTargets: [string, string][] = [
    [ctx.loans, "Loans"],
    [ctx.portfolioVault, "PortfolioVault"],
    [ctx.navCalculator, "NavCalculator"],
    [ctx.vaultShareToken, "VaultShareToken"],
    [ctx.timelock, "TimelockController"],
  ]
  for (const [address, label] of protocolTargets) {
    if (!isContract(address, deployment)) {
      errors.push(`${label} has no bytecode at ${address}`)
    }
  }

  // 2. Every grantee Safe / smart account must be a Gnosis Safe.
  const safeTargets: [string, string][] = [
    [ctx.proposerSafe, "proposerSafe"],
    [ctx.manifest.whitelisterSafe, "whitelisterSafe"],
    [ctx.manifest.originatorSa, "originatorSa"],
    [ctx.manifest.portfolioManagerSa, "portfolioManagerSa"],
    [ctx.manifest.investorManagerSa, "investorManagerSa"],
    [ctx.manifest.calculatingAgentSa, "calculatingAgentSa"],
  ]
  for (const [address, label] of safeTargets) {
    if (!isSafe(address, deployment)) {
      errors.push(`${label} is not a Gnosis Safe (getOwners() failed) at ${address}`)
    }
  }

  // 3. proposerSafe must hold PROPOSER_ROLE on the timelock.
  if (isContract(ctx.timelock, deployment)) {
    const proposerRole = castCall(ctx.timelock, "PROPOSER_ROLE()(bytes32)", [], deployment)
    if (!hasRole(ctx.timelock, proposerRole, ctx.proposerSafe, deployment)) {
      errors.push(`proposerSafe ${ctx.proposerSafe} does not hold PROPOSER_ROLE on the timelock`)
    }
  }

  // 4. SafeExec requirements: sender owns proposerSafe and its threshold is 1.
  if (isSafe(ctx.proposerSafe, deployment)) {
    if (!isOwner(ctx.proposerSafe, ctx.sender, deployment)) {
      errors.push(`sender ${ctx.sender} is not an owner of proposerSafe ${ctx.proposerSafe}`)
    }
    const threshold = getThreshold(ctx.proposerSafe, deployment)
    if (threshold !== 1) {
      errors.push(`proposerSafe threshold is ${threshold}, expected 1 (SafeExec requires threshold == 1)`)
    }
  }

  if (errors.length > 0) {
    throw new Error(`grant-roles precondition check failed:\n  - ${errors.join("\n  - ")}`)
  }
}
