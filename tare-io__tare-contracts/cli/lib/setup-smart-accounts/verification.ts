import { checkAllowance } from "../allowance.js"
import { Roles } from "../roles.js"
import {
  erc20Allowance,
  getOwners,
  getThreshold,
  isApprovedForAll,
  isDelegate,
  isMaxAllowance,
  isMaxUint208Allowance,
  isModuleEnabled,
  isOperator,
  isRegisteredForRole,
} from "../onchain.js"
import { ROLES, type Role, type SetupContext } from "./types.js"

const LOANS_APPROVAL_ROLES: Role[] = ["borrower", "investor", "servicer"]

export interface SaVerification {
  [key: string]: string | boolean | number | string[]
}

/**
 * Post-run verification block — the deployment gate for this command. Reads
 * every approval, delegate, operator, registration, and the final owner set /
 * threshold for each SA.
 */
export function verifySmartAccountsSetup(ctx: SetupContext): Record<Role, SaVerification> {
  const {
    loans,
    trustedCalls,
    trustedSpender,
    usdc,
    loansNft,
    loansExchange,
    portfolioVault,
    vaultShareToken,
    hotProxy,
    deployment,
  } = ctx
  const verification = {} as Record<Role, SaVerification>

  const expectedOwners = [ctx.operationalManagementSafe, hotProxy, ctx.guardianSafe].map((address) =>
    address.toLowerCase()
  )

  for (const role of ROLES) {
    const smartAccount = ctx.smartAccounts[role]
    const owners = getOwners(smartAccount, deployment)
    const actualOwners = new Set(owners.map((address) => address.toLowerCase()))
    // With --allow-extra-owners (local dev keeps the deployer as an owner), the
    // expected set only needs to be contained in the actual set.
    const ownerSetCorrect = ctx.allowExtraOwners
      ? expectedOwners.every((address) => actualOwners.has(address))
      : expectedOwners.length === actualOwners.size && expectedOwners.every((address) => actualOwners.has(address))

    const entry: SaVerification = {
      "TrustedCalls.isDelegate(SA, hotProxy)": isDelegate(trustedCalls, smartAccount, hotProxy, deployment),
      "TrustedSpender.isDelegate(SA, hotProxy)": isDelegate(trustedSpender, smartAccount, hotProxy, deployment),
      "SA.isModuleEnabled(TrustedCalls)": isModuleEnabled(smartAccount, trustedCalls, deployment),
      "USDC.allowance(SA, TrustedSpender)": erc20Allowance(usdc, smartAccount, trustedSpender, deployment),
      owners,
      "ownerSet == {opsMgmt, hotProxy, guardianSafe}": ownerSetCorrect,
      threshold: getThreshold(smartAccount, deployment),
    }

    if (LOANS_APPROVAL_ROLES.includes(role)) {
      entry["USDC.allowance(SA, Loans)"] = erc20Allowance(usdc, smartAccount, loans, deployment)
    }

    if (role === "borrower" && ctx.offramp) {
      entry["TrustedSpender.getAllowance(SA, offramp)"] = checkAllowance(
        trustedSpender,
        usdc,
        smartAccount,
        ctx.offramp,
        deployment
      )
    }

    if (role === "investor") {
      entry["LoansNFT.isApprovedForAll(SA, LoansExchange)"] = isApprovedForAll(
        loansNft,
        smartAccount,
        loansExchange,
        deployment
      )
      entry["Loans.isRegisteredForRole(SA, Investor, portfolioVault)"] = isRegisteredForRole(
        loans,
        smartAccount,
        Roles.Investor,
        portfolioVault,
        deployment
      )
    }

    if (role === "shareholder") {
      entry["USDC.allowance(SA, PortfolioVault)"] = erc20Allowance(usdc, smartAccount, portfolioVault, deployment)
      entry["VaultShareToken.allowance(SA, PortfolioVault)"] = erc20Allowance(
        vaultShareToken,
        smartAccount,
        portfolioVault,
        deployment
      )
      entry["PortfolioVault.isOperator(SA, hotProxy)"] = isOperator(portfolioVault, smartAccount, hotProxy, deployment)
    }

    if (role === "originator") {
      const registrations: [Roles, string][] = [
        [Roles.Borrower, ctx.smartAccounts.borrower],
        [Roles.Investor, ctx.smartAccounts.investor],
        [Roles.Servicer, ctx.smartAccounts.servicer],
      ]
      for (const [loanRole, peerAddress] of registrations) {
        const roleName = Roles[loanRole]
        entry[`Loans.isRegisteredForRole(SA, ${roleName}, ${roleName.toLowerCase()}Sa)`] = isRegisteredForRole(
          loans,
          smartAccount,
          loanRole,
          peerAddress,
          deployment
        )
      }
    }

    verification[role] = entry
  }

  return verification
}

/**
 * Derive hard failures from a verification block. Pure — evaluates the record
 * produced by {@link verifySmartAccountsSetup} against the postconditions:
 * every boolean entry true, the threshold at its final value, every ERC-20
 * allowance max uint256, and the TrustedSpender offramp allowance max uint208.
 * The `owners` array is informational — the owner set is asserted by its
 * boolean `ownerSet` entry.
 */
export function collectVerificationFailures(
  verification: Record<string, SaVerification>,
  finalThreshold: number
): string[] {
  const failures: string[] = []
  for (const [role, entry] of Object.entries(verification)) {
    for (const [name, value] of Object.entries(entry)) {
      if (typeof value === "boolean") {
        if (!value) failures.push(`[${role}] ${name}`)
      } else if (name === "threshold") {
        if (value !== finalThreshold) failures.push(`[${role}] threshold: expected ${finalThreshold}, got ${value}`)
      } else if (name.includes(".getAllowance(")) {
        if (!isMaxUint208Allowance(value as string))
          failures.push(`[${role}] ${name}: expected max uint208, got ${value}`)
      } else if (name.includes(".allowance(")) {
        if (!isMaxAllowance(value as string)) failures.push(`[${role}] ${name}: expected max allowance, got ${value}`)
      }
    }
  }
  return failures
}
