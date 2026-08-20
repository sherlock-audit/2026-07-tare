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
  investorSa: string
  portfolioManagerSa: string
  investorManagerSa: string
  calculatingAgentSa: string
  whitelisterSafe: string
}

export type GrantChecksManifest = Pick<
  GrantRolesManifest,
  | "originatorSa"
  | "investorSa"
  | "portfolioManagerSa"
  | "investorManagerSa"
  | "calculatingAgentSa"
  | "whitelisterSafe"
>

export interface GrantChecksContext {
  loans: string
  portfolioVault: string
  navCalculator: string
  vaultShareToken: string
  manifest: GrantChecksManifest
  deployment: ResolvedDeployment
}

/** Resolved protocol addresses + manifest inputs shared by all steps. */
export interface GrantRolesContext extends GrantChecksContext {
  timelock: string
  proposerSafe: string
  manifest: GrantRolesManifest
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
