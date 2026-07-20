import { hasRole, isRegisteredForRole } from "../onchain.js"
import { Roles } from "../roles.js"
import type { RoleIds } from "./build.js"
import type { GrantCheck, GrantRolesContext } from "./types.js"

export function checksToRecord(checks: GrantCheck[]): Record<string, boolean> {
  return Object.fromEntries(checks.map((check) => [check.label, check.satisfied]))
}

/**
 * Evaluate the desired end state of all five grants. Used both as the
 * idempotency guard (before scheduling) and the post-execution verification.
 * The order matches the grant table.
 */
export function checkGrantedRoles(ctx: GrantRolesContext, roleIds: RoleIds): GrantCheck[] {
  const { manifest } = ctx
  return [
    {
      label: `Loans.isRegisteredForRole(Originator, ${manifest.originatorSa})`,
      satisfied: isRegisteredForRole(ctx.loans, ctx.loans, Roles.Originator, manifest.originatorSa, ctx.deployment),
    },
    {
      label: `PortfolioVault.hasRole(PORTFOLIO_MANAGER, ${manifest.portfolioManagerSa})`,
      satisfied: hasRole(ctx.portfolioVault, roleIds.portfolioManager, manifest.portfolioManagerSa, ctx.deployment),
    },
    {
      label: `PortfolioVault.hasRole(INVESTOR_MANAGER, ${manifest.investorManagerSa})`,
      satisfied: hasRole(ctx.portfolioVault, roleIds.investorManager, manifest.investorManagerSa, ctx.deployment),
    },
    {
      label: `NavCalculator.hasRole(CALCULATING_AGENT, ${manifest.calculatingAgentSa})`,
      satisfied: hasRole(ctx.navCalculator, roleIds.calculatingAgent, manifest.calculatingAgentSa, ctx.deployment),
    },
    {
      label: `VaultShareToken.hasRole(WHITELISTER_ROLE, ${manifest.whitelisterSafe})`,
      satisfied: hasRole(ctx.vaultShareToken, roleIds.whitelister, manifest.whitelisterSafe, ctx.deployment),
    },
  ]
}
