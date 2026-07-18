import { castSend, readContractAddress, type ResolvedDeployment } from "./cast.js"
import { parseAddressList } from "./utils.js"
import { NO_EXPIRY } from "./constants.js"

// keccak256("SmartAccountDeployed(address,address)") — the new SA address is the first indexed topic.
const SMART_ACCOUNT_DEPLOYED_TOPIC = "0x1e4196261ecbd8de94ed810204cd060e235016937c667857956ce1d2d3398785"

export interface SmartAccountParams {
  owners: string
  threshold: string
  delegates?: string
  currencies?: string
  nftCollections?: string
  trustedRecipients?: string
  validUntil?: string
}

export interface SmartAccountResult {
  smartAccountAddress: string
  factoryAddress: string
  txHash: string
}

/** Deploy a role smart account via `SmartAccountFactory.deploySmartAccount`. */
export function deploySmartAccountViaFactory(
  deployment: ResolvedDeployment,
  params: SmartAccountParams
): SmartAccountResult {
  const factoryAddress = readContractAddress(deployment.root, deployment.config, "accounts", "SmartAccountFactory")

  const args = [
    parseAddressList(params.delegates),
    parseAddressList(params.currencies),
    parseAddressList(params.nftCollections),
    parseAddressList(params.trustedRecipients),
    params.validUntil ?? NO_EXPIRY,
    parseAddressList(params.owners),
    params.threshold,
  ]

  const { txHash, receipt } = castSend(
    factoryAddress,
    "deploySmartAccount(address[],address[],address[],address[],uint48,address[],uint256)",
    args,
    deployment
  )

  const log = (receipt.logs as { topics: string[] }[]).find((l) => l.topics[0] === SMART_ACCOUNT_DEPLOYED_TOPIC)
  if (!log) throw new Error("SmartAccountDeployed event not found in transaction receipt")

  return { smartAccountAddress: "0x" + log.topics[1].slice(26), factoryAddress, txHash }
}
