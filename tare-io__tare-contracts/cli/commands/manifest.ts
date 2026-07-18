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
    .argument("<value>", "Field value; addresses are checksummed and must have code on chain")
    .option("--output <path>", "Manifest path (default: derived roles/latest.json)")
    .option("--no-code-check", "Skip the has-code-on-chain check for address fields")
    .action(function (this: Command, field: string, value: string, opts: { output?: string; codeCheck: boolean }) {
      const deployment = resolveDeployment(this)

      if (isRolesManifestAddressField(field) && opts.codeCheck && !isContract(value, deployment)) {
        throw new Error(`${field} ${value} has no code on chain (use --no-code-check for EOAs)`)
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
