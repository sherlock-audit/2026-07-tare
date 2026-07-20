import { existsSync, readFileSync } from "fs"
import { resolve } from "path"
import { getAddress } from "viem"
import { DeploymentManifest, DeploymentComponent } from "./shared/types"

export function sleep(ms: number): Promise<void> {
  return new Promise((resolvePromise) => {
    setTimeout(resolvePromise, ms)
  })
}

/**
 * Load a deployment-artifact manifest (`deployments/<chain>/<shortName>/<component>/latest.json`).
 * Throws when the file is missing unless `optional` is set, in which case a
 * missing artifact returns `null` (used by `verify-deployment` for components
 * that may not be deployed yet).
 */
export function loadDeploymentManifest(
  root: string,
  chain: string,
  shortName: string,
  component: DeploymentComponent
): DeploymentManifest
export function loadDeploymentManifest(
  root: string,
  chain: string,
  shortName: string,
  component: DeploymentComponent,
  optional: true
): DeploymentManifest | null
export function loadDeploymentManifest(
  root: string,
  chain: string,
  shortName: string,
  component: DeploymentComponent,
  optional = false
): DeploymentManifest | null {
  const path = resolve(root, `deployments/${chain}/${shortName}/${component}/latest.json`)
  if (optional && !existsSync(path)) return null
  return JSON.parse(readFileSync(path, "utf8")) as DeploymentManifest
}

export function arrayArg(items: string[]): string {
  return `[${items.join(",")}]`
}

/** Build a `cast` array argument from a comma-separated CLI option (undefined → `[]`). */
export function parseAddressList(value: string | undefined): string {
  return arrayArg(value ? value.split(",") : [])
}

/** Progress logging to stderr (stdout is reserved for structured JSON output). */
export function logProgress(message: string): void {
  process.stderr.write(message + "\n")
}

/** Checksum an address option, failing with the offending flag name (getAddress rejects 0x0 shorthand). */
export function checksum(label: string) {
  return (value: string): string => {
    try {
      return getAddress(value)
    } catch {
      throw new Error(`Invalid ${label} address: ${value}`)
    }
  }
}
