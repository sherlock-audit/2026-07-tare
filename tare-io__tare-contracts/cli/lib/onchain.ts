import { castCall, type ResolvedDeployment } from "./cast.js"
import { Roles, roleToUint } from "./roles.js"
import { MAX_UINT208, MAX_UINT256 } from "./constants.js"

/** Generic boolean view read via `cast`: true when the call yields `"true"`. */
export function castCallBool(contract: string, signature: string, args: string[], deployment: ResolvedDeployment): boolean {
  return castCall(contract, signature, args, deployment) === "true"
}

/** `AccessControl.hasRole(role, account)`. */
export function hasRole(contract: string, role: string, account: string, deployment: ResolvedDeployment): boolean {
  return castCallBool(contract, "hasRole(bytes32,address)(bool)", [role, account], deployment)
}

/** `Loans.isRegisteredForRole(owner, role, account)` against the Loans address book. */
export function isRegisteredForRole(loans: string, owner: string, role: Roles, account: string, deployment: ResolvedDeployment): boolean {
  return castCallBool(loans, "isRegisteredForRole(address,uint8,address)(bool)", [owner, roleToUint(role), account], deployment)
}

/** `Safe.isOwner(address)`. */
export function isOwner(safe: string, address: string, deployment: ResolvedDeployment): boolean {
  return castCallBool(safe, "isOwner(address)(bool)", [address], deployment)
}

/** `Safe.getThreshold()` as a number. */
export function getThreshold(safe: string, deployment: ResolvedDeployment): number {
  return Number(castCall(safe, "getThreshold()(uint256)", [], deployment))
}

/** `Safe.getOwners()` parsed from cast's `[a, b]` array rendering. */
export function getOwners(safe: string, deployment: ResolvedDeployment): string[] {
  const raw = castCall(safe, "getOwners()(address[])", [], deployment)
  return raw
    .replace(/^\[/, "")
    .replace(/\]$/, "")
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
}

/** True if `address` responds to `getOwners()` — i.e. looks like a Gnosis Safe. */
export function isSafe(address: string, deployment: ResolvedDeployment): boolean {
  try {
    getOwners(address, deployment)
    return true
  } catch {
    return false
  }
}

/** `ERC20.allowance(owner, spender)` (raw cast-formatted uint string). */
export function erc20Allowance(token: string, owner: string, spender: string, deployment: ResolvedDeployment): string {
  return castCall(token, "allowance(address,address)(uint256)", [owner, spender], deployment)
}

/** `TrustedCalls/TrustedSpender.isDelegate(safe, delegate)`. */
export function isDelegate(module: string, safe: string, delegate: string, deployment: ResolvedDeployment): boolean {
  return castCallBool(module, "isDelegate(address,address)(bool)", [safe, delegate], deployment)
}

/** `Safe.isModuleEnabled(module)`. */
export function isModuleEnabled(safe: string, module: string, deployment: ResolvedDeployment): boolean {
  return castCallBool(safe, "isModuleEnabled(address)(bool)", [module], deployment)
}

/** `ERC721.isApprovedForAll(owner, operator)`. */
export function isApprovedForAll(nft: string, owner: string, operator: string, deployment: ResolvedDeployment): boolean {
  return castCallBool(nft, "isApprovedForAll(address,address)(bool)", [owner, operator], deployment)
}

/** ERC-7540 `isOperator(controller, operator)`. */
export function isOperator(vault: string, controller: string, operator: string, deployment: ResolvedDeployment): boolean {
  return castCallBool(vault, "isOperator(address,address)(bool)", [controller, operator], deployment)
}

/** True when the leading decimal of a cast-formatted uint output is exactly 0. */
export function isZero(value: string): boolean {
  return /^0(\s|$)/.test(value.trim())
}

/** cast formats large uints as "1157...935 [1.157e77]" — match on the leading decimal value. */
export function isMaxAllowance(value: string): boolean {
  return value.startsWith(MAX_UINT256)
}

/** TrustedSpender allowances are uint208 — `getAllowance` returns at most maxUint208. */
export function isMaxUint208Allowance(value: string): boolean {
  return value.startsWith(MAX_UINT208)
}
