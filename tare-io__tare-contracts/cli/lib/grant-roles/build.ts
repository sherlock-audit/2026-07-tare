import { castCall, castCalldata } from "../cast.js"
import type { GrantCall, GrantRolesContext } from "./types.js"

/** Role identifiers read from the on-chain contracts. */
export interface RoleIds {
  portfolioManager: string
  investorManager: string
  calculatingAgent: string
  whitelister: string
}

/** Read the four `bytes32` role identifiers from the vault-side contracts. */
export function readRoleIds(ctx: GrantRolesContext): RoleIds {
  return {
    portfolioManager: castCall(ctx.portfolioVault, "PORTFOLIO_MANAGER()(bytes32)", [], ctx.deployment),
    investorManager: castCall(ctx.portfolioVault, "INVESTOR_MANAGER()(bytes32)", [], ctx.deployment),
    calculatingAgent: castCall(ctx.navCalculator, "CALCULATING_AGENT()(bytes32)", [], ctx.deployment),
    whitelister: castCall(ctx.vaultShareToken, "WHITELISTER_ROLE()(bytes32)", [], ctx.deployment),
  }
}

/**
 * The five guardian-routed inner calls, in the order documented in the
 * production runbook. The order is fixed so the operation hash is deterministic
 * for a given salt.
 */
export function buildGrantCalls(ctx: GrantRolesContext, roleIds: RoleIds): GrantCall[] {
  const { manifest } = ctx
  return [
    {
      label: `Loans.approveOriginator(${manifest.originatorSa})`,
      target: ctx.loans,
      data: castCalldata("approveOriginator(address)", [manifest.originatorSa]),
    },
    {
      label: `PortfolioVault.grantRole(PORTFOLIO_MANAGER, ${manifest.portfolioManagerSa})`,
      target: ctx.portfolioVault,
      data: castCalldata("grantRole(bytes32,address)", [roleIds.portfolioManager, manifest.portfolioManagerSa]),
    },
    {
      label: `PortfolioVault.grantRole(INVESTOR_MANAGER, ${manifest.investorManagerSa})`,
      target: ctx.portfolioVault,
      data: castCalldata("grantRole(bytes32,address)", [roleIds.investorManager, manifest.investorManagerSa]),
    },
    {
      label: `NavCalculator.grantRole(CALCULATING_AGENT, ${manifest.calculatingAgentSa})`,
      target: ctx.navCalculator,
      data: castCalldata("grantRole(bytes32,address)", [roleIds.calculatingAgent, manifest.calculatingAgentSa]),
    },
    {
      label: `VaultShareToken.grantRole(WHITELISTER_ROLE, ${manifest.whitelisterSafe})`,
      target: ctx.vaultShareToken,
      data: castCalldata("grantRole(bytes32,address)", [roleIds.whitelister, manifest.whitelisterSafe]),
    },
  ]
}
