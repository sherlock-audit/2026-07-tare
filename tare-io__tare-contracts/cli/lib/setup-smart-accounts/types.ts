import type { ResolvedDeployment, SafeExecOptions } from "../cast.js"

/** Roles of the eight smart accounts, in setup execution order. */
export const ROLES = [
  "originator",
  "borrower",
  "investor",
  "servicer",
  "shareholder",
  "portfolioManager",
  "investorManager",
  "calculatingAgent",
] as const

export type Role = (typeof ROLES)[number]

export type SmartAccounts = Record<Role, string>

/** Manifest consumed via --input. Infra Safes + eight SAs + optional offramp. */
export interface SetupManifest {
  operationalManagementSafe: string
  hotProxy: string
  guardianSafe: string
  originatorSa: string
  borrowerSa: string
  investorSa: string
  servicerSa: string
  shareholderSa: string
  portfolioManagerSa: string
  investorManagerSa: string
  calculatingAgentSa: string
  offramp?: string
}

export type StepCategory =
  "moduleActivation" | "hotProxyDelegation" | "approvals" | "vaultWiring" | "disbursement" | "addressBook" | "ownership"

export interface StepResult {
  step: string
  status: "completed" | "skipped" | "failed" | "dry-run"
  txHashes?: string[]
  error?: string
}

export interface CategorizedStepResult extends StepResult {
  category: StepCategory
}

export interface StepDef {
  name: string
  category: StepCategory
  check: () => boolean
  execute: () => string[]
}

/** Resolved addresses and execution context shared by all step builders. */
export interface SetupContext {
  loans: string
  trustedCalls: string
  trustedSpender: string
  usdc: string
  loansNft: string
  loansExchange: string
  portfolioVault: string
  vaultShareToken: string
  operationalManagementSafe: string
  hotProxy: string
  guardianSafe: string
  offramp?: string
  smartAccounts: SmartAccounts
  deployment: ResolvedDeployment
  execOpts: SafeExecOptions
  /** SA threshold after the ownership transition (production: 2; local dev keeps 1). */
  finalThreshold: number
  /** Verify the expected owners as a subset instead of the exact set (local dev keeps the deployer as an owner). */
  allowExtraOwners: boolean
}
