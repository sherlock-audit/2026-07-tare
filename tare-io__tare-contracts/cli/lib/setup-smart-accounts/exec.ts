import { nestedSafeExec } from "../cast.js"
import type { SetupContext } from "./types.js"

/**
 * Execute a call as a smart-account self-call, signed by the threshold-1
 * Operational Management Safe (the SA's sole owner during bootstrap):
 * opsMgmtSafe → SA → target.
 */
export function saExec(smartAccount: string, target: string, callData: string, ctx: SetupContext): string[] {
  return nestedSafeExec(ctx.operationalManagementSafe, smartAccount, target, callData, ctx.deployment, ctx.execOpts)
    .txHashes
}
