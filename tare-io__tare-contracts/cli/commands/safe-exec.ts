import type { Command } from "commander"
import { resolveDeployment, castCalldata, getSenderAddress, safeExec } from "../lib/cast.js"
import { getThreshold, isOwner, isSafe } from "../lib/onchain.js"
import { outputResult } from "../lib/output.js"

export function registerSafeExec(program: Command): void {
  program
    .command("safe-exec")
    .description(
      "Execute a call from a threshold-1 Safe via script/SafeExec.s.sol — replaces the SAFE_ADDRESS/TARGET_ADDRESS/CALL_DATA env-var forge invocation."
    )
    .requiredOption("--safe <address>", "Safe to execute from (sender must be an owner; threshold must be 1)")
    .requiredOption("--target <address>", "Target contract the Safe calls")
    .option("--calldata <hex>", "Pre-encoded calldata")
    .option("--sig <signature>", "Function signature to encode, e.g. 'transfer(address,uint256)'")
    .option("--args <values>", "Comma-separated arguments for --sig")
    .action(function (
      this: Command,
      opts: { safe: string; target: string; calldata?: string; sig?: string; args?: string }
    ) {
      const deployment = resolveDeployment(this)
      const sender = getSenderAddress(deployment)

      if (!opts.calldata && !opts.sig) throw new Error("either --calldata or --sig is required")
      if (opts.calldata && opts.sig) throw new Error("--calldata and --sig are mutually exclusive")
      const callData = opts.calldata ?? castCalldata(opts.sig!, opts.args ? opts.args.split(",") : [])

      if (!isSafe(opts.safe, deployment)) {
        throw new Error(`${opts.safe} is not a Gnosis Safe (getOwners() failed)`)
      }
      if (!isOwner(opts.safe, sender, deployment)) {
        throw new Error(`sender ${sender} is not an owner of Safe ${opts.safe}`)
      }
      const threshold = getThreshold(opts.safe, deployment)
      if (threshold !== 1) {
        throw new Error(`Safe threshold is ${threshold}, expected 1 (multi-sig Safes go through the Safe UI)`)
      }

      const { txHashes } = safeExec(opts.safe, opts.target, callData, deployment, { sender })
      outputResult(this, {
        status: "ok",
        command: "safe-exec",
        data: { safe: opts.safe, target: opts.target, callData, txHashes },
      })
    })
}
