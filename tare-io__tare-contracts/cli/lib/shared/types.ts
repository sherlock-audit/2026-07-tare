export interface DeploymentManifest {
  contracts: Record<string, string>
}

export type DeploymentComponent = "loans" | "accounts" | "vault" | "timelock"
