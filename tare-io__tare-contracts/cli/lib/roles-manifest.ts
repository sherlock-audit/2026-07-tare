import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { getAddress, isAddress } from "viem"
import type { DeploymentConfig } from "./deployment-configs.js"

/**
 * The roles manifest (`deployments/<chain>/<name>/roles/latest.json`) is the
 * single deployment artifact carrying governance Safes, the eight role smart
 * accounts, the grant-roles salt, and the borrower offramp. It is the superset
 * consumed by `setup-smart-accounts` and `grant-roles` (each loader ignores
 * fields it does not recognise) and is auto-recorded into by the
 * address-producing commands (`deploy-safe --manifest-key`,
 * `create-smart-account --manifest-key`, `create-role-accounts`,
 * `manifest set`).
 */

export const ROLES_MANIFEST_ADDRESS_FIELDS = [
  "adminSafe",
  "proposerSafe",
  "guardianSafe",
  "whitelisterSafe",
  "operationalManagementSafe",
  "hotProxy",
  "offramp",
  "originatorSa",
  "borrowerSa",
  "investorSa",
  "servicerSa",
  "shareholderSa",
  "portfolioManagerSa",
  "investorManagerSa",
  "calculatingAgentSa",
] as const

export const ROLES_MANIFEST_STRING_FIELDS = ["salt"] as const

export type RolesManifestField =
  (typeof ROLES_MANIFEST_ADDRESS_FIELDS)[number] | (typeof ROLES_MANIFEST_STRING_FIELDS)[number]

export function isRolesManifestAddressField(field: string): boolean {
  return (ROLES_MANIFEST_ADDRESS_FIELDS as readonly string[]).includes(field)
}

export function assertRolesManifestField(field: string): asserts field is RolesManifestField {
  const known = [...ROLES_MANIFEST_ADDRESS_FIELDS, ...ROLES_MANIFEST_STRING_FIELDS] as readonly string[]
  if (!known.includes(field)) {
    throw new Error(`unknown roles-manifest field: ${field}. Options: ${known.join(", ")}`)
  }
}

/** Canonical derived location: `deployments/<chain>/<name>/roles/latest.json`. */
export function rolesManifestPath(root: string, config: DeploymentConfig, explicit?: string): string {
  if (explicit) return resolve(explicit)
  return resolve(root, `deployments/${config.chain}/${config.shortName}/roles/latest.json`)
}

/** Read the roles manifest if present; `null` when it does not exist yet. */
export function readRolesManifest(path: string): Record<string, string> | null {
  if (!existsSync(path)) return null
  return JSON.parse(readFileSync(path, "utf8")) as Record<string, string>
}

function normalize(field: string, value: string): string {
  if (!isRolesManifestAddressField(field)) return value
  if (!isAddress(value)) throw new Error(`${field} is not a valid address: ${value}`)
  return getAddress(value)
}

export interface WriteRolesManifestOptions {
  /** Explicit output path (replaces the derived `roles/latest.json`). */
  output?: string
  /** Allow overwriting an existing field with a different value (used by `manifest set`). */
  overwrite?: boolean
}

/**
 * Upsert fields into the roles manifest. Stamps the current package version and
 * writes both `latest.json` and the version-pinned `<version>.json` so the two
 * can never drift within a version — no writer ever copies files by hand.
 * A field that already exists with a different value is an error unless
 * `overwrite` is set, so an auto-recording command cannot silently clobber a
 * previously recorded address.
 */
export function writeRolesManifest(
  root: string,
  config: DeploymentConfig,
  updates: Record<string, string>,
  options: WriteRolesManifestOptions = {}
): { path: string; versionedPath: string; manifest: Record<string, string> } {
  const path = rolesManifestPath(root, config, options.output)
  const existing = readRolesManifest(path) ?? {}

  const manifest: Record<string, string> = { ...existing }
  for (const [field, rawValue] of Object.entries(updates)) {
    assertRolesManifestField(field)
    const value = normalize(field, rawValue)
    const current = existing[field]
    if (current !== undefined && current.toLowerCase() !== value.toLowerCase() && !options.overwrite) {
      throw new Error(
        `roles manifest ${path} already has ${field}=${current} (attempted ${value}); ` +
          `use 'manifest set' to overwrite deliberately`
      )
    }
    manifest[field] = value
  }

  const pkg = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8")) as { version: string }
  manifest.version = pkg.version

  const versionedPath = resolve(dirname(path), `${pkg.version}.json`)
  const json = JSON.stringify(manifest, null, 2) + "\n"
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, json)
  writeFileSync(versionedPath, json)
  return { path, versionedPath, manifest }
}

/**
 * Read a required address field from the roles manifest, with an actionable
 * error naming the command that records it.
 */
export function requireManifestField(
  manifest: Record<string, string> | null,
  field: RolesManifestField,
  manifestPath: string
): string {
  const value = manifest?.[field]
  if (!value) {
    throw new Error(
      `roles manifest ${manifestPath} is missing '${field}' — record it with ` +
        `'deploy-safe --manifest-key ${field}' or 'manifest set ${field} <value>'`
    )
  }
  return value
}
