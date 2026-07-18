import { createPublicClient, http, type Hex, type Abi, type PublicClient, type Hash } from "viem"
import { loansAbi, trustedCallsAbi, trustedSpenderAbi, multiSendCallOnlyAbi } from "../../../src/abis.js"
import { deployments, type Deployment } from "../../../src/deployments.js"
import { simulateCall, type RevertError } from "./errors.js"
import {
  unwrapSafeTransaction,
  unwrapTrustedCall,
  unwrapTrustedCallBatch,
  unwrapMultiSend,
  tryDecodeFunctionName,
  type TrustedCallInner,
} from "./unwrap.js"

export type { RevertError } from "./errors.js"

export interface DebugResult {
  txHash: Hash
  status: "success" | "reverted" | "not-found"
  blockNumber?: bigint
  callStack: CallStackEntry[]
  revertError?: RevertError
  innerCalls?: InnerCallResult[]
}

export interface CallStackEntry {
  from: Hex
  to: Hex
  functionName?: string
  contractName?: string
}

export interface InnerCallResult {
  index: number
  label: string
  from: Hex
  to: Hex
  error?: RevertError
}

interface DebugContext {
  client: PublicClient
  deployment: Deployment | undefined
  blockNumber: bigint
  safeAddress: Hex
  txHash: Hash
  knownAbis: { abi: Abi; name: string }[]
  callStack: CallStackEntry[]
}

function findDeployment(chainId: number): Deployment | undefined {
  return Object.values(deployments).find((d) => d.chain.id === chainId)
}

function identifyContract(address: Hex, deployment: Deployment | undefined): string | undefined {
  if (!deployment) return undefined
  const lower = address.toLowerCase()
  for (const [name, addr] of Object.entries(deployment.contracts)) {
    if (addr && addr.toLowerCase() === lower) return name
  }
  return undefined
}

function revertedResult(ctx: DebugContext, extra: Omit<DebugResult, "txHash" | "status" | "blockNumber" | "callStack">): DebugResult {
  return { txHash: ctx.txHash, status: "reverted", blockNumber: ctx.blockNumber, callStack: ctx.callStack, ...extra }
}

async function simulateTrustedCall(
  ctx: DebugContext,
  tcAddress: Hex,
  tcCalldata: Hex,
  tc: TrustedCallInner,
): Promise<RevertError | undefined> {
  const innerError = await simulateCall(ctx.client, tc.safe, tc.target, tc.innerData, ctx.blockNumber)
  if (innerError) return innerError

  return await simulateCall(ctx.client, ctx.safeAddress, tcAddress, tcCalldata, ctx.blockNumber)
}

// --- Pipeline handlers ---

async function tryDebugMultiSend(
  ctx: DebugContext,
  innerTo: Hex,
  innerData: Hex,
  operation: number,
): Promise<DebugResult | null> {
  if (operation !== 1) return null

  const innerOps = unwrapMultiSend(innerData)
  if (!innerOps) return null

  ctx.callStack.push({
    from: ctx.safeAddress,
    to: innerTo,
    functionName: "MultiSendCallOnly.multiSend",
    contractName: "MultiSendCallOnly",
  })

  const innerResults: InnerCallResult[] = []

  for (let i = 0; i < innerOps.length; i++) {
    const op = innerOps[i]
    const contractName = identifyContract(op.to, ctx.deployment)

    const tc = unwrapTrustedCall(op.data)
    if (tc) {
      const targetName = identifyContract(tc.target, ctx.deployment)
      const fnName = tryDecodeFunctionName(tc.innerData, ctx.knownAbis)

      ctx.callStack.push({
        from: ctx.safeAddress,
        to: op.to,
        functionName: "TrustedCalls.executeTrustedCall",
        contractName: contractName ?? "TrustedCalls",
      })
      ctx.callStack.push({
        from: tc.safe,
        to: tc.target,
        functionName: fnName,
        contractName: targetName,
      })

      const error = await simulateTrustedCall(ctx, op.to, op.data, tc)
      innerResults.push({
        index: i,
        label: fnName ?? `call[${i}]`,
        from: error ? tc.safe : ctx.safeAddress,
        to: error ? tc.target : op.to,
        error,
      })
    } else {
      const fnName = tryDecodeFunctionName(op.data, ctx.knownAbis)
      ctx.callStack.push({
        from: ctx.safeAddress,
        to: op.to,
        functionName: fnName,
        contractName: contractName,
      })

      const error = await simulateCall(ctx.client, ctx.safeAddress, op.to, op.data, ctx.blockNumber)
      innerResults.push({
        index: i,
        label: fnName ?? `call[${i}]`,
        from: ctx.safeAddress,
        to: op.to,
        error,
      })
    }
  }

  const firstFailing = innerResults.find((r) => r.error)
  return revertedResult(ctx, { revertError: firstFailing?.error, innerCalls: innerResults })
}

async function tryDebugTrustedCall(
  ctx: DebugContext,
  innerTo: Hex,
  innerData: Hex,
): Promise<DebugResult | null> {
  const tc = unwrapTrustedCall(innerData)
  if (!tc) return null

  const tcName = identifyContract(innerTo, ctx.deployment)
  const targetName = identifyContract(tc.target, ctx.deployment)
  const fnName = tryDecodeFunctionName(tc.innerData, ctx.knownAbis)

  ctx.callStack.push({
    from: ctx.safeAddress,
    to: innerTo,
    functionName: "TrustedCalls.executeTrustedCall",
    contractName: tcName ?? "TrustedCalls",
  })
  ctx.callStack.push({
    from: tc.safe,
    to: tc.target,
    functionName: fnName,
    contractName: targetName,
  })

  const error = await simulateTrustedCall(ctx, innerTo, innerData, tc)
  return revertedResult(ctx, {
    revertError: error ?? { name: "UnknownRevert", message: "Could not determine revert reason" },
  })
}

async function tryDebugTrustedCallBatch(
  ctx: DebugContext,
  innerTo: Hex,
  innerData: Hex,
): Promise<DebugResult | null> {
  const batch = unwrapTrustedCallBatch(innerData)
  if (!batch) return null

  const tcName = identifyContract(innerTo, ctx.deployment)
  ctx.callStack.push({
    from: ctx.safeAddress,
    to: innerTo,
    functionName: "TrustedCalls.executeTrustedCallBatch",
    contractName: tcName ?? "TrustedCalls",
  })

  const innerResults: InnerCallResult[] = []
  for (let i = 0; i < batch.targets.length; i++) {
    const target = batch.targets[i]
    const data = batch.innerDatas[i]
    const targetName = identifyContract(target, ctx.deployment)
    const fnName = tryDecodeFunctionName(data, ctx.knownAbis)

    ctx.callStack.push({
      from: batch.safe,
      to: target,
      functionName: fnName,
      contractName: targetName,
    })

    const error = await simulateCall(ctx.client, batch.safe, target, data, ctx.blockNumber)
    innerResults.push({
      index: i,
      label: fnName ?? `call[${i}]`,
      from: batch.safe,
      to: target,
      error,
    })
  }

  const firstFailing = innerResults.find((r) => r.error)
  return revertedResult(ctx, { revertError: firstFailing?.error, innerCalls: innerResults })
}

async function debugDirectCall(
  ctx: DebugContext,
  innerTo: Hex,
  innerData: Hex,
): Promise<DebugResult> {
  const contractName = identifyContract(innerTo, ctx.deployment)
  const fnName = tryDecodeFunctionName(innerData, ctx.knownAbis)
  ctx.callStack.push({
    from: ctx.safeAddress,
    to: innerTo,
    functionName: fnName,
    contractName: contractName,
  })

  const error = await simulateCall(ctx.client, ctx.safeAddress, innerTo, innerData, ctx.blockNumber)
  return revertedResult(ctx, {
    revertError: error ?? { name: "UnknownRevert", message: "Could not determine revert reason" },
  })
}

// --- Main entry point ---

export async function debugTransaction(txHash: Hash, rpcUrl: string): Promise<DebugResult> {
  const client = createPublicClient({ transport: http(rpcUrl) })

  let tx: Awaited<ReturnType<typeof client.getTransaction>>
  try {
    tx = await client.getTransaction({ hash: txHash })
  } catch {
    return { txHash, status: "not-found", callStack: [] }
  }

  let receipt: Awaited<ReturnType<typeof client.getTransactionReceipt>>
  try {
    receipt = await client.getTransactionReceipt({ hash: txHash })
  } catch {
    return { txHash, status: "not-found", callStack: [] }
  }

  if (receipt.status === "success") {
    return { txHash, status: "success", blockNumber: receipt.blockNumber, callStack: [] }
  }

  const chainId = await client.getChainId()
  const safeAddress = tx.to as Hex

  const ctx: DebugContext = {
    client,
    deployment: findDeployment(chainId),
    blockNumber: receipt.blockNumber,
    safeAddress,
    txHash,
    knownAbis: [
      { abi: loansAbi as Abi, name: "Loans" },
      { abi: trustedCallsAbi as Abi, name: "TrustedCalls" },
      { abi: trustedSpenderAbi as Abi, name: "TrustedSpender" },
      { abi: multiSendCallOnlyAbi as Abi, name: "MultiSendCallOnly" },
    ],
    callStack: [
      {
        from: tx.from as Hex,
        to: safeAddress,
        functionName: "Safe.execTransaction",
        contractName: identifyContract(safeAddress, findDeployment(chainId)) ?? "Safe",
      },
    ],
  }

  const safeInner = unwrapSafeTransaction(tx.input as Hex)
  if (!safeInner) {
    const error = await simulateCall(client, tx.from as Hex, safeAddress, tx.input as Hex, ctx.blockNumber)
    return revertedResult(ctx, { revertError: error ?? { name: "UnknownRevert" } })
  }

  const { innerTo, innerData, operation } = safeInner

  const pipeline = [
    () => tryDebugMultiSend(ctx, innerTo, innerData, operation),
    () => tryDebugTrustedCall(ctx, innerTo, innerData),
    () => tryDebugTrustedCallBatch(ctx, innerTo, innerData),
  ]

  for (const handler of pipeline) {
    const result = await handler()
    if (result) return result
  }

  return debugDirectCall(ctx, innerTo, innerData)
}

export function formatDebugResult(result: DebugResult): string {
  const lines: string[] = []

  lines.push(`Transaction: ${result.txHash}`)
  lines.push(`Status: ${result.status}`)
  if (result.blockNumber !== undefined) {
    lines.push(`Block: ${result.blockNumber}`)
  }

  if (result.status === "success") {
    lines.push("\nTransaction succeeded — no revert to debug.")
    return lines.join("\n")
  }

  if (result.status === "not-found") {
    lines.push("\nTransaction not found. Check the hash and RPC URL.")
    return lines.join("\n")
  }

  if (result.callStack.length > 0) {
    lines.push("\nCall stack:")
    result.callStack.forEach((entry, i) => {
      const indent = "  ".repeat(i)
      const fn = entry.functionName ?? "unknown"
      const contract = entry.contractName ? `(${entry.contractName})` : ""
      lines.push(`${indent}→ ${fn} ${contract}`)
      lines.push(`${indent}  from: ${entry.from}`)
      lines.push(`${indent}  to:   ${entry.to}`)
    })
  }

  if (result.revertError) {
    lines.push("\nRevert reason:")
    lines.push(`  Error: ${result.revertError.name}`)
    if (result.revertError.message) {
      lines.push(`  Message: ${result.revertError.message}`)
    }
    if (result.revertError.args && Object.keys(result.revertError.args).length > 0) {
      lines.push(`  Args: ${JSON.stringify(result.revertError.args)}`)
    }
    if (result.revertError.raw) {
      lines.push(`  Raw: ${result.revertError.raw}`)
    }
  }

  if (result.innerCalls && result.innerCalls.length > 1) {
    lines.push("\nInner calls:")
    for (const call of result.innerCalls) {
      const status = call.error ? "FAIL" : "OK"
      lines.push(`  [${call.index}] ${call.label}: ${status}`)
      if (call.error) {
        lines.push(`       Error: ${call.error.name}`)
        if (call.error.message) lines.push(`       Message: ${call.error.message}`)
      }
    }
  }

  return lines.join("\n")
}
