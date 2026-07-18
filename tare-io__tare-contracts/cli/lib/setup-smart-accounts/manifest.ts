import { assertAddressField, loadAndValidateManifest } from "../manifest.js"
import { ROLES, type Role, type SetupManifest, type SmartAccounts } from "./types.js"

const REQUIRED_SAFE_FIELDS = ["operationalManagementSafe", "hotProxy", "guardianSafe"] as const

// Mapping from role to the corresponding manifest field name for that role's SA address. Used for validation and extraction.
const SA_FIELD_BY_ROLE: Record<Role, keyof SetupManifest> = {
  originator: "originatorSa",
  borrower: "borrowerSa",
  investor: "investorSa",
  servicer: "servicerSa",
  shareholder: "shareholderSa",
  portfolioManager: "portfolioManagerSa",
  investorManager: "investorManagerSa",
  calculatingAgent: "calculatingAgentSa",
}

/** Load and validate the setup manifest from disk. Throws with all validation errors at once. */
export function loadSetupManifest(path: string): SetupManifest {
  return loadAndValidateManifest<SetupManifest>(path, (parsed, errors) => {
    for (const fieldName of REQUIRED_SAFE_FIELDS) {
      assertAddressField(fieldName, parsed[fieldName], errors)
    }
    for (const role of ROLES) {
      const fieldName = SA_FIELD_BY_ROLE[role]
      assertAddressField(fieldName, parsed[fieldName], errors)
    }
    if (parsed.offramp !== undefined) {
      assertAddressField("offramp", parsed.offramp, errors)
    }

    if (errors.length === 0) {
      const manifest = parsed as unknown as SetupManifest

      // No two SA addresses may be equal
      const seen = new Map<string, string>()
      for (const role of ROLES) {
        const fieldName = SA_FIELD_BY_ROLE[role]
        const address = (manifest[fieldName] as string).toLowerCase()
        const existing = seen.get(address)
        if (existing) {
          errors.push(`duplicate smart account address: ${fieldName} == ${existing}`)
        } else {
          seen.set(address, fieldName)
        }
      }

      // Infrastructure Safes must be pairwise distinct (e.g. hotProxy == guardianSafe
      // would silently skip the second ownership step and leave SAs at threshold 1)
      const infraSafes = new Map<string, string>()
      for (const fieldName of REQUIRED_SAFE_FIELDS) {
        const address = (manifest[fieldName] as string).toLowerCase()
        const existing = infraSafes.get(address)
        if (existing) {
          errors.push(`infrastructure Safes must be distinct: ${fieldName} == ${existing}`)
        } else {
          infraSafes.set(address, fieldName)
        }
      }

      // No SA may equal one of the infrastructure Safes
      for (const role of ROLES) {
        const fieldName = SA_FIELD_BY_ROLE[role]
        const infraField = infraSafes.get((manifest[fieldName] as string).toLowerCase())
        if (infraField) {
          errors.push(`smart account ${fieldName} must not equal infrastructure Safe ${infraField}`)
        }
      }
    }
  })
}

/** Extract the role→address map of the eight smart accounts from a validated manifest. */
export function smartAccountsFromManifest(manifest: SetupManifest): SmartAccounts {
  return Object.fromEntries(
    ROLES.map((role) => [role, manifest[SA_FIELD_BY_ROLE[role]] as string])
  ) as SmartAccounts
}
