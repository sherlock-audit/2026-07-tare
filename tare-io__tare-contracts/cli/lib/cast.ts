import { execFileSync } from "child_process"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import type { Command } from "commander"
import { getDeploymentConfig, getChainConfig, type DeploymentConfig, type ChainConfig } from "./deployment-configs.js"
import { loadDeploymentManifest } from "./utils.js"
import { ZERO_ADDRESS } from "./constants.js"
import type { DeploymentComponent } from "./shared/types.js"

export interface ResolvedDeployment {
  config: DeploymentConfig
  chainConfig: ChainConfig
  rpcUrl: string
  root: string
  privateKey?: string
}

/** Program-level options merged into every command via `optsWithGlobals()`. */
export interface GlobalOpts {
  name: string
  chain?: string
  root: string
  privateKey?: string
  account?: string
  deployerAddr?: string
  json?: boolean
}

/**
 * Decrypt an encrypted keystore account once via `cast wallet decrypt-keystore`.
 * The password prompt is shown interactively (inherited stdin/stderr).
 * The decrypted key is kept only in Node process memory.
 *
 * `cast wallet decrypt-keystore` prints a labeled line
 * (`<account>'s private key is: 0x…`), not the bare key, so extract the
 * 0x-prefixed 32-byte hex from the output.
 */
function decryptKeystore(account: string): string {
  const output = execFileSync("cast", ["wallet", "decrypt-keystore", account], {
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  })
  const match = output.match(/0x[0-9a-fA-F]{64}/)
  if (!match) throw new Error(`Could not parse private key from 'cast wallet decrypt-keystore ${account}' output`)
  return match[0]
}

export function resolveDeployment(cmd: Command): ResolvedDeployment {
  const { name, chain, root, privateKey, account } = cmd.optsWithGlobals() as GlobalOpts
  if (!chain) throw new Error("--chain is required")
  const config = getDeploymentConfig(`${chain}-${name}`)
  const chainConfig = getChainConfig(config.chain)
  const rpcUrl = chainConfig.rpc()
  if (!rpcUrl) throw new Error(`RPC URL not set for chain: ${config.chain}`)

  // Decrypt keystore once — key stays in Node process memory, prompted only once
  const resolvedKey = privateKey ?? (account ? decryptKeystore(account) : undefined)

  return { config, chainConfig, rpcUrl, root, privateKey: resolvedKey }
}

export function readContractAddress(root: string, config: DeploymentConfig, component: DeploymentComponent, contractName: string): string {
  const deployment = loadDeploymentManifest(root, config.chain, config.shortName, component)
  const address = deployment.contracts[contractName]
  if (!address) throw new Error(`Contract ${contractName} not found in ${config.chain}/${config.shortName}/${component}`)
  return address
}

export function castCall(address: string, signature: string, args: string[], deployment: ResolvedDeployment): string {
  return execFileSync(
    "cast",
    ["call", address, signature, ...args, "--rpc-url", deployment.rpcUrl],
    { encoding: "utf8" },
  ).trim()
}

export function castCalldata(signature: string, args: string[]): string {
  return execFileSync("cast", ["calldata", signature, ...args], { encoding: "utf8" }).trim()
}

function pushSignerArgs(castArgs: string[], deployment: ResolvedDeployment): void {
  if (deployment.privateKey) {
    castArgs.push("--private-key", deployment.privateKey)
  } else {
    throw new Error("--private-key or --account is required")
  }
}

export interface CastSendResult {
  txHash: string
  receipt: Record<string, unknown>
}

export function castSend(address: string, signature: string, args: string[], deployment: ResolvedDeployment): CastSendResult {
  const castArgs = [
    "send", address,
    signature, ...args,
    "--rpc-url", deployment.rpcUrl,
    "--json",
  ]

  pushSignerArgs(castArgs, deployment)

  const output = execFileSync("cast", castArgs, { encoding: "utf8" })
  const receipt = JSON.parse(output)
  return { txHash: receipt.transactionHash, receipt }
}


export function getSenderAddress(deployment: ResolvedDeployment): string {
  if (deployment.privateKey) {
    return execFileSync("cast", ["wallet", "address", "--private-key", deployment.privateKey], { encoding: "utf8" }).trim()
  }
  throw new Error("--private-key or --account is required to derive sender address")
}

export function isContract(address: string, deployment: ResolvedDeployment): boolean {
  const code = execFileSync("cast", ["code", address, "--rpc-url", deployment.rpcUrl], { encoding: "utf8" }).trim()
  return code !== "0x" && code.length > 2
}

export interface SafeExecOptions {
  sender?: string
}

export interface SafeExecResult {
  txHashes: string[]
}

export function safeExec(
  safeAddress: string,
  targetAddress: string,
  callData: string,
  deployment: ResolvedDeployment,
  options?: SafeExecOptions,
): SafeExecResult {
  if (!deployment.privateKey) throw new Error("--private-key or --account is required for Safe execution")
  const resolvedSender = options?.sender ?? getSenderAddress(deployment)
  const forgeArgs = [
    "script", resolve(deployment.root, "script/SafeExec.s.sol"),
    "--rpc-url", deployment.rpcUrl,
    "--private-key", deployment.privateKey,
    "--broadcast",
    "--sender", resolvedSender,
  ]
  execFileSync("forge", forgeArgs, {
    stdio: ["pipe", "pipe", "inherit"],
    cwd: deployment.root,
    env: {
      ...process.env,
      SAFE_ADDRESS: safeAddress,
      TARGET_ADDRESS: targetAddress,
      CALL_DATA: callData,
    },
  })

  const broadcastPath = resolve(deployment.root, `broadcast/SafeExec.s.sol/${deployment.chainConfig.chainId}/run-latest.json`)
  try {
    const broadcast = JSON.parse(readFileSync(broadcastPath, "utf8"))
    const txHashes = (broadcast.transactions as { hash: string }[]).map((t) => t.hash)
    return { txHashes }
  } catch {
    return { txHashes: [] }
  }
}

export function nestedSafeExec(
  outerSafe: string,
  innerSafe: string,
  targetAddress: string,
  callData: string,
  deployment: ResolvedDeployment,
  options?: SafeExecOptions,
): SafeExecResult {
  const nonce = castCall(innerSafe, "nonce()(uint256)", [], deployment)
  const safeTxHash = castCall(
    innerSafe,
    "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
    [targetAddress, "0", callData, "0", "0", "0", "0", ZERO_ADDRESS, ZERO_ADDRESS, nonce],
    deployment,
  )

  const approveHashData = castCalldata("approveHash(bytes32)", [safeTxHash])
  const { txHashes } = safeExec(outerSafe, innerSafe, approveHashData, deployment, options)

  const paddedOuterSafe = "0x000000000000000000000000" + outerSafe.slice(2) + "0000000000000000000000000000000000000000000000000000000000000000" + "01"
  const { txHash: execTxHash } = castSend(
    innerSafe,
    "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
    [targetAddress, "0", callData, "0", "0", "0", "0", ZERO_ADDRESS, ZERO_ADDRESS, paddedOuterSafe],
    deployment,
  )

  return { txHashes: [...txHashes, execTxHash] }
}
