import type { Address } from "viem"

export interface DeploymentManifest {
  contracts: Record<string, string>
  blockNumber?: number
}

export type CheckStatus = "pass" | "fail" | "skip" | "info"

export interface Check {
  section: string
  name: string
  status: CheckStatus
  detail?: string
}

export type Addr = Address | ""

export interface Addresses {
  loans: Addr
  loansNFT: Addr
  exchange: Addr
  usdc: Addr
  trustedCalls: Addr
  trustedSpender: Addr
  saf: Addr
  safeSingleton: Addr
  safeProxyFactory: Addr
  navCalculator: Addr
  vaultShareToken: Addr
  portfolioVault: Addr
  timelock: Addr
}

// Operator-supplied expectations for the Timelock's configuration (all optional —
// only the supplied ones are asserted).
export interface TimelockExpectations {
  minDelay?: bigint
}

export interface SelectorGroup {
  label: string
  contract: "loans" | "exchange" | "vault"
  entries: { name: string; sig: string }[]
}
