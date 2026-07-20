import type { Command } from "commander"
import { resolveDeployment, readContractAddress, castCall, castCalldata, safeExec } from "../lib/cast.js"
import { resolveCurrency } from "../lib/allowance.js"
import { isMaxAllowance } from "../lib/onchain.js"
import { MAX_UINT256, displayAmount } from "../lib/constants.js"
import { outputResult } from "../lib/output.js"

function resolveSpender(
  spender: string | undefined,
  root: string,
  config: Parameters<typeof readContractAddress>[1]
): string {
  if (spender) return spender
  return readContractAddress(root, config, "loans", "Loans")
}

export function registerApproveCurrency(program: Command): void {
  const cmd = program.command("approve-currency").description("Manage ERC20 currency approvals on smart accounts")

  cmd
    .command("set")
    .description("Approve a spender to use currency on a smart account via Safe execTransaction")
    .requiredOption("--smart-account <address>", "Smart account (Safe) address")
    .option("--spender <address>", "Spender address (defaults to Loans contract)")
    .option("--amount <uint256>", "Approval amount (defaults to max uint256)", MAX_UINT256)
    .action(function (this: Command, opts: { smartAccount: string; spender?: string; amount: string }) {
      const deployment = resolveDeployment(this)
      const spenderAddress = resolveSpender(opts.spender, deployment.root, deployment.config)
      const currencyAddress = resolveCurrency(deployment)
      const approveCalldata = castCalldata("approve(address,uint256)", [spenderAddress, opts.amount])

      const { txHashes } = safeExec(opts.smartAccount, currencyAddress, approveCalldata, deployment)

      outputResult(this, {
        status: "ok",
        command: "approve-currency set",
        data: {
          smartAccount: opts.smartAccount,
          spender: spenderAddress,
          currencyAddress,
          amount: displayAmount(opts.amount, MAX_UINT256),
          txHashes,
        },
      })
    })

  cmd
    .command("check")
    .description("Check the current ERC20 allowance for a spender on a smart account")
    .requiredOption("--smart-account <address>", "Smart account (Safe) address")
    .option("--spender <address>", "Spender address (defaults to Loans contract)")
    .action(function (this: Command, opts: { smartAccount: string; spender?: string }) {
      const deployment = resolveDeployment(this)
      const spenderAddress = resolveSpender(opts.spender, deployment.root, deployment.config)
      const currencyAddress = resolveCurrency(deployment)

      const allowance = castCall(
        currencyAddress,
        "allowance(address,address)(uint256)",
        [opts.smartAccount, spenderAddress],
        deployment
      )

      outputResult(this, {
        status: "ok",
        command: "approve-currency check",
        data: {
          smartAccount: opts.smartAccount,
          spender: spenderAddress,
          currencyAddress,
          allowance,
          isMaxApproval: isMaxAllowance(allowance),
        },
      })
    })
}
