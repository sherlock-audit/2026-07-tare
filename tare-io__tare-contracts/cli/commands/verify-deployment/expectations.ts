import { type Address } from "viem"
import { resolveAuthorizedSenders } from "../../lib/forwarder.js"

export function resolveExpectedForwarderSenders(
  option: string[] | undefined,
  environmentAddress: string | undefined,
  foundryDefault: string | undefined
): Address[] {
  const senders = option?.length
    ? option
    : environmentAddress
      ? [environmentAddress]
      : foundryDefault
        ? [foundryDefault]
        : []
  if (senders.length === 0) {
    throw new Error("Forwarder sender is required (--forwarder-sender or $RELAYER_EOA)")
  }
  return resolveAuthorizedSenders(senders) as Address[]
}
