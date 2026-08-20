import type { Command } from "commander"
import {
  resolveDeployment,
  readOptionalContractAddress,
  castCall,
  castCalldata,
  castSend,
  getSenderAddress,
  safeExec,
} from "../lib/cast.js"
import { castCallBool, getThreshold, isOwner, isSafe } from "../lib/onchain.js"
import { readRolesManifest, rolesManifestPath } from "../lib/roles-manifest.js"
import { planSenderUpdate, resolveAuthorizedSenders, resolveForwarder } from "../lib/forwarder.js"
import { arrayArg } from "../lib/utils.js"
import { outputResult } from "../lib/output.js"

export function registerForwarder(program: Command): void {
  const cmd = program.command("forwarder").description("Manage the Forwarder relay")

  cmd
    .command("set-senders")
    .description("Replace the Forwarder's authorized senders, executed from whichever address owns it")
    .requiredOption("--sender <address...>", "Authorized sender EOA(s) — the LMS relayer keys; replaces the whole set")
    .option("--forwarder <address>", "Forwarder address (default: roles manifest, then the deployment)")
    .action(function (this: Command, opts: { sender: string[]; forwarder?: string }) {
      const deployment = resolveDeployment(this)
      const { root, config } = deployment
      const signer = getSenderAddress(deployment)
      const senders = resolveAuthorizedSenders(opts.sender)

      // Lenient read: set-senders runs before the role SAs exist, so the full
      // setup-manifest validation must not apply — only `forwarder` is needed.
      const manifest = readRolesManifest(rolesManifestPath(root, config))
      const forwarder = resolveForwarder({
        option: opts.forwarder,
        manifest: manifest?.forwarder,
        deployment:
          readOptionalContractAddress(root, config, "forwarder", "Forwarder") ??
          readOptionalContractAddress(root, config, "accounts", "Forwarder"),
      })

      const owner = castCall(forwarder, "owner()(address)", [], deployment)
      const callData = castCalldata("setAuthorizedSenders(address[])", [arrayArg(senders)])
      const ownerIsSafe = isSafe(owner, deployment)
      const route = planSenderUpdate({
        forwarder,
        owner,
        signer,
        ownerIsSafe,
        signerOwnsSafe: ownerIsSafe && isOwner(owner, signer, deployment),
        safeThreshold: ownerIsSafe ? getThreshold(owner, deployment) : 0,
      })

      const txHashes =
        route.via === "safe"
          ? safeExec(route.safe, forwarder, callData, deployment, { sender: signer }).txHashes
          : [castSend(forwarder, "setAuthorizedSenders(address[])", [arrayArg(senders)], deployment).txHash]

      // A silently-unauthorized relayer only surfaces later, as every relayed call reverting.
      const unauthorized = senders.filter(
        (sender) => !castCallBool(forwarder, "isAuthorizedSender(address)(bool)", [sender], deployment)
      )
      if (unauthorized.length > 0) {
        throw new Error(`Forwarder ${forwarder} did not authorize ${unauthorized.join(", ")}`)
      }

      outputResult(this, {
        status: "ok",
        command: "forwarder set-senders",
        data: { forwarder, owner, senders, executedVia: route.via, txHashes },
      })
    })

  cmd
    .command("check")
    .description("Report the Forwarder's owner, protocol-currency guard and authorized senders")
    .option("--forwarder <address>", "Forwarder address (default: roles manifest, then the deployment)")
    .action(function (this: Command, opts: { forwarder?: string }) {
      const deployment = resolveDeployment(this)
      const { root, config } = deployment

      const manifest = readRolesManifest(rolesManifestPath(root, config))
      const forwarder = resolveForwarder({
        option: opts.forwarder,
        manifest: manifest?.forwarder,
        deployment:
          readOptionalContractAddress(root, config, "forwarder", "Forwarder") ??
          readOptionalContractAddress(root, config, "accounts", "Forwarder"),
      })

      outputResult(this, {
        status: "ok",
        command: "forwarder check",
        data: {
          forwarder,
          owner: castCall(forwarder, "owner()(address)", [], deployment),
          currencyGuard: castCall(forwarder, "linkToken()(address)", [], deployment),
          senders: castCall(forwarder, "getAuthorizedSenders()(address[])", [], deployment),
        },
      })
    })
}
