import { maxUint208, maxUint256, maxUint48 } from "viem"

export const DEFAULT_ANVIL_RPC = "http://127.0.0.1:8545"

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

export const MAX_UINT256 = maxUint256.toString()

/** Decimal string of `2**208 - 1` — the max TrustedSpender allowance. */
export const MAX_UINT208 = maxUint208.toString()

/** Decimal string of `2**48 - 1` — the "no expiry" sentinel for allowances. */
export const NO_EXPIRY = maxUint48.toString()

export function displayAmount(value: string, max: string): string {
  return value === max ? "max" : value
}

export function displayExpiry(value: string): string {
  return value === NO_EXPIRY ? "no-expiry" : value
}
