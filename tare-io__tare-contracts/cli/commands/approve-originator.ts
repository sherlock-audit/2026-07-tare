import type { Command } from "commander"
import { resolveDeployment, readContractAddress, castSend } from "../lib/cast.js"
import { isRegisteredForRole } from "../lib/onchain.js"
import { outputResult } from "../lib/output.js"
import { Roles } from "../lib/roles.js"

export function registerApproveOriginator(program: Command): void {
  const cmd = program.command("approve-originator").description("Manage approved originators on the Loans contract")

  cmd
    .command("set")
    .description("Approve an originator address")
    .requiredOption("--originator <address>", "Originator address to approve")
    .action(function (this: Command, opts: { originator: string }) {
      const deployment = resolveDeployment(this)
      const loansAddress = readContractAddress(deployment.root, deployment.config, "loans", "Loans")

      const { txHash } = castSend(loansAddress, "approveOriginator(address)", [opts.originator], deployment)
      outputResult(this, {
        status: "ok",
        command: "approve-originator set",
        data: { originator: opts.originator, loansAddress },
        txHash,
      })
    })

  cmd
    .command("check")
    .description("Check if an address is an approved originator")
    .requiredOption("--originator <address>", "Originator address to check")
    .action(function (this: Command, opts: { originator: string }) {
      const deployment = resolveDeployment(this)
      const loansAddress = readContractAddress(deployment.root, deployment.config, "loans", "Loans")

      const approved = isRegisteredForRole(loansAddress, loansAddress, Roles.Originator, opts.originator, deployment)

      outputResult(this, {
        status: "ok",
        command: "approve-originator check",
        data: { originator: opts.originator, approved, loansAddress },
      })
    })
}
