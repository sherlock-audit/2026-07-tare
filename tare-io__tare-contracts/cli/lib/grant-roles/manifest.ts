import { assertAddressField, loadAndValidateManifest } from "../manifest.js"
import type { GrantRolesManifest } from "./types.js"

/** Address fields that must be present, well-formed, and non-zero. */
const REQUIRED_ADDRESS_FIELDS = [
  "proposerSafe",
  "originatorSa",
  "portfolioManagerSa",
  "investorManagerSa",
  "calculatingAgentSa",
  "whitelisterSafe",
] as const

/** Load and validate the grant-roles manifest from disk. Throws with all errors at once. */
export function loadGrantRolesManifest(path: string): GrantRolesManifest {
  return loadAndValidateManifest<GrantRolesManifest>(path, (parsed, errors) => {
    for (const fieldName of REQUIRED_ADDRESS_FIELDS) {
      assertAddressField(fieldName, parsed[fieldName], errors)
    }

    if (typeof parsed.salt !== "string" || parsed.salt.length === 0) {
      errors.push("missing required field: salt")
    }
  })
}
