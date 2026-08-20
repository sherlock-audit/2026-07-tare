import type { Command } from "commander"
import { resolveDeployment, isContract } from "../lib/cast.js"
import { outputResult } from "../lib/output.js"
import {
  isRolesManifestAddressField,
  readRolesManifest,
  rolesManifestPath,
  writeRolesManifest,
} from "../lib/roles-manifest.js"

export function registerManifest(program: Command): void {
  const cmd = program.command("manifest").description("Inspect and edit the deployment's roles manifest")

  cmd
    .command("set")
    .description(
      "Record a roles-manifest field by hand (e.g. a Safe created in the Safe UI). Overwrites an existing value."
    )
    .argument("<field>", "Manifest field, e.g. adminSafe, proposerSafe, salt")
    .argument("<value>", "Field value; addresses are checksummed and must have code on chain unless --eoa")
    .option("--output <path>", "Manifest path (default: derived roles/latest.json)")
    .option("--eoa", "The value is an externally owned account: assert it has no code rather than requiring code")
    .action(function (this: Command, field: string, value: string, opts: { output?: string; eoa?: boolean }) {
      const deployment = resolveDeployment(this)

      // Asserted either way rather than skipped, so recording a Safe as an EOA — or
      // an EOA where a contract belongs — fails here instead of at first use.
      if (isRolesManifestAddressField(field)) {
        const hasCode = isContract(value, deployment)
        if (opts.eoa && hasCode) {
          throw new Error(`${field} ${value} has code on chain — drop --eoa`)
        }
        if (!opts.eoa && !hasCode) {
          throw new Error(`${field} ${value} has no code on chain (use --eoa if it is one)`)
        }
      }

      const { path, versionedPath, manifest } = writeRolesManifest(
        deployment.root,
        deployment.config,
        { [field]: value },
        { output: opts.output, overwrite: true }
      )

      outputResult(this, {
        status: "ok",
        command: "manifest set",
        data: { field, value: manifest[field], path, versionedPath },
      })
    })

  cmd
    .command("show")
    .description("Print the deployment's roles manifest")
    .option("--output <path>", "Manifest path (default: derived roles/latest.json)")
    .action(function (this: Command, opts: { output?: string }) {
      const deployment = resolveDeployment(this)
      const path = rolesManifestPath(deployment.root, deployment.config, opts.output)
      const manifest = readRolesManifest(path)
      if (!manifest) throw new Error(`roles manifest not found: ${path}`)
      outputResult(this, { status: "ok", command: "manifest show", data: { path, ...manifest } })
    })
}
