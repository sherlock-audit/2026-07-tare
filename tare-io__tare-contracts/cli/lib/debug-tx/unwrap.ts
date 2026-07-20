import { decodeFunctionData, type Hex, type Abi } from "viem"
import { trustedCallsAbi, multiSendCallOnlyAbi } from "../../../src/abis.js"

const safeExecTransactionAbi = [
  {
    inputs: [
      { name: "to", type: "address" },
      { name: "value", type: "uint256" },
      { name: "data", type: "bytes" },
      { name: "operation", type: "uint8" },
      { name: "safeTxGas", type: "uint256" },
      { name: "baseGas", type: "uint256" },
      { name: "gasPrice", type: "uint256" },
      { name: "gasToken", type: "address" },
      { name: "refundReceiver", type: "address" },
      { name: "signatures", type: "bytes" },
    ],
    name: "execTransaction",
    outputs: [{ type: "bool", name: "success" }],
    stateMutability: "payable",
    type: "function",
  },
] as const

export interface SafeInner {
  innerTo: Hex
  innerData: Hex
  operation: number
}

export interface TrustedCallInner {
  safe: Hex
  target: Hex
  innerData: Hex
}

export interface TrustedCallBatchInner {
  safe: Hex
  targets: Hex[]
  innerDatas: Hex[]
}

export interface MultiSendOp {
  operation: number
  to: Hex
  value: bigint
  data: Hex
}

export function unwrapSafeTransaction(txInput: Hex): SafeInner | undefined {
  try {
    const decoded = decodeFunctionData({ abi: safeExecTransactionAbi, data: txInput })
    if (decoded.functionName !== "execTransaction") return undefined
    const [to, , data, operation] = decoded.args
    return { innerTo: to as Hex, innerData: data as Hex, operation: operation as number }
  } catch {
    return undefined
  }
}

export function unwrapTrustedCall(data: Hex): TrustedCallInner | undefined {
  try {
    const decoded = decodeFunctionData({ abi: trustedCallsAbi as Abi, data })
    if (decoded.functionName === "executeTrustedCall") {
      const [safe, target, innerData] = decoded.args as [Hex, Hex, Hex]
      return { safe, target, innerData }
    }
    return undefined
  } catch {
    return undefined
  }
}

export function unwrapTrustedCallBatch(data: Hex): TrustedCallBatchInner | undefined {
  try {
    const decoded = decodeFunctionData({ abi: trustedCallsAbi as Abi, data })
    if (decoded.functionName === "executeTrustedCallBatch") {
      const [safe, targets, innerDatas] = decoded.args as [Hex, Hex[], Hex[]]
      return { safe, targets, innerDatas }
    }
    return undefined
  } catch {
    return undefined
  }
}

export function unwrapMultiSend(data: Hex): MultiSendOp[] | undefined {
  try {
    const decoded = decodeFunctionData({ abi: multiSendCallOnlyAbi as Abi, data })
    if (decoded.functionName === "multiSend" && decoded.args) {
      return decodeMultiSendData(decoded.args[0] as Hex)
    }
    return undefined
  } catch {
    return undefined
  }
}

function decodeMultiSendData(data: Hex): MultiSendOp[] {
  const results: MultiSendOp[] = []
  let offset = 2

  while (offset < data.length) {
    const operation = parseInt(data.slice(offset, offset + 2), 16)
    offset += 2

    const to = `0x${data.slice(offset, offset + 40)}` as Hex
    offset += 40

    const value = BigInt(`0x${data.slice(offset, offset + 64)}`)
    offset += 64

    const dataLength = parseInt(data.slice(offset, offset + 64), 16)
    offset += 64

    const callData = `0x${data.slice(offset, offset + dataLength * 2)}` as Hex
    offset += dataLength * 2

    results.push({ operation, to, value, data: callData })
  }

  return results
}

export function tryDecodeFunctionName(data: Hex, knownAbis: { abi: Abi; name: string }[]): string | undefined {
  for (const { abi, name } of knownAbis) {
    try {
      const decoded = decodeFunctionData({ abi, data })
      if (decoded.functionName) return `${name}.${decoded.functionName}`
    } catch {
      // not this ABI
    }
  }
  return undefined
}
