import type { Command } from "commander"
import { resolveDeployment, readContractAddress, castCall, castCalldata, getSenderAddress } from "../lib/cast.js"
import { getThreshold, hasRole, isOwner } from "../lib/onchain.js"
import { outputResult } from "../lib/output.js"
import { logProgress } from "../lib/utils.js"
import { buildTimelockBatch, readMinDelay, scheduleAndExecuteBatch } from "../lib/timelock.js"
import { readRolesManifest, rolesManifestPath, requireManifestField } from "../lib/roles-manifest.js"

export function registerUpdateTimelockDelay(program: Command): void {
  program
    .command("update-timelock-delay")
    .description(
      "Raise the Timelock minDelay via a self-call scheduled from the Proposer Safe — the hardening step that closes the setup window."
    )
    .requiredOption("--min-delay <seconds>", "Target minimum delay, e.g. 129600 for 36h")
    .option("--proposer-safe <address>", "Proposer Safe (default: roles-manifest proposerSafe)")
    .option("--salt <string>", "Operation salt (default: <chain>-<name>:update-delay:<seconds>)")
    .action(async function (this: Command, opts: { minDelay: string; proposerSafe?: string; salt?: string }) {
      const cmd = this
      const deployment = resolveDeployment(cmd)
      const { root, config } = deployment

      const minDelay = Number.parseInt(opts.minDelay, 10)
      if (!Number.isInteger(minDelay) || minDelay < 0) throw new Error(`Invalid --min-delay: ${opts.minDelay}`)

      const timelock = readContractAddress(root, config, "timelock", "TimelockController")
      const manifestPath = rolesManifestPath(root, config)
      const proposerSafe =
        opts.proposerSafe ?? requireManifestField(readRolesManifest(manifestPath), "proposerSafe", manifestPath)
      const sender = getSenderAddress(deployment)

      const current = readMinDelay(timelock, deployment)
      if (current === minDelay) {
        outputResult(cmd, {
          status: "ok",
          command: "update-timelock-delay",
          data: { timelock, minDelay, status: "skipped", message: `minDelay is already ${minDelay}s` },
        })
        return
      }
      // The immediate schedule+execute pair only works while the delay is 0. Once
      // hardened, a delay change waits out the current delay — Safe UI territory.
      if (current !== 0) {
        throw new Error(
          `timelock minDelay is ${current}s, not 0 — schedule updateDelay(${minDelay}) from the Proposer Safe and execute it after the delay elapses`
        )
      }

      const proposerRole = castCall(timelock, "PROPOSER_ROLE()(bytes32)", [], deployment)
      if (!hasRole(timelock, proposerRole, proposerSafe, deployment)) {
        throw new Error(`proposerSafe ${proposerSafe} does not hold PROPOSER_ROLE on the timelock`)
      }
      if (!isOwner(proposerSafe, sender, deployment)) {
        throw new Error(`sender ${sender} is not an owner of proposerSafe ${proposerSafe}`)
      }
      const threshold = getThreshold(proposerSafe, deployment)
      if (threshold !== 1) {
        throw new Error(`proposerSafe threshold is ${threshold}, expected 1 (SafeExec requires threshold == 1)`)
      }

      const salt = opts.salt ?? `${config.chain}-${config.shortName}:update-delay:${minDelay}`
      const data = castCalldata("updateDelay(uint256)", [String(minDelay)])
      const batch = buildTimelockBatch(timelock, [{ target: timelock, data }], salt, deployment)

      logProgress(`Raising timelock minDelay ${current}s -> ${minDelay}s`)
      const { scheduleTxHashes, executeTxHash } = await scheduleAndExecuteBatch(
        { timelock, proposerSafe, sender, batch },
        deployment
      )

      const after = readMinDelay(timelock, deployment)
      if (after !== minDelay) {
        outputResult(cmd, {
          status: "error",
          command: "update-timelock-delay",
          data: {
            message: `minDelay is ${after}s after execution, expected ${minDelay}s`,
            scheduleTxHashes,
            executeTxHash,
          },
        })
        process.exit(1)
      }

      outputResult(cmd, {
        status: "ok",
        command: "update-timelock-delay",
        data: {
          timelock,
          minDelay,
          previousMinDelay: current,
          salt,
          operationId: batch.operationId,
          scheduleTxHashes,
          executeTxHash,
        },
      })
    })
}
