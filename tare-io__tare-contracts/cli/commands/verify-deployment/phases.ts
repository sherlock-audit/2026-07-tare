import { type Address } from "viem"
import { Checker } from "./checker.js"
import { ADMIN_ROLE, GUARDIAN_ROLE, DEFAULT_ADMIN_ROLE, DEAD_ADDRESS, SELECTOR_GROUPS } from "./constants.js"
import type { Addresses, Addr, DeploymentManifest, TimelockExpectations } from "./types.js"

export function verifyManifests(
  checker: Checker,
  loans: DeploymentManifest | null,
  accounts: DeploymentManifest | null,
  vault: DeploymentManifest | null,
  timelock: DeploymentManifest | null
) {
  const section = "manifests"
  loans ? checker.pass(section, "loans manifest exists") : checker.fail(section, "loans manifest exists", "not found")
  accounts
    ? checker.pass(section, "accounts manifest exists")
    : checker.fail(section, "accounts manifest exists", "not found")
  vault
    ? checker.pass(section, "vault manifest exists")
    : checker.skip(section, "vault manifest exists", "No vault deployment (optional)")
  timelock
    ? checker.pass(section, "timelock manifest exists")
    : checker.skip(section, "timelock manifest exists", "No timelock deployment (optional)")
}

export async function verifyDeployment(checker: Checker, addresses: Addresses): Promise<Record<string, boolean>> {
  const section = "1. deployment"
  const deployed: Record<string, boolean> = {}
  const contracts: [string, Addr][] = [
    ["Loans", addresses.loans],
    ["LoansNFT", addresses.loansNFT],
    ["LoansExchange", addresses.exchange],
    ["USDC", addresses.usdc],
    ["TrustedCalls", addresses.trustedCalls],
    ["TrustedSpender", addresses.trustedSpender],
    ["SmartAccountFactory", addresses.saf],
    ["SafeSingleton", addresses.safeSingleton],
    ["SafeProxyFactory", addresses.safeProxyFactory],
    ["NavCalculator", addresses.navCalculator],
    ["VaultShareToken", addresses.vaultShareToken],
    ["PortfolioVault", addresses.portfolioVault],
  ]
  for (const [name, address] of contracts) {
    if (!address) {
      checker.skip(section, `${name} deployed`, "Not in manifest")
      deployed[name] = false
    } else deployed[name] = await checker.checkDeployed(section, name, address as Address)
  }
  return deployed
}

export async function verifyWiring(checker: Checker, addresses: Addresses, deployed: Record<string, boolean>) {
  const section = "2. wiring"

  const checks: [string, Addr, string, Addr][] = [
    ["Loans.loansNFT → LoansNFT", addresses.loans, "loansNFT", addresses.loansNFT],
    ["LoansNFT.LOANS_CONTRACT → Loans", addresses.loansNFT, "LOANS_CONTRACT", addresses.loans],
    ["Loans.currency → USDC", addresses.loans, "currency", addresses.usdc],
    ["LoansExchange.LOANS → Loans", addresses.exchange, "LOANS", addresses.loans],
    ["LoansExchange.LOANS_NFT → LoansNFT", addresses.exchange, "LOANS_NFT", addresses.loansNFT],
    ["SAF.SAFE_SINGLETON → SafeSingleton", addresses.saf, "SAFE_SINGLETON", addresses.safeSingleton],
    ["SAF.SAFE_PROXY_FACTORY → SafeProxyFactory", addresses.saf, "SAFE_PROXY_FACTORY", addresses.safeProxyFactory],
    ["SAF.TRUSTED_CALLS_MODULE → TrustedCalls", addresses.saf, "TRUSTED_CALLS_MODULE", addresses.trustedCalls],
    ["SAF.TRUSTED_SPENDER → TrustedSpender", addresses.saf, "TRUSTED_SPENDER", addresses.trustedSpender],
    ["PortfolioVault.loans → Loans", addresses.portfolioVault, "loans", addresses.loans],
    ["PortfolioVault.loansNFT → LoansNFT", addresses.portfolioVault, "loansNFT", addresses.loansNFT],
    ["PortfolioVault.exchange → LoansExchange", addresses.portfolioVault, "exchange", addresses.exchange],
    ["PortfolioVault.shareToken → VaultShareToken", addresses.portfolioVault, "shareToken", addresses.vaultShareToken],
    ["PortfolioVault.calculator → NavCalculator", addresses.portfolioVault, "calculator", addresses.navCalculator],
    ["PortfolioVault.assetToken → USDC", addresses.portfolioVault, "assetToken", addresses.usdc],
  ]

  for (const [label, source, getter, expected] of checks) {
    if (source && expected) await checker.checkWiring(section, label, source as Address, getter, expected as Address)
  }

  if (deployed.VaultShareToken && deployed.PortfolioVault && addresses.usdc) {
    await checker.checkWiring(
      section,
      "VaultShareToken.vault(USDC) → PortfolioVault",
      addresses.vaultShareToken as Address,
      "vault",
      addresses.portfolioVault as Address,
      [addresses.usdc as Address]
    )
  }
}

export async function verifyConfiguration(
  checker: Checker,
  addresses: Addresses,
  deployed: Record<string, boolean>,
  admin: Address,
  guardian: Address,
  recoveryAddress: Address,
  deployer: Address,
  whitelister?: Address
) {
  const section = "3. configuration"

  // Informational: report the vault's current NAV so the §7.7 NAV bootstrap can
  // be confirmed here rather than via a separate `cast call lastNav()`. Never gates.
  if (deployed.PortfolioVault && addresses.portfolioVault) {
    try {
      const lastNav = await checker.readUint(addresses.portfolioVault as Address, "lastNav")
      checker.info(section, "PortfolioVault.lastNav()", `${lastNav}`)
    } catch (err) {
      checker.info(section, "PortfolioVault.lastNav()", `read failed: ${String(err)}`)
    }
  }

  const controlled: [string, Addr][] = [
    ["Loans", addresses.loans],
    ["LoansExchange", addresses.exchange],
    ["TrustedCalls", addresses.trustedCalls],
    ["TrustedSpender", addresses.trustedSpender],
    ["PortfolioVault", addresses.portfolioVault],
    ["NavCalculator", addresses.navCalculator],
    ["VaultShareToken", addresses.vaultShareToken],
  ]
  const rescuable = new Set(["Loans", "LoansExchange", "TrustedCalls", "TrustedSpender", "PortfolioVault"])
  for (const [name, address] of controlled) {
    if (!deployed[name] || !address) continue
    await checker.checkHasRole(section, name, address as Address, "ADMIN_ROLE", ADMIN_ROLE, admin, "admin")
    await checker.checkHasRole(section, name, address as Address, "GUARDIAN_ROLE", GUARDIAN_ROLE, guardian, "guardian")
    // GuardianAccessControl invariant: GUARDIAN_ROLE admins DEFAULT_ADMIN_ROLE, ADMIN_ROLE and itself.
    await checker.checkRoleAdmin(
      section,
      name,
      address as Address,
      "DEFAULT_ADMIN_ROLE",
      DEFAULT_ADMIN_ROLE,
      GUARDIAN_ROLE
    )
    await checker.checkRoleAdmin(section, name, address as Address, "ADMIN_ROLE", ADMIN_ROLE, GUARDIAN_ROLE)
    await checker.checkRoleAdmin(section, name, address as Address, "GUARDIAN_ROLE", GUARDIAN_ROLE, GUARDIAN_ROLE)
    if (rescuable.has(name)) {
      await checker.checkAddressGetter(section, name, address as Address, "recoveryAddress", recoveryAddress)
    }

    if (deployer !== guardian) {
      await checker.checkDoesNotHaveRole(
        section,
        name,
        address as Address,
        "GUARDIAN_ROLE",
        GUARDIAN_ROLE,
        deployer,
        "deployer"
      )

      await checker.checkDoesNotHaveRole(
        section,
        name,
        address as Address,
        "DEFAULT_ADMIN_ROLE",
        DEFAULT_ADMIN_ROLE,
        deployer,
        "deployer"
      )
    }

    if (deployer !== admin) {
      await checker.checkDoesNotHaveRole(
        section,
        name,
        address as Address,
        "ADMIN_ROLE",
        ADMIN_ROLE,
        deployer,
        "deployer"
      )
    }
  }

  if (deployed.VaultShareToken && deployed.PortfolioVault) {
    const shareTokenAddr = addresses.vaultShareToken as Address
    const vaultAddr = addresses.portfolioVault as Address
    const [minterRole, burnerRole, shareholderRole, whitelisterRole] = await Promise.all([
      checker.readBytes32(shareTokenAddr, "MINTER_ROLE"),
      checker.readBytes32(shareTokenAddr, "BURNER_ROLE"),
      checker.readBytes32(shareTokenAddr, "SHAREHOLDER_ROLE"),
      checker.readBytes32(shareTokenAddr, "WHITELISTER_ROLE"),
    ])
    await checker.checkHasRole(
      section,
      "VaultShareToken",
      shareTokenAddr,
      "MINTER_ROLE",
      minterRole,
      vaultAddr,
      "PortfolioVault"
    )
    await checker.checkHasRole(
      section,
      "VaultShareToken",
      shareTokenAddr,
      "BURNER_ROLE",
      burnerRole,
      vaultAddr,
      "PortfolioVault"
    )
    await checker.checkHasRole(
      section,
      "VaultShareToken",
      shareTokenAddr,
      "SHAREHOLDER_ROLE",
      shareholderRole,
      vaultAddr,
      "PortfolioVault"
    )
    await checker.checkDoesNotHaveRole(
      section,
      "VaultShareToken",
      shareTokenAddr,
      "SHAREHOLDER_ROLE",
      shareholderRole,
      DEAD_ADDRESS,
      "0xdead"
    )
    if (whitelister !== undefined) {
      await checker.checkHasRole(
        section,
        "VaultShareToken",
        shareTokenAddr,
        "WHITELISTER_ROLE",
        whitelisterRole,
        whitelister,
        "whitelister"
      )
    }
    if (deployer !== whitelister) {
      await checker.checkDoesNotHaveRole(
        section,
        "VaultShareToken",
        shareTokenAddr,
        "WHITELISTER_ROLE",
        whitelisterRole,
        deployer,
        "deployer"
      )
    }
    await checker.checkDoesNotHaveRole(
      section,
      "VaultShareToken",
      shareTokenAddr,
      "MINTER_ROLE",
      minterRole,
      deployer,
      "deployer"
    )
    await checker.checkDoesNotHaveRole(
      section,
      "VaultShareToken",
      shareTokenAddr,
      "BURNER_ROLE",
      burnerRole,
      deployer,
      "deployer"
    )
  } else if (deployed.VaultShareToken) {
    const shareTokenAddr = addresses.vaultShareToken as Address
    const shareholderRole = await checker.readBytes32(shareTokenAddr, "SHAREHOLDER_ROLE")
    await checker.checkHasRole(
      section,
      "VaultShareToken",
      shareTokenAddr,
      "SHAREHOLDER_ROLE",
      shareholderRole,
      DEAD_ADDRESS,
      "0xdead"
    )
  }

  if (!deployed.TrustedCalls) return
  const trustedCallsAddr = addresses.trustedCalls as Address
  const targetMap: Record<string, { addr: Addr; okKey: string }> = {
    loans: { addr: addresses.loans, okKey: "Loans" },
    exchange: { addr: addresses.exchange, okKey: "LoansExchange" },
    vault: { addr: addresses.portfolioVault, okKey: "PortfolioVault" },
  }
  for (const group of SELECTOR_GROUPS) {
    const target = targetMap[group.contract]
    if (!target || !target.addr || !deployed[target.okKey]) continue
    for (const entry of group.entries) {
      await checker.checkTrustedCall(
        section,
        trustedCallsAddr,
        target.addr as Address,
        group.label,
        entry.name,
        entry.sig
      )
    }
  }
}

export interface TimelockVerifyContext {
  timelock: Addr
  timelockManifest: DeploymentManifest | null
  expectations: TimelockExpectations
}

export async function verifyTimelock(checker: Checker, ctx: TimelockVerifyContext): Promise<void> {
  const section = "4. timelock"
  const { expectations } = ctx

  if (!ctx.timelock) {
    if (expectations.minDelay !== undefined) {
      checker.fail(
        section,
        `TimelockController: minDelay is ${expectations.minDelay}`,
        "timelock manifest/address is required"
      )
    }
    return
  }

  const timelockAddr = ctx.timelock as Address
  if (!(await checker.checkDeployed(section, "TimelockController", timelockAddr))) return

  if (expectations.minDelay !== undefined) {
    try {
      const actual = await checker.readUint(timelockAddr, "getMinDelay")
      const matches = actual === expectations.minDelay
      checker.results.push({
        section,
        name: `TimelockController: minDelay is ${expectations.minDelay}`,
        status: matches ? "pass" : "fail",
        detail: matches ? undefined : `min delay mismatch: expected ${expectations.minDelay}, got ${actual}`,
      })
    } catch (err) {
      checker.fail(section, `TimelockController: minDelay is ${expectations.minDelay}`, String(err))
    }
  }

  // Self-administration: the deployer renounced its transient setup-admin role at the end
  // of deployTimelock, leaving the timelock itself as the only DEFAULT_ADMIN_ROLE holder.
  // This invariant is enforced post-deploy by DeployTimelock.s.sol assertions.
  await checker.checkHasRole(
    section,
    "TimelockController",
    timelockAddr,
    "DEFAULT_ADMIN_ROLE",
    DEFAULT_ADMIN_ROLE,
    timelockAddr,
    "timelock itself"
  )
}
