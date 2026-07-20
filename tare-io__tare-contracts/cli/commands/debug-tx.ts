import type { Command } from "commander"
import { isJsonMode } from "../lib/output.js"
import { DEFAULT_ANVIL_RPC } from "../lib/constants.js"
import type { Hex } from "viem"

export function registerDebugTx(program: Command): void {
  program
    .command("debug-tx")
    .description("Debug a reverted transaction by unwrapping Safe layers and simulating inner calls")
    .argument("<txHash>", "Transaction hash to debug")
    .option("-r, --rpc-url <url>", "RPC URL (defaults to Anvil)", process.env.ANVIL_RPC ?? DEFAULT_ANVIL_RPC)
    .action(async function (this: Command, txHash: string, opts: { rpcUrl: string }) {
      const { debugTransaction, formatDebugResult } = await import("../lib/debug-tx/index.js")
      const result = await debugTransaction(txHash as Hex, opts.rpcUrl)

      if (isJsonMode(this)) {
        const serializable = serializeResult(result)
        process.stdout.write(JSON.stringify(serializable) + "\n")
      } else {
        console.log(formatDebugResult(result))
      }
    })
}

function serializeResult(result: {
  txHash: string
  status: string
  blockNumber?: bigint
  callStack: unknown[]
  revertError?: unknown
  innerCalls?: unknown[]
}): Record<string, unknown> {
  return {
    txHash: result.txHash,
    status: result.status,
    blockNumber: result.blockNumber?.toString(),
    callStack: result.callStack,
    revertError: result.revertError,
    innerCalls: result.innerCalls,
  }
}
