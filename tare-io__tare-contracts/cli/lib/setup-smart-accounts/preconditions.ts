import { erc20Allowance, getThreshold, isApprovedForAll, isOperator, isOwner, isZero } from "../onchain.js"
import { ROLES, type SetupContext } from "./types.js"

/**
 * Strict bootstrap-state assertions, run before any step unless
 * --skip-preconditions is set. Collects every violation and throws once.
 *
 * Note: after a successful run the SAs are in their final state (3 owners,
 * threshold 2, max allowances), so a plain re-run fails here by design —
 * re-runs must pass --skip-preconditions (the steps themselves are idempotent).
 */
export function assertPreconditions(ctx: SetupContext): void {
  const { deployment } = ctx
  const errors: string[] = []

  for (const role of ROLES) {
    const smartAccount = ctx.smartAccounts[role]

    if (!isOwner(smartAccount, ctx.operationalManagementSafe, deployment)) {
      errors.push(`${role}: operationalManagementSafe is not an owner`)
    }
    if (isOwner(smartAccount, ctx.hotProxy, deployment)) {
      errors.push(`${role}: hotProxy is already an owner`)
    }
    if (isOwner(smartAccount, ctx.guardianSafe, deployment)) {
      errors.push(`${role}: guardianSafe is already an owner`)
    }
    const threshold = getThreshold(smartAccount, deployment)
    if (threshold !== 1) {
      errors.push(`${role}: threshold is ${threshold}, expected 1`)
    }
  }

  const shareholderSa = ctx.smartAccounts.shareholder
  if (!isZero(erc20Allowance(ctx.usdc, shareholderSa, ctx.portfolioVault, deployment))) {
    errors.push("shareholder: USDC allowance to PortfolioVault is not 0")
  }
  if (!isZero(erc20Allowance(ctx.vaultShareToken, shareholderSa, ctx.portfolioVault, deployment))) {
    errors.push("shareholder: VaultShareToken allowance to PortfolioVault is not 0")
  }
  if (isOperator(ctx.portfolioVault, shareholderSa, ctx.hotProxy, deployment)) {
    errors.push("shareholder: hotProxy is already a PortfolioVault operator")
  }

  if (isApprovedForAll(ctx.loansNft, ctx.smartAccounts.investor, ctx.loansExchange, deployment)) {
    errors.push("investor: LoansNFT approval for LoansExchange is already set")
  }

  if (errors.length > 0) {
    throw new Error(
      `precondition check failed (use --skip-preconditions to resume a partial or completed run):\n  - ${errors.join("\n  - ")}`
    )
  }
}
