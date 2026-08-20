import { checksum } from "./utils.js"

/**
 * The Forwarder every role SA authorizes: `--forwarder`, else the setup
 * manifest (recorded by `deploy forwarder`), else a deployment component.
 *
 * Only local dev deploys it as part of the accounts component; elsewhere it is
 * its own component, mirroring the LMS's `<PREFIX>FORWARDER_ADDRESS`.
 */
export function resolveForwarder(sources: { option?: string; manifest?: string; deployment: string | null }): string {
  const { option, manifest, deployment } = sources
  if (option !== undefined) return checksum("--forwarder")(option.trim())
  if (manifest !== undefined) return checksum("manifest forwarder")(manifest.trim())
  if (deployment) return deployment
  throw new Error(
    "no Forwarder address: run `deploy forwarder` (records it in the roles manifest), pass --forwarder, or set `forwarder` in the setup manifest"
  )
}

const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase()

/**
 * Checksums the requested sender set and rejects what the contract would revert
 * on anyway — an empty set (`setAuthorizedSenders` requires at least one) and
 * duplicates — before a transaction is signed.
 */
export function resolveAuthorizedSenders(senders: string[]): string[] {
  const resolved = senders.map((sender) => checksum("--sender")(sender.trim()))
  const duplicate = resolved.find((sender, index) => resolved.indexOf(sender) !== index)
  if (duplicate) throw new Error(`duplicate --sender ${duplicate}: the sender set must be unique`)
  if (resolved.length === 0) throw new Error("at least one --sender is required")
  return resolved
}

/**
 * `setAuthorizedSenders` is owner-only, so the deploy can only seed senders
 * while the deployer still holds the owner slot.
 */
export function assertSendersSettableAtDeploy(sources: {
  initialOwner: string
  deployer: string
  senders: string[]
}): void {
  const { initialOwner, deployer, senders } = sources
  if (senders.length === 0 || sameAddress(initialOwner, deployer)) return
  throw new Error(
    `--sender cannot be combined with --owner ${initialOwner}: setAuthorizedSenders is owner-only, so the owner has to set them — deploy without --sender, then run \`forwarder set-senders\``
  )
}

export type SenderUpdateRoute = { via: "signer" } | { via: "safe"; safe: string }

/**
 * How to reach `setAuthorizedSenders` from the key at hand: directly when the
 * signer is the owner, or through the owning Safe while it is still threshold-1.
 * A multi-sig owner is not an error the CLI can fix — it goes to the Safe UI.
 */
export function planSenderUpdate(state: {
  forwarder: string
  owner: string
  signer: string
  ownerIsSafe: boolean
  signerOwnsSafe: boolean
  safeThreshold: number
}): SenderUpdateRoute {
  const { forwarder, owner, signer, ownerIsSafe, signerOwnsSafe, safeThreshold } = state
  if (sameAddress(owner, signer)) return { via: "signer" }
  if (!ownerIsSafe) {
    throw new Error(`Forwarder ${forwarder} is owned by ${owner}, which is neither the signer ${signer} nor a Safe`)
  }
  if (!signerOwnsSafe) {
    throw new Error(`signer ${signer} is not an owner of the owning Safe ${owner}`)
  }
  if (safeThreshold !== 1) {
    throw new Error(
      `owning Safe ${owner} has threshold ${safeThreshold} — submit setAuthorizedSenders through the Safe UI instead`
    )
  }
  return { via: "safe", safe: owner }
}
