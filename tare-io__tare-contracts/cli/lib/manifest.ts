import { readFileSync } from "node:fs"
import { isAddress, zeroAddress } from "viem"

/**
 * Push an error unless `value` is a present, well-formed, non-zero address.
 * Shared by the `--input` manifest loaders so their validation stays identical.
 */
export function assertAddressField(fieldName: string, value: unknown, errors: string[]): void {
  if (typeof value !== "string" || value.length === 0) {
    errors.push(`missing required field: ${fieldName}`)
    return
  }
  if (!isAddress(value)) {
    errors.push(`${fieldName} is not a valid address: ${value}`)
    return
  }
  if (value.toLowerCase() === zeroAddress) {
    errors.push(`${fieldName} must not be the zero address`)
  }
}

/**
 * Read and validate a JSON `--input` manifest from disk. The caller's
 * `validate` collects field-level errors into the shared array; this helper
 * owns the file read, JSON parse, and single aggregated throw so every
 * manifest command reports problems the same way.
 */
export function loadAndValidateManifest<T>(
  path: string,
  validate: (parsed: Record<string, unknown>, errors: string[]) => void
): T {
  let parsed: Record<string, unknown>
  try {
    parsed = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>
  } catch (e) {
    const reason = e instanceof SyntaxError ? "manifest is not valid JSON" : "cannot read manifest file"
    throw new Error(`${reason}: ${path}`)
  }

  const errors: string[] = []
  validate(parsed, errors)

  if (errors.length > 0) {
    throw new Error(`invalid manifest ${path}:\n  - ${errors.join("\n  - ")}`)
  }

  return parsed as unknown as T
}
