/**
 * Bake the pre-seeded Anvil state snapshot shipped with the npm package.
 *
 * Boots a throwaway Anvil and rehearses the production deployment sequence
 * (specs/deployment/production_deployment_runbook.md) with the local deltas
 * from specs/deployment/local_anvil_production_parity.md: stand-in governance
 * Safes and role SAs stay at threshold 1, and the Timelock minDelay stays 0.
 *
 *   Safe infra -> 4 stand-in Safes -> Timelock -> deploy local (Timelock as
 *   guardian, Admin Safe as admin) -> 8 role SAs -> setup-smart-accounts ->
 *   grant-roles (+ shareholder grant) -> hot-safe allowances -> fund USDC ->
 *   seed vault NAV -> dump state.
 *
 * Writes:
 *   state/anvil-state.json.gz  — gzipped anvil_dumpState snapshot
 *   state/anvil-manifest.json  — accounts, env, and version (read by src/anvil.ts)
 *
 * Because deployment addresses are CREATE3-derived, the real deploy lands on the
 * same addresses a simulation would predict — so this also produces the
 * deployments/foundry/dev manifests consumed by generate-deployments.
 *
 * Runs as part of `pnpm build`. Requires anvil, forge, and cast on PATH.
 */
import { execFileSync, execSync, spawn } from "child_process"
import { existsSync, mkdirSync, openSync, readFileSync, unlinkSync, writeFileSync } from "fs"
import { gunzipSync } from "zlib"
import { dirname, resolve } from "path"
import { fileURLToPath } from "url"
import { DEFAULT_ANVIL_ADDR, DEFAULT_ANVIL_KEY } from "./lib/deployment-configs.js"
import { DEFAULT_ANVIL_RPC } from "./lib/constants.js"
import { loadDeploymentManifest } from "./lib/utils.js"

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const RPC_URL = process.env.ANVIL_RPC ?? DEFAULT_ANVIL_RPC
// Children (CLI invocations, cast) resolve the foundry RPC from ANVIL_RPC.
process.env.ANVIL_RPC = RPC_URL

const ANVIL_LOG = process.env.ANVIL_LOG ?? "/tmp/anvil.log"
const TSX = resolve(ROOT, "node_modules", ".bin", "tsx")
const CLI_ENTRY = resolve(ROOT, "cli", "index.ts")

// Anvil dev account #0 — the HotSafe owner (the key the LMS hot-proxy signs with)
// and therefore the signer for hot-proxy-routed calls like seed-vault's updateNav.
const HOT_SAFE_OWNER_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
const HOT_SAFE_OWNER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

const STATE_DIR = resolve(ROOT, "state")
const STATE_FILE = resolve(STATE_DIR, "anvil-state.json.gz")
const MANIFEST_FILE = resolve(STATE_DIR, "anvil-manifest.json")
const ROLES_MANIFEST_FILE = resolve(ROOT, "deployments", "foundry", "dev", "roles", "latest.json")

// Fixed deploy-safe saltNonces so the stand-in Safes land on the same addresses
// every bake (they are version-independent, unlike the CREATE3 protocol salts).
const SAFES = [
  { key: "operationalManagementSafe", salt: "1001" },
  { key: "adminSafe", salt: "1002" },
  { key: "proposerSafe,guardianSafe", salt: "1003" },
  { key: "whitelisterSafe", salt: "1004" },
] as const

let stepCount = 1
async function step(name: string, fn: () => void | Promise<void>): Promise<void> {
  console.log(`Step ${stepCount++}: ${name}`)
  try {
    await fn()
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    throw new Error(`${name} failed: ${msg.split("\n")[0]}`)
  }
}

function cli(args: string[], privateKey: string = DEFAULT_ANVIL_KEY): void {
  execFileSync(TSX, [CLI_ENTRY, "--chain", "foundry", "--private-key", privateKey, ...args], {
    stdio: "inherit",
    cwd: ROOT,
  })
}

function cast(args: string[]): string {
  return execFileSync("cast", [...args, "--rpc-url", RPC_URL], { encoding: "utf8" }).trim()
}

function readRoles(): Record<string, string> {
  return JSON.parse(readFileSync(ROLES_MANIFEST_FILE, "utf8")) as Record<string, string>
}

async function waitForAnvil(): Promise<void> {
  for (let i = 0; i < 60; i++) {
    try {
      cast(["chain-id"])
      return
    } catch {
      await new Promise((r) => setTimeout(r, 500))
    }
  }
  throw new Error("Anvil did not become ready in time")
}

async function main(): Promise<void> {
  const pkg = JSON.parse(readFileSync(resolve(ROOT, "package.json"), "utf8"))
  console.log("=== bake-anvil-state ===")
  console.log(`  version: ${pkg.version}`)
  console.log(`  forge:   ${execSync("forge --version", { encoding: "utf8" }).trim().split("\n")[0]}`)

  // The committed roles manifest carries the previous version's SA addresses;
  // on a fresh chain they don't exist, so start clean or create-role-accounts
  // would skip creation.
  if (existsSync(ROLES_MANIFEST_FILE)) unlinkSync(ROLES_MANIFEST_FILE)

  const anvilLogFd = openSync(ANVIL_LOG, "w")
  const anvil = spawn("anvil", ["--host", "127.0.0.1", "--port", new URL(RPC_URL).port || "8545"], {
    stdio: ["ignore", anvilLogFd, anvilLogFd],
  })
  const killAnvil = () => {
    if (!anvil.killed) anvil.kill("SIGKILL")
  }
  process.on("exit", killAnvil)

  try {
    await step("Wait for Anvil", waitForAnvil)

    await step("Deploy stand-in Safe infrastructure", () => {
      cli(["deploy", "safe-infra", "--rpc-url", RPC_URL])
    })

    for (const { key, salt } of SAFES) {
      await step(`Deploy stand-in Safe: ${key}`, () => {
        cli(["deploy-safe", "--owners", DEFAULT_ANVIL_ADDR, "--threshold", "1", "--salt", salt, "--manifest-key", key])
      })
    }

    await step("Deploy Timelock (minDelay 0, proposer/canceller from manifest)", () => {
      cli(["deploy", "timelock", "--min-delay", "0", "--deployer-addr", DEFAULT_ANVIL_ADDR, "--rpc-url", RPC_URL])
    })

    await step("Deploy contracts (admin = Admin Safe, guardian = Timelock)", () => {
      cli(["deploy", "local", "--keep-state", "--hot-safe-owner", HOT_SAFE_OWNER_ADDR, "--rpc-url", RPC_URL])
    })

    // The deploy just wrote these manifests; read addresses from them directly.
    const loans = loadDeploymentManifest(ROOT, "foundry", "dev", "loans")
    const timelockManifest = loadDeploymentManifest(ROOT, "foundry", "dev", "timelock")
    const currencyAddress = loans.contracts.USDC
    const hotSafeAddress = loans.contracts.HotSafe
    const timelockAddress = timelockManifest.contracts.TimelockController
    if (!currencyAddress || !hotSafeAddress || !timelockAddress) {
      throw new Error("Missing USDC/HotSafe/TimelockController in deployment manifests")
    }
    console.log(`  Currency: ${currencyAddress}`)
    console.log(`  HotSafe:  ${hotSafeAddress}`)
    console.log(`  Timelock: ${timelockAddress}`)

    await step("Record hot proxy + offramp in roles manifest", () => {
      cli(["manifest", "set", "hotProxy", hotSafeAddress])
      cli(["manifest", "set", "offramp", hotSafeAddress])
    })

    const opsMgmtSafe = readRoles().operationalManagementSafe
    await step("Create role smart accounts", () => {
      cli([
        "create-role-accounts",
        // The deployer stays a direct owner so dev tooling can sign SA
        // transactions with a single key (threshold stays 1).
        "--owners",
        `${opsMgmtSafe},${DEFAULT_ANVIL_ADDR}`,
        "--threshold",
        "1",
        "--delegates",
        hotSafeAddress,
        "--currencies",
        currencyAddress,
        "--trusted-recipients",
        hotSafeAddress,
      ])
    })

    await step("Configure smart accounts (threshold stays 1)", () => {
      cli(["setup-smart-accounts", "--final-threshold", "1", "--allow-extra-owners"])
    })

    await step("Grant privileged roles via Timelock (+ shareholder grant)", () => {
      cli(["grant-roles", "--include-shareholder-grant"])
    })

    const roles = readRoles()
    const saFields = [
      "originatorSa",
      "borrowerSa",
      "investorSa",
      "servicerSa",
      "shareholderSa",
      "portfolioManagerSa",
      "investorManagerSa",
      "calculatingAgentSa",
    ] as const

    // Local extra (not part of the production setup): dev/e2e TrustedSpender
    // transfer flows move funds SA -> hot safe and rely on these allowances.
    for (const field of saFields) {
      await step(`Set TrustedSpender allowance on ${field}`, () => {
        cli(["set-allowance", "set", "--from", roles[field], "--to", hotSafeAddress, "--smart-account", roles[field]])
      })
    }

    await step("Fund role accounts with USDC", () => {
      cli(["fund-usdc"])
    })

    await step("Seed vault NAV (donation + updateNav via hot proxy)", () => {
      cli(["seed-vault", "--amount", "1"], HOT_SAFE_OWNER_KEY)
    })

    await step("Dump Anvil state", () => {
      mkdirSync(STATE_DIR, { recursive: true })
      const dumped = cast(["rpc", "anvil_dumpState"])
      // anvil_dumpState returns a 0x-prefixed hex string of gzipped state bytes.
      // Ship the gzipped original; `anvil --load-state` only reads plain JSON, so
      // consumers gunzip when provisioning.
      const hex = JSON.parse(dumped) as string
      const gz = Buffer.from(hex.replace(/^0x/, ""), "hex")
      // Sanity-check the payload is valid gzipped JSON before shipping it.
      JSON.parse(gunzipSync(gz).toString("utf8"))
      writeFileSync(STATE_FILE, gz)
      console.log(`  Wrote ${STATE_FILE} (${gz.length} bytes)`)
    })

    await step("Write anvil manifest", () => {
      const manifest = {
        version: pkg.version,
        accounts: {
          Borrower: roles.borrowerSa,
          Investor: roles.investorSa,
          Originator: roles.originatorSa,
          Servicer: roles.servicerSa,
          Shareholder: roles.shareholderSa,
          PortfolioManager: roles.portfolioManagerSa,
          InvestorManager: roles.investorManagerSa,
          CalculatingAgent: roles.calculatingAgentSa,
        },
        env: {
          HOT_PROXY_SAFE_ADDRESS: hotSafeAddress,
          TIMELOCK_ADDRESS: timelockAddress,
          ADMIN_SAFE_ADDRESS: roles.adminSafe,
          PROPOSER_SAFE_ADDRESS: roles.proposerSafe,
          WHITELISTER_SAFE_ADDRESS: roles.whitelisterSafe,
          OPS_MGMT_SAFE_ADDRESS: roles.operationalManagementSafe,
        },
      }
      writeFileSync(MANIFEST_FILE, JSON.stringify(manifest, null, 2) + "\n")
      console.log(`  Wrote ${MANIFEST_FILE}`)
    })
  } finally {
    killAnvil()
  }

  console.log("\n=== bake-anvil-state complete ===")
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
