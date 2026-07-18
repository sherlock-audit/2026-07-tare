import type { Command } from "commander"
import { resolveDeployment, castCall, castCalldata, safeExec } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import { logProgress } from "../lib/utils.js"
import { readMinDelay, scheduleAndExecuteBatch, buildTimelockBatch } from "../lib/timelock.js"
import { loadGrantRolesManifest } from "../lib/grant-roles/manifest.js"
import { resolveGrantRolesContext, assertGrantRolesPreconditions } from "../lib/grant-roles/resolve.js"
import { readRoleIds, buildGrantCalls } from "../lib/grant-roles/build.js"
import { checkGrantedRoles, checksToRecord } from "../lib/grant-roles/checks.js"
import type { GrantRolesContext } from "../lib/grant-roles/types.js"
import { getThreshold, hasRole, isOwner } from "../lib/onchain.js"
import { assertAddressField } from "../lib/manifest.js"
import { rolesManifestPath } from "../lib/roles-manifest.js"

/**
 * The `SHAREHOLDER_ROLE` grant is the one setup-time grant that does not go
 * through the Timelock — `WHITELISTER_ROLE` is its role admin, so it executes
 * from the Whitelister Safe. In production that is a Safe-UI flow; wherever the
 * Whitelister Safe is threshold-1 (rehearsal, local bake) the same SafeExec
 * path as the rest of the setup applies.
 */
function shareholderGrant(ctx: GrantRolesContext) {
  const shareholderSa = (ctx.manifest as unknown as Record<string, string>).shareholderSa
  const roleId = castCall(ctx.vaultShareToken, "SHAREHOLDER_ROLE()(bytes32)", [], ctx.deployment)
  return {
    label: `VaultShareToken.grantRole(SHAREHOLDER_ROLE, ${shareholderSa})`,
    satisfied: () => hasRole(ctx.vaultShareToken, roleId, shareholderSa, ctx.deployment),
    execute: (): string[] => {
      const whitelisterSafe = ctx.manifest.whitelisterSafe
      if (!isOwner(whitelisterSafe, ctx.sender, ctx.deployment)) {
        throw new Error(`sender ${ctx.sender} is not an owner of whitelisterSafe ${whitelisterSafe}`)
      }
      const threshold = getThreshold(whitelisterSafe, ctx.deployment)
      if (threshold !== 1) {
        throw new Error(
          `whitelisterSafe threshold is ${threshold}, expected 1 — execute the SHAREHOLDER_ROLE grant via the Safe UI instead`
        )
      }
      const data = castCalldata("grantRole(bytes32,address)", [roleId, shareholderSa])
      return safeExec(whitelisterSafe, ctx.vaultShareToken, data, ctx.deployment, { sender: ctx.sender }).txHashes
    },
  }
}

export function registerGrantRoles(program: Command): void {
  program
    .command("grant-roles")
    .description(
      "Batch the setup-time guardian role grants into a single Timelock scheduleBatch + executeBatch from the Proposer Safe."
    )
    .option("--input <path>", "Path to the grant-roles manifest JSON (default: derived roles/latest.json)")
    .option("--dry-run", "Validate, encode, and report without sending transactions")
    .option(
      "--include-shareholder-grant",
      "Also grant SHAREHOLDER_ROLE to the shareholder SA from the Whitelister Safe (threshold-1 Safes only)"
    )
    .action(async function (
      this: Command,
      opts: { input?: string; dryRun?: boolean; includeShareholderGrant?: boolean }
    ) {
      const cmd = this
      const deployment = resolveDeployment(cmd)
      const dryRun = opts.dryRun ?? false
      const includeShareholder = opts.includeShareholderGrant ?? false

      const manifestPath = rolesManifestPath(deployment.root, deployment.config, opts.input)
      const manifest = loadGrantRolesManifest(manifestPath)
      if (includeShareholder) {
        const errors: string[] = []
        assertAddressField("shareholderSa", (manifest as unknown as Record<string, unknown>).shareholderSa, errors)
        if (errors.length > 0) throw new Error(`invalid manifest ${manifestPath}:\n  - ${errors.join("\n  - ")}`)
      }
      const ctx = resolveGrantRolesContext(deployment, manifest)

      logProgress("Checking preconditions")
      assertGrantRolesPreconditions(ctx)

      const roleIds = readRoleIds(ctx)
      const shareholder = includeShareholder ? shareholderGrant(ctx) : undefined

      // Idempotency guard: if every grant is already in place, do nothing.
      const preChecks = checkGrantedRoles(ctx, roleIds)
      const batchSatisfied = preChecks.every((check) => check.satisfied)
      const shareholderSatisfied = shareholder ? shareholder.satisfied() : true
      const allChecks = () => ({
        ...checksToRecord(checkGrantedRoles(ctx, roleIds)),
        ...(shareholder ? { [shareholder.label]: shareholder.satisfied() } : {}),
      })

      if (batchSatisfied && shareholderSatisfied) {
        outputResult(cmd, {
          status: "ok",
          command: "grant-roles",
          data: { scheduled: 0, executed: 0, skipped: includeShareholder ? 6 : 5, checks: allChecks() },
        })
        return
      }

      const grantCalls = buildGrantCalls(ctx, roleIds)
      const operation = buildTimelockBatch(ctx.timelock, grantCalls, ctx.manifest.salt, deployment)
      const minDelay = readMinDelay(ctx.timelock, deployment)
      // grant-roles only runs during the setup window, where the timelock
      // minDelay is 0 and schedule + execute happen back-to-back.
      const nonZeroDelayNote =
        minDelay > 0
          ? `timelock minDelay is ${minDelay}s; grant-roles only runs during the setup window (delay 0)`
          : undefined

      if (dryRun) {
        outputResult(cmd, {
          status: "ok",
          command: "grant-roles",
          data: {
            dryRun: true,
            operationId: operation.operationId,
            scheduleCalldata: operation.scheduleCalldata,
            minDelay,
            ...(nonZeroDelayNote && !batchSatisfied
              ? { warning: `${nonZeroDelayNote} — a live run would fail fast; schedule and execute separately` }
              : {}),
            grants: [
              ...grantCalls.map((call) => call.label),
              ...(shareholder ? [`${shareholder.label} (via whitelisterSafe)`] : []),
            ],
            checks: allChecks(),
          },
        })
        return
      }

      let scheduleTxHashes: string[] = []
      let executeTxHash: string | undefined
      let executed = 0

      if (!batchSatisfied) {
        // Fail fast before scheduling so nothing is left half-applied on-chain.
        if (nonZeroDelayNote) {
          outputResult(cmd, {
            status: "error",
            command: "grant-roles",
            data: {
              message: `${nonZeroDelayNote}. Schedule and execute the batch separately once the delay elapses.`,
              minDelay,
            },
          })
          process.exit(1)
        }

        const batchResult = await scheduleAndExecuteBatch(
          {
            timelock: ctx.timelock,
            proposerSafe: ctx.proposerSafe,
            sender: ctx.sender,
            batch: operation,
          },
          deployment
        )
        scheduleTxHashes = batchResult.scheduleTxHashes
        executeTxHash = batchResult.executeTxHash
        executed = 5

        // Re-verify every grant landed; a missing grant fails the command.
        const postChecks = checkGrantedRoles(ctx, roleIds)
        const missing = postChecks.filter((check) => !check.satisfied)
        if (missing.length > 0) {
          outputResult(cmd, {
            status: "error",
            command: "grant-roles",
            data: {
              message: `grant verification failed after executeBatch: ${missing.map((check) => check.label).join(", ")}`,
              operationId: operation.operationId,
              scheduleTxHashes,
              executeTxHash,
              checks: checksToRecord(postChecks),
            },
          })
          process.exit(1)
        }
      }

      let shareholderTxHashes: string[] = []
      if (shareholder && !shareholder.satisfied()) {
        logProgress(`Granting SHAREHOLDER_ROLE via whitelisterSafe ${ctx.manifest.whitelisterSafe}`)
        shareholderTxHashes = shareholder.execute()
        executed += 1
        if (!shareholder.satisfied()) {
          outputResult(cmd, {
            status: "error",
            command: "grant-roles",
            data: { message: `grant verification failed: ${shareholder.label}`, shareholderTxHashes },
          })
          process.exit(1)
        }
      }

      outputResult(cmd, {
        status: "ok",
        command: "grant-roles",
        data: {
          scheduled: batchSatisfied ? 0 : 5,
          executed,
          skipped: (includeShareholder ? 6 : 5) - executed,
          operationId: operation.operationId,
          ...(scheduleTxHashes.length > 0
            ? { scheduleTxHash: scheduleTxHashes[scheduleTxHashes.length - 1], scheduleTxHashes }
            : {}),
          ...(executeTxHash ? { executeTxHash } : {}),
          ...(shareholderTxHashes.length > 0 ? { shareholderTxHashes } : {}),
          checks: allChecks(),
        },
      })
    })
}
