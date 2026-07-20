import type { ResolvedDeployment } from "../cast.js"
import type { TimelockCall } from "../timelock.js"

/**
 * Manifest consumed via `--input`. Carries only deploy-specific inputs; all
 * protocol contract addresses are read from the deployment artifacts.
 */
export interface GrantRolesManifest {
  proposerSafe: string
  salt: string
  originatorSa: string
  portfolioManagerSa: string
  investorManagerSa: string
  calculatingAgentSa: string
  whitelisterSafe: string
}

/** Resolved protocol addresses + manifest inputs shared by all steps. */
export interface GrantRolesContext {
  loans: string
  portfolioVault: string
  navCalculator: string
  vaultShareToken: string
  timelock: string
  proposerSafe: string
  manifest: GrantRolesManifest
  deployment: ResolvedDeployment
  sender: string
}

/** A single guardian-routed grant: the inner call bundled into the batch. */
export interface GrantCall extends TimelockCall {
  /** Human-readable label, e.g. `PortfolioVault.grantRole(PORTFOLIO_MANAGER, ...)`. */
  label: string
}

/** Per-grant idempotency / verification result. */
export interface GrantCheck {
  label: string
  satisfied: boolean
}
