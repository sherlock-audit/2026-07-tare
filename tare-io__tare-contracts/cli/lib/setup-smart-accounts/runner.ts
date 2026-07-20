import { logProgress } from "../utils.js"
import { getThreshold } from "../onchain.js"
import type { CategorizedStepResult, SetupContext, StepCategory, StepDef, StepResult } from "./types.js"

/**
 * Run steps in order: check first (skip when already satisfied), execute only
 * when needed, stop on the first failure. With dryRun, unsatisfied steps are
 * reported as "dry-run" without executing.
 */
export function runSteps(defs: StepDef[], dryRun: boolean): CategorizedStepResult[] {
  const results: CategorizedStepResult[] = []
  for (const def of defs) {
    try {
      logProgress(`  ${def.name}`)
      if (def.check()) {
        results.push({ step: def.name, category: def.category, status: "skipped" })
        continue
      }
      if (dryRun) {
        results.push({ step: def.name, category: def.category, status: "dry-run" })
        continue
      }
      const txHashes = def.execute()
      results.push({ step: def.name, category: def.category, status: "completed", txHashes })
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e)
      const error = message.split("\n")[0]
      results.push({ step: def.name, category: def.category, status: "failed", error })
      return results
    }
  }
  return results
}

/**
 * Diagnose a failed SA step: if the SA is already past its ownership transition
 * (threshold > 1), the ops safe can no longer reach quorum and the only
 * recovery is a multisig session on the SA itself.
 */
export function lockedSaHint(smartAccount: string, ctx: SetupContext): string | undefined {
  try {
    const threshold = getThreshold(smartAccount, ctx.deployment)
    if (threshold > 1) {
      return `smart account ${smartAccount} has threshold ${threshold} — setup can no longer self-execute; this step requires a SA multisig session (signers reach quorum on the SA itself)`
    }
  } catch {
    // diagnostic only — ignore read failures
  }
  return undefined
}

export function groupSteps(results: CategorizedStepResult[]): Partial<Record<StepCategory, StepResult[]>> {
  const grouped: Partial<Record<StepCategory, StepResult[]>> = {}
  for (const { category, ...rest } of results) {
    if (!grouped[category]) grouped[category] = []
    grouped[category]!.push(rest)
  }
  return grouped
}
