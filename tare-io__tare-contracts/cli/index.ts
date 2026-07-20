#!/usr/bin/env node
import { resolve, dirname } from "path"
import { existsSync } from "fs"
import { fileURLToPath } from "url"
import { config } from "dotenv"
import { Command } from "commander"
import { registerDeploy } from "./commands/deploy.js"
import { registerDeploySafe } from "./commands/deploy-safe.js"
import { registerExtractEnums } from "./commands/extract-enums.js"
import { registerGenerateDeployments } from "./commands/generate-deployments.js"
import { registerApproveOriginator } from "./commands/approve-originator.js"
import { registerCreateSmartAccount } from "./commands/create-smart-account.js"
import { registerAddressBook } from "./commands/address-book.js"
import { registerApproveCurrency } from "./commands/approve-currency.js"
import { registerSetupSmartAccounts } from "./commands/setup-smart-accounts.js"
import { registerSetAllowance } from "./commands/set-allowance.js"
import { registerGrantRoles } from "./commands/grant-roles.js"
import { registerDebugTx } from "./commands/debug-tx.js"
import { registerVerifyDeployment } from "./commands/verify-deployment/index.js"
import { registerManifest } from "./commands/manifest.js"
import { registerCreateRoleAccounts } from "./commands/create-role-accounts.js"
import { registerSafeExec } from "./commands/safe-exec.js"
import { registerUpdateTimelockDelay } from "./commands/update-timelock-delay.js"
import { registerSeedVault } from "./commands/seed-vault.js"
import { registerFundUsdc } from "./commands/fund-usdc.js"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

function findPkgRoot(start: string): string {
  let dir = start
  for (;;) {
    if (existsSync(resolve(dir, "package.json"))) return dir
    const parent = resolve(dir, "..")
    if (parent === dir) return start
    dir = parent
  }
}

const pkgRoot = findPkgRoot(__dirname)
const envFile = process.env.ENV === "testing" ? ".env.testing" : ".env"
config({ path: resolve(pkgRoot, envFile), quiet: true })

const program = new Command()
program
  .name("tare-contracts")
  .description("Tare contracts tooling")
  .option("--name <name>", "Deployment name", process.env.TARE_DEPLOYMENT_NAME ?? "dev")
  .option("--chain <chain>", "Chain name", process.env.TARE_CHAIN)
  .option("--root <path>", "Project root", pkgRoot)
  .option("--private-key <key>", "Deployer private key", process.env.DEPLOYER_KEY)
  .option("--account <name>", "Deployer keystore account name", process.env.DEPLOYER_ACCOUNT)
  .option("--deployer-addr <address>", "Deployer address", process.env.DEPLOYER_ADDR)
  .option("--json", "Output structured JSON instead of human-readable text", false)

registerDeploy(program)
registerDeploySafe(program)
registerExtractEnums(program)
registerGenerateDeployments(program)
registerApproveOriginator(program)
registerCreateSmartAccount(program)
registerAddressBook(program)
registerApproveCurrency(program)
registerSetupSmartAccounts(program)
registerSetAllowance(program)
registerGrantRoles(program)
registerDebugTx(program)
registerVerifyDeployment(program)
registerManifest(program)
registerCreateRoleAccounts(program)
registerSafeExec(program)
registerUpdateTimelockDelay(program)
registerSeedVault(program)
registerFundUsdc(program)

async function main(): Promise<void> {
  await program.parseAsync(process.argv)
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error)
  if (program.opts().json) {
    process.stdout.write(
      JSON.stringify({ status: "error", command: process.argv.slice(2).join(" "), data: { message } }) + "\n"
    )
  } else {
    console.error(error)
  }
  process.exit(1)
})
