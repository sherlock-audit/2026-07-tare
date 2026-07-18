import type { Command } from "commander"
import { resolveDeployment, readContractAddress, castSend, castCalldata, safeExec } from "../lib/cast.js"
import { isRegisteredForRole } from "../lib/onchain.js"
import { outputResult } from "../lib/output.js"
import { parseRole, roleToUint } from "../lib/roles.js"

export function registerAddressBook(program: Command): void {
  const cmd = program.command("address-book").description("Manage the Loans address book")

  cmd
    .command("register")
    .description("Register an address for a role")
    .requiredOption("--role <role>", "Role (Borrower, Originator, Investor, Servicer)")
    .requiredOption("--addr <address>", "Address to register")
    .option("--on-behalf-of <address>", "Address book owner (admin only)")
    .option("--smart-account <address>", "Execute via Safe (sender must be an owner)")
    .action(function (this: Command, opts: { role: string; addr: string; onBehalfOf?: string; smartAccount?: string }) {
      const deployment = resolveDeployment(this)
      const loansAddress = readContractAddress(deployment.root, deployment.config, "loans", "Loans")
      const role = parseRole(opts.role)

      let txHash: string | undefined
      let txHashes: string[] | undefined
      if (opts.smartAccount) {
        const data = castCalldata("registerAddress(uint8,address)", [roleToUint(role), opts.addr])
        ;({ txHashes } = safeExec(opts.smartAccount, loansAddress, data, deployment))
      } else if (opts.onBehalfOf) {
        ;({ txHash } = castSend(loansAddress, "registerAddressOnBehalfOf(address,uint8,address)", [opts.onBehalfOf, roleToUint(role), opts.addr], deployment))
      } else {
        ;({ txHash } = castSend(loansAddress, "registerAddress(uint8,address)", [roleToUint(role), opts.addr], deployment))
      }

      outputResult(this, {
        status: "ok",
        command: "address-book register",
        data: { action: "register", role, addr: opts.addr, onBehalfOf: opts.onBehalfOf ?? null, smartAccount: opts.smartAccount ?? null, loansAddress, ...(txHashes ? { txHashes } : {}) },
        txHash,
      })
    })

  cmd
    .command("check")
    .description("Check if an address is registered for a role")
    .requiredOption("--role <role>", "Role (Borrower, Originator, Investor, Servicer)")
    .requiredOption("--addr <address>", "Address to check")
    .requiredOption("--owner <address>", "Address book owner")
    .action(function (this: Command, opts: { role: string; addr: string; owner: string }) {
      const deployment = resolveDeployment(this)
      const loansAddress = readContractAddress(deployment.root, deployment.config, "loans", "Loans")
      const role = parseRole(opts.role)

      const registered = isRegisteredForRole(loansAddress, opts.owner, role, opts.addr, deployment)

      outputResult(this, {
        status: "ok",
        command: "address-book check",
        data: { registered, role, addr: opts.addr, owner: opts.owner, loansAddress },
      })
    })
}
