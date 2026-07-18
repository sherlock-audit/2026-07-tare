import { test } from "node:test"
import assert from "node:assert/strict"
import { collectVerificationFailures } from "../lib/setup-smart-accounts/verification.js"
import type { SaVerification } from "../lib/setup-smart-accounts/verification.js"
import { MAX_UINT208, MAX_UINT256 } from "../lib/constants.js"

const OPS_MGMT = "0x1000000000000000000000000000000000000001"
const HOT_PROXY = "0x1000000000000000000000000000000000000002"
const GUARDIAN = "0x1000000000000000000000000000000000000003"

function configuredEntry(overrides: SaVerification = {}): SaVerification {
  return {
    "TrustedCalls.isDelegate(SA, hotProxy)": true,
    "TrustedSpender.isDelegate(SA, hotProxy)": true,
    "SA.isModuleEnabled(TrustedCalls)": true,
    "USDC.allowance(SA, TrustedSpender)": MAX_UINT256,
    owners: [OPS_MGMT, HOT_PROXY, GUARDIAN],
    "ownerSet == {opsMgmt, hotProxy, guardianSafe}": true,
    threshold: 2,
    ...overrides,
  }
}

test("fully configured SA yields no failures", () => {
  assert.deepEqual(collectVerificationFailures({ borrower: configuredEntry() }, 2), [])
})

test("bootstrap-owned SA fails on owner set and threshold", () => {
  const bootstrap = configuredEntry({
    owners: [OPS_MGMT],
    "ownerSet == {opsMgmt, hotProxy, guardianSafe}": false,
    threshold: 1,
  })
  const failures = collectVerificationFailures({ borrower: bootstrap }, 2)
  assert.deepEqual(failures, [
    "[borrower] ownerSet == {opsMgmt, hotProxy, guardianSafe}",
    "[borrower] threshold: expected 2, got 1",
  ])
})

test("missing delegate, disabled module, and operator flag fail", () => {
  const broken = configuredEntry({
    "TrustedCalls.isDelegate(SA, hotProxy)": false,
    "SA.isModuleEnabled(TrustedCalls)": false,
    "PortfolioVault.isOperator(SA, hotProxy)": false,
  })
  const failures = collectVerificationFailures({ shareholder: broken }, 2)
  assert.equal(failures.length, 3)
  assert.ok(failures.every((failure) => failure.startsWith("[shareholder]")))
})

test("non-max ERC-20 allowance fails; max passes", () => {
  const entry = configuredEntry({
    "USDC.allowance(SA, Loans)": "0",
    "VaultShareToken.allowance(SA, PortfolioVault)": MAX_UINT256,
  })
  const failures = collectVerificationFailures({ investor: entry }, 2)
  assert.deepEqual(failures, ["[investor] USDC.allowance(SA, Loans): expected max allowance, got 0"])
})

test("offramp TrustedSpender allowance is asserted against max uint208", () => {
  const entryWithMax = configuredEntry({ "TrustedSpender.getAllowance(SA, offramp)": MAX_UINT208 })
  assert.deepEqual(collectVerificationFailures({ borrower: entryWithMax }, 2), [])

  const entryWithPartial = configuredEntry({ "TrustedSpender.getAllowance(SA, offramp)": "5" })
  assert.deepEqual(collectVerificationFailures({ borrower: entryWithPartial }, 2), [
    "[borrower] TrustedSpender.getAllowance(SA, offramp): expected max uint208, got 5",
  ])
})

test("local-dev threshold 1 passes when expected threshold is 1", () => {
  assert.deepEqual(collectVerificationFailures({ borrower: configuredEntry({ threshold: 1 }) }, 1), [])
})

test("failures across multiple roles are all reported", () => {
  const failures = collectVerificationFailures(
    {
      originator: configuredEntry({ threshold: 1 }),
      servicer: configuredEntry({ "Loans.isRegisteredForRole(SA, Investor, portfolioVault)": false }),
    },
    2
  )
  assert.deepEqual(failures, [
    "[originator] threshold: expected 2, got 1",
    "[servicer] Loans.isRegisteredForRole(SA, Investor, portfolioVault)",
  ])
})
