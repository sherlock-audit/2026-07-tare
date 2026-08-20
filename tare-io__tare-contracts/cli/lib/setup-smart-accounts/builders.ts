import { castCalldata } from "../cast.js"
import { checkAllowance } from "../allowance.js"
import { Roles, roleToUint } from "../roles.js"
import { saExec } from "./exec.js"
import {
  erc20Allowance,
  isApprovedForAll,
  isDelegate,
  isMaxAllowance,
  isMaxUint208Allowance,
  isModuleEnabled,
  isOperator,
  isOwner,
  isRegisteredForRole,
} from "../onchain.js"
import { MAX_UINT208, MAX_UINT256, NO_EXPIRY } from "../constants.js"
import type { Role, SetupContext, StepDef } from "./types.js"

/**
 * Common steps for every SA: Forwarder delegation on both modules, TrustedCalls
 * module activation, and the TrustedSpender USDC approval. In production these
 * should all report `skipped` because
 * `SmartAccountFactory.configureSmartAccount` performed them at SA creation;
 * they remain as idempotent fallbacks for SAs created before the current
 * factory version.
 */
export function buildCommonSteps(role: Role, ctx: SetupContext): StepDef[] {
  const { trustedCalls, trustedSpender, usdc, forwarder, deployment } = ctx
  const smartAccount = ctx.smartAccounts[role]
  return [
    {
      name: `TrustedCalls.addDelegate(${role}, forwarder)`,
      category: "relayDelegation",
      check: () => isDelegate(trustedCalls, smartAccount, forwarder, deployment),
      execute: () => {
        const data = castCalldata("addDelegate(address,address)", [smartAccount, forwarder])
        return saExec(smartAccount, trustedCalls, data, ctx)
      },
    },
    {
      name: `TrustedSpender.addDelegate(${role}, forwarder)`,
      category: "relayDelegation",
      check: () => isDelegate(trustedSpender, smartAccount, forwarder, deployment),
      execute: () => {
        const data = castCalldata("addDelegate(address,address)", [smartAccount, forwarder])
        return saExec(smartAccount, trustedSpender, data, ctx)
      },
    },
    {
      name: `${role}.enableModule(TrustedCalls)`,
      category: "moduleActivation",
      check: () => isModuleEnabled(smartAccount, trustedCalls, deployment),
      execute: () => {
        const data = castCalldata("enableModule(address)", [trustedCalls])
        return saExec(smartAccount, smartAccount, data, ctx)
      },
    },
    {
      name: `USDC.approve(TrustedSpender, MAX) from ${role}`,
      category: "approvals",
      check: () => isMaxAllowance(erc20Allowance(usdc, smartAccount, trustedSpender, deployment)),
      execute: () => {
        const data = castCalldata("approve(address,uint256)", [trustedSpender, MAX_UINT256])
        return saExec(smartAccount, usdc, data, ctx)
      },
    },
  ]
}

/** `USDC.approve(Loans, MAX)` — borrower, investor, and servicer SAs. */
export function buildLoansApprovalStep(role: Role, ctx: SetupContext): StepDef {
  const { loans, usdc, deployment } = ctx
  const smartAccount = ctx.smartAccounts[role]
  return {
    name: `USDC.approve(Loans, MAX) from ${role}`,
    category: "approvals",
    check: () => isMaxAllowance(erc20Allowance(usdc, smartAccount, loans, deployment)),
    execute: () => {
      const data = castCalldata("approve(address,uint256)", [loans, MAX_UINT256])
      return saExec(smartAccount, usdc, data, ctx)
    },
  }
}

/** Borrower-only optional offramp allowance on TrustedSpender (SA self-call, `safeOrGuardian(from)`). */
export function buildOfframpStep(ctx: SetupContext): StepDef | undefined {
  const { trustedSpender, usdc, offramp, deployment } = ctx
  if (!offramp) return undefined
  const borrowerSa = ctx.smartAccounts.borrower
  return {
    name: "TrustedSpender.setAllowance(borrower, offramp, MAX)",
    category: "disbursement",
    check: () => isMaxUint208Allowance(checkAllowance(trustedSpender, usdc, borrowerSa, offramp, deployment)),
    execute: () => {
      const data = castCalldata("setAllowance(address,address,address,uint208,uint48)", [
        usdc,
        borrowerSa,
        offramp,
        MAX_UINT208,
        NO_EXPIRY,
      ])
      return saExec(borrowerSa, trustedSpender, data, ctx)
    },
  }
}

/** Investor-only: allow LoansExchange to move the investor's loan NFTs (seller on createOffer). */
export function buildInvestorNftApprovalStep(ctx: SetupContext): StepDef {
  const { loansNft, loansExchange, deployment } = ctx
  const investorSa = ctx.smartAccounts.investor
  return {
    name: "LoansNFT.setApprovalForAll(LoansExchange, true) from investor",
    category: "approvals",
    check: () => isApprovedForAll(loansNft, investorSa, loansExchange, deployment),
    execute: () => {
      const data = castCalldata("setApprovalForAll(address,bool)", [loansExchange, "true"])
      return saExec(investorSa, loansNft, data, ctx)
    },
  }
}

/**
 * Investor-only: register the PortfolioVault as Investor in the investor SA's
 * own address book, satisfying the seller-side checks in
 * `LoansExchange.createOffer` and `acceptOffer` when selling loans to the
 * vault. The buyer-side entry (vault's book) is guardian-routed and lands in
 * the `grant-roles` Timelock batch.
 */
export function buildInvestorExchangeRegistrationStep(ctx: SetupContext): StepDef {
  const { loans, portfolioVault, deployment } = ctx
  const investorSa = ctx.smartAccounts.investor
  return {
    name: "Loans.registerAddress(Investor, portfolioVault) from investor",
    category: "addressBook",
    check: () => isRegisteredForRole(loans, investorSa, Roles.Investor, portfolioVault, deployment),
    execute: () => {
      const data = castCalldata("registerAddress(uint8,address)", [roleToUint(Roles.Investor), portfolioVault])
      return saExec(investorSa, loans, data, ctx)
    },
  }
}

/**
 * Shareholder-only vault wiring. All three are on the never-whitelist list for
 * TrustedCalls, so they must land here — no relay can retrofit them later.
 */
export function buildShareholderSteps(ctx: SetupContext): StepDef[] {
  const { usdc, vaultShareToken, portfolioVault, forwarder, deployment } = ctx
  const shareholderSa = ctx.smartAccounts.shareholder
  return [
    {
      name: "USDC.approve(PortfolioVault, MAX) from shareholder",
      category: "vaultWiring",
      check: () => isMaxAllowance(erc20Allowance(usdc, shareholderSa, portfolioVault, deployment)),
      execute: () => {
        const data = castCalldata("approve(address,uint256)", [portfolioVault, MAX_UINT256])
        return saExec(shareholderSa, usdc, data, ctx)
      },
    },
    {
      name: "VaultShareToken.approve(PortfolioVault, MAX) from shareholder",
      category: "vaultWiring",
      check: () => isMaxAllowance(erc20Allowance(vaultShareToken, shareholderSa, portfolioVault, deployment)),
      execute: () => {
        const data = castCalldata("approve(address,uint256)", [portfolioVault, MAX_UINT256])
        return saExec(shareholderSa, vaultShareToken, data, ctx)
      },
    },
    {
      name: "PortfolioVault.setOperator(forwarder, true) from shareholder",
      category: "vaultWiring",
      check: () => isOperator(portfolioVault, shareholderSa, forwarder, deployment),
      execute: () => {
        const data = castCalldata("setOperator(address,bool)", [forwarder, "true"])
        return saExec(shareholderSa, portfolioVault, data, ctx)
      },
    },
  ]
}

/**
 * Originator self-calls registering peer SAs in its own address book.
 * `registerAddress` is permissionless and writes to `addressBook[msg.sender]`.
 */
export function buildOriginatorRegistrationSteps(ctx: SetupContext): StepDef[] {
  const { loans, deployment } = ctx
  const originatorSa = ctx.smartAccounts.originator
  const registrations: [Roles, string][] = [
    [Roles.Borrower, ctx.smartAccounts.borrower],
    [Roles.Investor, ctx.smartAccounts.investor],
    [Roles.Servicer, ctx.smartAccounts.servicer],
  ]
  return registrations.map(([role, peerAddress]) => {
    const roleName = Roles[role]
    return {
      name: `Loans.registerAddress(${roleName}, ${roleName.toLowerCase()}Sa) from originator`,
      category: "addressBook" as const,
      check: () => isRegisteredForRole(loans, originatorSa, role, peerAddress, deployment),
      execute: () => {
        const data = castCalldata("registerAddress(uint8,address)", [roleToUint(role), peerAddress])
        return saExec(originatorSa, loans, data, ctx)
      },
    }
  })
}

/**
 * Final ownership transition: add the Forwarder (threshold stays 1 so the
 * second call can still execute under the ops safe's single approval), then add
 * the Guardian Safe and raise the threshold to its final value
 * (`ctx.finalThreshold`: 2 in production, 1 for local dev).
 *
 * The slot is what lets an authorized sender confirm a Safe transaction with a
 * `v = 1` pre-validated signature. At `finalThreshold > 1` it is one of the
 * required signatures, not sufficient on its own.
 */
export function buildOwnershipTransitionSteps(role: Role, ctx: SetupContext): StepDef[] {
  const { forwarder, guardianSafe, finalThreshold, deployment } = ctx
  const smartAccount = ctx.smartAccounts[role]
  return [
    {
      name: `${role}.addOwnerWithThreshold(forwarder, 1)`,
      category: "ownership",
      check: () => isOwner(smartAccount, forwarder, deployment),
      execute: () => {
        const data = castCalldata("addOwnerWithThreshold(address,uint256)", [forwarder, "1"])
        return saExec(smartAccount, smartAccount, data, ctx)
      },
    },
    {
      name: `${role}.addOwnerWithThreshold(guardianSafe, ${finalThreshold})`,
      category: "ownership",
      check: () => isOwner(smartAccount, guardianSafe, deployment),
      execute: () => {
        const data = castCalldata("addOwnerWithThreshold(address,uint256)", [guardianSafe, String(finalThreshold)])
        return saExec(smartAccount, smartAccount, data, ctx)
      },
    },
  ]
}
