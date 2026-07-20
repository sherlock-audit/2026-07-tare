import { execFileSync, execSync } from "child_process"
import { mkdirSync, readFileSync } from "fs"
import { resolve } from "path"
import { getDeploymentConfig, getChainConfig, forgeScripts, type DeployPreset } from "./deployment-configs.js"
import { verifyLocalDeploymentWithSourcify } from "./local-verification.js"
import { checksum, loadDeploymentManifest } from "./utils.js"
import { readRolesManifest, rolesManifestPath } from "./roles-manifest.js"

function setRoleHolderEnv(envVar: "DEPLOY_ADMIN" | "DEPLOY_GUARDIAN", flag: string, value: string | undefined): void {
  if (value) process.env[envVar] = checksum(flag)(value)
}

/**
 * Resolve the admin/guardian role holders for a protocol deploy: explicit flag >
 * recorded deployment artifact (roles manifest `adminSafe` / timelock manifest
 * `TimelockController`) > static config value (via `setDeploymentEnv`'s `??=`
 * below). `useManifestDefaults: false` skips the artifact layer — a local deploy
 * that resets the chain wipes any previously recorded Safes/Timelock, so their
 * addresses must not carry over.
 */
export function applyRoleHolderEnv(
  root: string,
  deploymentName: string,
  opts: { admin?: string; guardian?: string },
  useManifestDefaults = true
): void {
  const config = getDeploymentConfig(deploymentName)
  const roles = useManifestDefaults ? readRolesManifest(rolesManifestPath(root, config)) : null
  const timelock = useManifestDefaults
    ? loadDeploymentManifest(root, config.chain, config.shortName, "timelock", true)
    : null

  setRoleHolderEnv("DEPLOY_ADMIN", "--admin", opts.admin ?? roles?.adminSafe)
  setRoleHolderEnv("DEPLOY_GUARDIAN", "--guardian", opts.guardian ?? timelock?.contracts.TimelockController)
}

export function setDeploymentEnv(deploymentName: string): void {
  const deployment = getDeploymentConfig(deploymentName)
  const chain = getChainConfig(deployment.chain)

  const defaults: Record<string, string | undefined> = {
    DEPLOY_ADMIN: deployment.admin,
    DEPLOY_GUARDIAN: deployment.guardian,
    DEPLOY_LOANS_BASE_URI: deployment.loansBaseURI,
    DEPLOY_USDC: deployment.usdc,
    DEPLOY_SAFE_SINGLETON: chain.safeSingleton,
    DEPLOY_SAFE_PROXY_FACTORY: chain.safeProxyFactory,
    DEPLOY_MULTISEND: chain.multisendCallOnly,
  }

  for (const [key, value] of Object.entries(defaults)) {
    process.env[key] ??= value
  }
}

export function etchCreateX(rpcUrl: string, root: string = "."): void {
  execFileSync("cast", ["rpc", "anvil_reset", "--rpc-url", rpcUrl], { stdio: "inherit" })
  setCreateXCode(rpcUrl, root)
}

// Etches CreateX without resetting the chain — for presets that deploy onto an anvil
// instance whose existing state must be preserved (e.g. `deploy timelock`).
export function setCreateXCode(rpcUrl: string, root: string = "."): void {
  const sol = readFileSync(resolve(root, "lib/createx-forge/script/CreateX.d.sol"), "utf8")
  const match = sol.match(/hex"([0-9a-fA-F]+)"/)
  if (!match) throw new Error("Could not extract CreateX bytecode")
  execFileSync(
    "cast",
    ["rpc", "anvil_setCode", "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed", `0x${match[1]}`, "--rpc-url", rpcUrl],
    { stdio: "inherit" }
  )
}

export interface DeployOptions {
  preset: DeployPreset
  name: string
  root?: string
  privateKey?: string
  account?: string
  deployerAddr: string
  rpcUrl?: string
  /** Local preset only: keep existing anvil state (no `anvil_reset`) so pre-deployed Safes/Timelock survive. */
  keepState?: boolean
}

export async function deploy(opts: DeployOptions): Promise<void> {
  const deployment = getDeploymentConfig(opts.name)
  const chainConfig = getChainConfig(deployment.chain)

  if (!forgeScripts[opts.preset]) {
    throw new Error(`Unknown preset: ${opts.preset}. Options: ${Object.keys(forgeScripts).join(", ")}`)
  }

  process.env.DEPLOYMENT_NAME = deployment.shortName
  const root = opts.root ?? "."
  mkdirSync(resolve(root, `deployments/${deployment.chain}/${deployment.shortName}/loans`), { recursive: true })
  mkdirSync(resolve(root, `deployments/${deployment.chain}/${deployment.shortName}/accounts`), { recursive: true })
  mkdirSync(resolve(root, `deployments/${deployment.chain}/${deployment.shortName}/vault`), { recursive: true })
  mkdirSync(resolve(root, `deployments/${deployment.chain}/${deployment.shortName}/timelock`), { recursive: true })
  setDeploymentEnv(opts.name)

  if (!process.env.PACKAGE_VERSION) {
    const pkg = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"))
    process.env.PACKAGE_VERSION = pkg.version
  }
  if (!process.env.COMMIT_HASH) {
    try {
      process.env.COMMIT_HASH = execSync("git rev-parse --short HEAD", { encoding: "utf8" }).trim()
    } catch {
      process.env.COMMIT_HASH = ""
    }
  }

  const forgeArgs = ["script", forgeScripts[opts.preset], "--sender", opts.deployerAddr]

  const rpcUrl = opts.rpcUrl ?? chainConfig.rpc()
  if (!rpcUrl) {
    throw new Error(`RPC URL not set for chain: ${deployment.chain}`)
  }

  if (opts.preset === "local" && !opts.keepState) {
    etchCreateX(rpcUrl, root)
  } else if (deployment.chain === "foundry") {
    // Anvil targets other than the full local stack must keep their existing state;
    // etch CreateX in place (idempotent) instead of resetting the chain.
    setCreateXCode(rpcUrl, root)
  }

  forgeArgs.push("--chain", chainConfig.chainId, "--rpc-url", rpcUrl, "--broadcast")

  if (opts.preset === "local") {
    forgeArgs.push("--slow")
  }

  if (opts.privateKey) {
    forgeArgs.push("--private-key", opts.privateKey, "--non-interactive")
  } else if (opts.account) {
    forgeArgs.push("--account", opts.account)
  } else {
    throw new Error("--private-key or --account is required")
  }

  if (deployment.chain !== "foundry") {
    // Generous detection window: explorers index runtime code fast but lag on the
    // internal CREATE3 creation trace — submitting too early fails verification
    // with a creation-bytecode mismatch against the CreateX factory call.
    forgeArgs.push("--verify")
    forgeArgs.push("--retries", process.env.VERIFY_RETRIES ?? "10")
    forgeArgs.push("--delay", process.env.VERIFY_DELAY ?? "30")
  }

  execFileSync("forge", forgeArgs, { stdio: "inherit", cwd: opts.root })

  if (deployment.chain === "foundry" && opts.preset === "local" && process.env.SOURCIFY_URL) {
    try {
      await verifyLocalDeploymentWithSourcify(root, deployment.chain, deployment.shortName, chainConfig.chainId)
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      console.warn(`Sourcify verification failed (non-fatal): ${msg}`)
    }
  }
}
