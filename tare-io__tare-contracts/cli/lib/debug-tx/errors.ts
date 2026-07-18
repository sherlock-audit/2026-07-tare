import { decodeErrorResult, type Hex, type Abi, type PublicClient } from "viem"
import {
  loansAbi,
  trustedCallsAbi,
  trustedSpenderAbi,
  multiSendCallOnlyAbi,
  smartAccountFactoryAbi,
  usdcAbi,
} from "../../../src/abis.js"

export interface RevertError {
  name: string
  args?: Record<string, unknown>
  raw?: Hex
  message?: string
}

const allAbis: Abi = [
  ...loansAbi,
  ...trustedCallsAbi,
  ...trustedSpenderAbi,
  ...multiSendCallOnlyAbi,
  ...smartAccountFactoryAbi,
  ...usdcAbi,
] as Abi

const ERROR_STRING_SELECTOR = "0x08c379a0" // Error(string)
const PANIC_UINT256_SELECTOR = "0x4e487b71" // Panic(uint256)

export function decodeRevertData(data: Hex): RevertError {
  try {
    const decoded = decodeErrorResult({ abi: allAbis, data })
    const args: Record<string, unknown> = {}
    if (decoded.args && Array.isArray(decoded.args)) {
      decoded.args.forEach((arg, i) => {
        args[`arg${i}`] = typeof arg === "bigint" ? arg.toString() : arg
      })
    }
    return { name: decoded.errorName, args, raw: data }
  } catch {
    // not a known custom error
  }

  if (data.startsWith(ERROR_STRING_SELECTOR)) {
    try {
      const decoded = decodeErrorResult({
        abi: [{ type: "error", name: "Error", inputs: [{ name: "message", type: "string" }] }],
        data,
      })
      return { name: "Error", message: String(decoded.args?.[0] ?? ""), raw: data }
    } catch {
      // fallthrough
    }
  }

  if (data.startsWith(PANIC_UINT256_SELECTOR)) {
    try {
      const decoded = decodeErrorResult({
        abi: [{ type: "error", name: "Panic", inputs: [{ name: "code", type: "uint256" }] }],
        data,
      })
      return { name: "Panic", args: { code: String(decoded.args?.[0] ?? "") }, raw: data }
    } catch {
      // fallthrough
    }
  }

  if (data.length >= 10) {
    try {
      const text = Buffer.from(data.slice(2), "hex").toString("utf8").replace(/[^\x20-\x7E]/g, "")
      if (text.length > 0) return { name: "UnknownRevert", message: text, raw: data }
    } catch {
      // fallthrough
    }
  }

  return { name: "UnknownRevert", raw: data }
}

export async function simulateCall(
  client: PublicClient,
  from: Hex,
  to: Hex,
  data: Hex,
  blockNumber: bigint,
): Promise<RevertError | undefined> {
  try {
    await client.call({ account: from, to, data, blockNumber })
    return undefined
  } catch (error: unknown) {
    if (error && typeof error === "object") {
      const err = error as Record<string, unknown>

      if ("data" in err && typeof err.data === "string" && err.data.startsWith("0x")) {
        return decodeRevertData(err.data as Hex)
      }

      let cause = "cause" in err ? err.cause : undefined
      while (cause && typeof cause === "object") {
        const c = cause as Record<string, unknown>
        if ("data" in c && typeof c.data === "string" && c.data.startsWith("0x")) {
          return decodeRevertData(c.data as Hex)
        }
        cause = "cause" in c ? c.cause : undefined
      }

      const message = "message" in err ? String(err.message) : "Simulation failed"
      const hexMatch = message.match(/revert(?:ed)?.*?(0x[0-9a-fA-F]+)/)
      if (hexMatch) {
        return decodeRevertData(hexMatch[1] as Hex)
      }
      return { name: "SimulationFailed", message }
    }

    return { name: "SimulationFailed", message: String(error) }
  }
}
