export const DEFAULT_ANVIL_ADDR = "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"
export const DEFAULT_ANVIL_KEY = "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"

export interface ChainConfig {
  chainId: string
  rpc: () => string | undefined
  safeSingleton: string
  safeProxyFactory: string
  multisendCallOnly: string
}

export interface DeploymentConfig {
  deploymentId: number
  shortName: string
  chain: string
  usdc?: string
  admin: string
  guardian: string
  loansBaseURI: string
  blockExplorerUrl?: string
}

export const chains: Record<string, ChainConfig> = {
  foundry: {
    chainId: "31337",
    rpc: () => process.env.ANVIL_RPC,
    // Leaving these contracts as empty strings because local deployments are redeploying them.
    safeSingleton: "",
    safeProxyFactory: "",
    multisendCallOnly: "",
  },
  baseSepolia: {
    chainId: "84532",
    rpc: () => process.env.BASE_SEPOLIA_RPC,
    safeSingleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a",
    safeProxyFactory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67",
    multisendCallOnly: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2",
  },
  base: {
    chainId: "8453",
    rpc: () => process.env.BASE_RPC,
    safeSingleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a",
    safeProxyFactory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67",
    multisendCallOnly: "0x9641d764fc13c8B624c04430C7356C1C7C8102e2",
  },
  avalancheFuji: {
    chainId: "43113",
    rpc: () => process.env.FUJI_RPC,
    safeSingleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a",
    safeProxyFactory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67",
    multisendCallOnly: "0x9641d764fc13c8b624c04430c7356c1c7c8102e2",
  },
  avalanche: {
    chainId: "43114",
    rpc: () => process.env.AVALANCHE_RPC,
    safeSingleton: "0x41675C099F32341bf84BFc5382aF534df5C7461a",
    safeProxyFactory: "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67",
    multisendCallOnly: "0x9641d764fc13c8b624c04430c7356c1c7c8102e2",
  },
}

export const deploymentConfigs: Record<string, DeploymentConfig> = {
  "foundry-dev": {
    deploymentId: 100031337,
    shortName: "dev",
    chain: "foundry",
    admin: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    // Anvil account #1 — distinct from deployer (anvil #0) so the in-script guardian
    // renounce leaves a real guardian behind.
    guardian: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    loansBaseURI: "https://api.tare.live/loans/nft-metadata/",
  },
  "baseSepolia-dev": {
    deploymentId: 100084532,
    shortName: "dev",
    chain: "baseSepolia",
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    admin: "0xaF73A34d9aec79C808fF1A57372c3e9838F63Ab8",
    guardian: "0xaF73A34d9aec79C808fF1A57372c3e9838F63Ab8",
    loansBaseURI: "https://api.tare.live/loans/nft-metadata/",
  },
  "baseSepolia-dev-brale": {
    deploymentId: 200084532,
    shortName: "dev-brale",
    chain: "baseSepolia",
    usdc: "0xf9FB20B8E097904f0aB7d12e9DbeE88f2dcd0F16",
    admin: "0xB1D487cF513efA4Bd3625F5AB778bE82A72E722C",
    guardian: "0xB1D487cF513efA4Bd3625F5AB778bE82A72E722C",
    loansBaseURI: "https://api.tare.live/loans/nft-metadata/",
  },
  "base-production": {
    deploymentId: 100008453,
    shortName: "production",
    chain: "base",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    admin: "0xaF73A34d9aec79C808fF1A57372c3e9838F63Ab8",
    guardian: "0xaF73A34d9aec79C808fF1A57372c3e9838F63Ab8",
    loansBaseURI: "https://api.tare.live/loans/nft-metadata/",
  },
  "fuji-dev": {
    deploymentId: 100043113,
    shortName: "dev",
    chain: "avalancheFuji",
    usdc: "0x5425890298aed601595a70AB815c96711a31Bc65",
    admin: "0x9955cb0DD832ACb1fdf3B860c8874a4822910d68",
    guardian: "0x9955cb0DD832ACb1fdf3B860c8874a4822910d68",
    loansBaseURI: "https://api.tare.live/loans/nft-metadata/",
    blockExplorerUrl: "https://testnet.snowscan.xyz",
  },
  // Production deployment on Avalanche C-Chain mainnet (43114).
  // `admin` and `guardian` must be replaced with the real Admin Safe and Timelock
  // addresses before deploying loans/accounts/vault — see
  // specs/deployment/production_deployment_runbook.md.
  "avalanche-production": {
    deploymentId: 100143114,
    shortName: "production",
    chain: "avalanche",
    usdc: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", // native USDC (Circle)
    admin: "0x9013CD0bA21b1f706d62c9ca3E3f1cEBF995722B", // REPLACE: Admin Safe
    guardian: "0x79a51C2C6DB0D4d7C685ad41A6B5b628C1e6bba0", // REPLACE: Timelock (deploy first)
    loansBaseURI: "https://api.tare.io/loans/nft-metadata/",
    blockExplorerUrl: "https://snowscan.xyz",
  },
}

export type DeployPreset = "local" | "loans" | "accounts" | "vault" | "timelock" | "safe-infra"

export const forgeScripts: Record<DeployPreset, string> = {
  local: "script/DeployLocal.s.sol",
  loans: "script/DeployLoans.s.sol",
  accounts: "script/DeploySmartAccounts.s.sol",
  vault: "script/DeployVault.s.sol",
  timelock: "script/DeployTimelock.s.sol",
  "safe-infra": "script/DeploySafeInfra.s.sol",
}

export function getDeploymentConfig(name: string): DeploymentConfig {
  const config = deploymentConfigs[name]
  if (!config) {
    throw new Error(`Unknown deployment: ${name}. Options: ${Object.keys(deploymentConfigs).join(", ")}`)
  }
  return config
}

export function getChainConfig(chain: string): ChainConfig {
  const config = chains[chain]
  if (!config) {
    throw new Error(`Unknown chain: ${chain}. Options: ${Object.keys(chains).join(", ")}`)
  }
  return config
}
