import { keccak256, toBytes } from "viem"
import { castCall, castCalldata, castSend, safeExec, type ResolvedDeployment } from "./cast.js"
import { arrayArg, logProgress } from "./utils.js"

const ZERO_BYTES32 = "0x" + "0".repeat(64)

/** Read an OZ `TimelockController`'s current minimum delay (seconds). */
export function readMinDelay(timelock: string, deployment: ResolvedDeployment): number {
  const value = castCall(timelock, "getMinDelay()(uint256)", [], deployment)
  // cast may render large uints with a thousands-formatted suffix; take the leading integer.
  return Number.parseInt(value.split(/\s/)[0], 10)
}

/** A single inner call bundled into a timelock batch. */
export interface TimelockCall {
  /** Target contract the timelock calls. */
  target: string
  /** ABI-encoded inner calldata. */
  data: string
}

/** A timelock batch operation, pre-encoded for both schedule and execute. */
export interface TimelockBatch {
  /** Operation id (`hashOperationBatch`), for logging/reporting. */
  operationId: string
  /** `scheduleBatch(...)` calldata (includes the trailing delay arg). */
  scheduleCalldata: string
  /** The five shared leading args reused by `executeBatch(...)`. */
  executeArgs: string[]
}

/**
 * Encode a timelock batch from a list of inner calls: arrays in call order,
 * zero values, zero predecessor, `delay = 0`, and a deterministic salt hashed
 * from `salt`. `grant-roles` only runs during the setup window where the
 * timelock `minDelay` is 0; callers must fail fast on any non-zero delay before
 * scheduling. The operation id is read from the timelock itself so it matches
 * the on-chain hash exactly.
 */
export function buildTimelockBatch(
  timelock: string,
  calls: TimelockCall[],
  salt: string,
  deployment: ResolvedDeployment
): TimelockBatch {
  const targets = calls.map((call) => call.target)
  const values = calls.map(() => "0")
  const payloads = calls.map((call) => call.data)
  const saltHash = keccak256(toBytes(salt))

  // The leading args are identical across scheduleBatch, executeBatch, and
  // hashOperationBatch — encode them once and reuse.
  const executeArgs = [arrayArg(targets), arrayArg(values), arrayArg(payloads), ZERO_BYTES32, saltHash]

  const operationId = castCall(
    timelock,
    "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)",
    executeArgs,
    deployment
  )

  // scheduleBatch appends the `delay` (0) to the shared args.
  const scheduleCalldata = castCalldata("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", [
    ...executeArgs,
    "0",
  ])

  return { operationId, scheduleCalldata, executeArgs }
}

export interface TimelockBatchResult {
  scheduleTxHashes: string[]
  executeTxHash: string
}

/**
 * Schedule a batch from the proposer Safe (via `SafeExec.s.sol`), then execute
 * it from the caller's EOA (open executor). Assumes the timelock delay is 0
 * (callers must fail fast on any non-zero delay before scheduling), so the
 * operation is ready as soon as the schedule tx is mined and `executeBatch`
 * can be sent immediately — its own transaction mines the block that satisfies
 * the timelock's `block.timestamp >= scheduledAt` readiness check.
 */
export async function scheduleAndExecuteBatch(
  params: { timelock: string; proposerSafe: string; sender: string; batch: TimelockBatch },
  deployment: ResolvedDeployment
): Promise<TimelockBatchResult> {
  const { timelock, proposerSafe, sender, batch } = params

  logProgress(`Scheduling batch ${batch.operationId} via proposer Safe ${proposerSafe}`)
  const { txHashes: scheduleTxHashes } = safeExec(proposerSafe, timelock, batch.scheduleCalldata, deployment, {
    sender,
  })

  logProgress("Executing batch")
  const { txHash: executeTxHash } = castSend(
    timelock,
    "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
    batch.executeArgs,
    deployment
  )

  return { scheduleTxHashes, executeTxHash }
}
