import type { Command } from "commander"
import { applyRoleHolderEnv, deploy } from "../lib/deploy.js"
import { DEFAULT_ANVIL_ADDR, DEFAULT_ANVIL_KEY, getDeploymentConfig } from "../lib/deployment-configs.js"
import { DEFAULT_ANVIL_RPC, ZERO_ADDRESS } from "../lib/constants.js"
import type { GlobalOpts } from "../lib/cast.js"
import { checksum } from "../lib/utils.js"
import { readRolesManifest, rolesManifestPath } from "../lib/roles-manifest.js"

export function registerDeploy(program: Command): void {
  const deployCmd = program.command("deploy").description("Deploy contracts")

  deployCmd
    .command("local")
    .description("Deploy all contracts to a local Anvil instance")
    .option("-r, --rpc-url <url>", "Anvil RPC URL", process.env.ANVIL_RPC ?? DEFAULT_ANVIL_RPC)
    .option("--admin <address>", "ADMIN_ROLE holder (default: roles-manifest adminSafe, then config)")
    .option("--guardian <address>", "GUARDIAN_ROLE holder (default: timelock manifest, then config)")
    .option("--hot-safe-owner <address>", "HotSafe owner EOA (default: the admin address)")
    .option("--keep-state", "Keep existing anvil state (no anvil_reset) — pre-deployed Safes/Timelock survive")
    .action(async function (
      this: Command,
      opts: { rpcUrl: string; admin?: string; guardian?: string; hotSafeOwner?: string; keepState?: boolean }
    ) {
      const { name, chain, root } = this.optsWithGlobals() as GlobalOpts
      const deploymentName = `${chain ?? "foundry"}-${name}`
      // Manifest-recorded Safes/Timelock only exist on chain when the state they
      // were deployed into survives — i.e. with --keep-state. A reset falls back
      // to explicit flags or the static config EOAs.
      applyRoleHolderEnv(root, deploymentName, opts, opts.keepState ?? false)
      if (opts.hotSafeOwner) process.env.DEPLOY_HOT_SAFE_OWNER = checksum("--hot-safe-owner")(opts.hotSafeOwner)
      await deploy({
        preset: "local",
        root,
        name: deploymentName,
        rpcUrl: opts.rpcUrl,
        privateKey: DEFAULT_ANVIL_KEY,
        deployerAddr: DEFAULT_ANVIL_ADDR,
        account: undefined,
        keepState: opts.keepState,
      })
    })

  deployCmd
    .command("safe-infra")
    .description(
      "Land the stand-in Safe infrastructure (singleton, proxy factory, MultiSend) on a local Anvil so deploy-safe works before the protocol deploy"
    )
    .option("-r, --rpc-url <url>", "Anvil RPC URL", process.env.ANVIL_RPC ?? DEFAULT_ANVIL_RPC)
    .action(async function (this: Command, opts: { rpcUrl: string }) {
      const { name, chain, root } = this.optsWithGlobals() as GlobalOpts
      const deploymentName = `${chain ?? "foundry"}-${name}`
      if (getDeploymentConfig(deploymentName).chain !== "foundry") {
        throw new Error("deploy safe-infra targets local anvil chains only — live chains use the canonical Safe infra")
      }
      await deploy({
        preset: "safe-infra",
        root,
        name: deploymentName,
        rpcUrl: opts.rpcUrl,
        privateKey: DEFAULT_ANVIL_KEY,
        deployerAddr: DEFAULT_ANVIL_ADDR,
        account: undefined,
      })
    })

  function remoteDeployAction(preset: "loans" | "accounts" | "vault") {
    return async function (this: Command, opts: { admin?: string; guardian?: string }) {
      const { name, chain, root, privateKey, account, deployerAddr } = this.optsWithGlobals() as GlobalOpts
      if (!chain) throw new Error(`--chain is required for deploy ${preset}`)
      if (!deployerAddr) throw new Error("--deployer-addr or DEPLOYER_ADDR is required")
      applyRoleHolderEnv(root, `${chain}-${name}`, opts)
      await deploy({ preset, root, name: `${chain}-${name}`, privateKey, account, deployerAddr })
    }
  }

  for (const preset of ["loans", "accounts", "vault"] as const) {
    deployCmd
      .command(preset)
      .description(
        `Deploy ${preset === "loans" ? "Loans contracts" : preset === "accounts" ? "Smart Accounts" : "Vault contracts"}`
      )
      .option("--admin <address>", "ADMIN_ROLE holder (default: roles-manifest adminSafe, then config)")
      .option("--guardian <address>", "GUARDIAN_ROLE holder (default: timelock manifest, then config)")
      .action(remoteDeployAction(preset))
  }

  deployCmd
    .command("timelock")
    .description("Deploy a TimelockController with explicit proposer / canceller / executor sets")
    .option("--min-delay <seconds>", "Minimum delay before a scheduled operation can execute", "0")
    .option("--proposer <address...>", "PROPOSER_ROLE holder(s) (default: roles-manifest proposerSafe)")
    .option("--canceller <address...>", "Exact CANCELLER_ROLE set (default: roles-manifest adminSafe)")
    .option("--executor <address...>", "EXECUTOR_ROLE holder(s); defaults to the zero address (open execution)", [
      ZERO_ADDRESS,
    ])
    .option("-r, --rpc-url <url>", "RPC URL (local anvil targets only)")
    .action(async function (
      this: Command,
      opts: { minDelay: string; proposer?: string[]; canceller?: string[]; executor: string[]; rpcUrl?: string }
    ) {
      const { name, chain, root, privateKey, account, deployerAddr } = this.optsWithGlobals() as GlobalOpts
      if (!chain) throw new Error("--chain is required for deploy timelock")

      const minDelay = Number.parseInt(opts.minDelay, 10)
      if (!Number.isInteger(minDelay) || minDelay < 0) throw new Error(`Invalid --min-delay: ${opts.minDelay}`)

      const deploymentName = `${chain}-${name}`
      const config = getDeploymentConfig(deploymentName)
      const roles = readRolesManifest(rolesManifestPath(root, config))
      const proposers = opts.proposer ?? (roles?.proposerSafe ? [roles.proposerSafe] : undefined)
      const cancellers = opts.canceller ?? (roles?.adminSafe ? [roles.adminSafe] : undefined)
      if (!proposers) throw new Error("--proposer is required (or record proposerSafe in the roles manifest)")
      if (!cancellers) throw new Error("--canceller is required (or record adminSafe in the roles manifest)")

      process.env.DEPLOY_TIMELOCK_MIN_DELAY = String(minDelay)
      process.env.DEPLOY_TIMELOCK_PROPOSERS = proposers.map(checksum("--proposer")).join(",")
      process.env.DEPLOY_TIMELOCK_CANCELLERS = cancellers.map(checksum("--canceller")).join(",")
      process.env.DEPLOY_TIMELOCK_EXECUTORS = opts.executor.map(checksum("--executor")).join(",")

      const isLocal = config.chain === "foundry"
      // On local anvil, signer flags from .env defaults (DEPLOYER_KEY / DEPLOYER_ACCOUNT /
      // DEPLOYER_ADDR) target remote chains and would not match the anvil accounts — use the
      // anvil defaults unless the signer was given explicitly on the command line.
      const explicitSigner =
        this.getOptionValueSourceWithGlobals("privateKey") === "cli" ||
        this.getOptionValueSourceWithGlobals("account") === "cli"
      const useAnvilDefaults = isLocal && !explicitSigner
      // Whenever the anvil defaults are not used (remote chain, or explicit signer on
      // local anvil), the sender address must be supplied alongside the signer.
      const resolvedDeployerAddr = useAnvilDefaults ? DEFAULT_ANVIL_ADDR : deployerAddr
      if (!resolvedDeployerAddr) throw new Error("--deployer-addr or DEPLOYER_ADDR is required")
      await deploy({
        preset: "timelock",
        root,
        name: deploymentName,
        rpcUrl: isLocal ? (opts.rpcUrl ?? process.env.ANVIL_RPC ?? DEFAULT_ANVIL_RPC) : opts.rpcUrl,
        privateKey: useAnvilDefaults ? DEFAULT_ANVIL_KEY : privateKey,
        account: useAnvilDefaults ? undefined : account,
        deployerAddr: resolvedDeployerAddr,
      })
    })
}
