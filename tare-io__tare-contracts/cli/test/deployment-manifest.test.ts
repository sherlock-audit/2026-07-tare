import { test } from "node:test"
import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { readOptionalContractAddress } from "../lib/cast.js"
import type { DeploymentConfig } from "../lib/deployment-configs.js"

const FORWARDER = "0x1000000000000000000000000000000000000004"

const config = { chain: "foundry", shortName: "dev" } as DeploymentConfig

function fixtureRoot(components: Record<string, Record<string, string>>): string {
  const root = mkdtempSync(join(tmpdir(), "tare-manifest-"))
  for (const [component, contracts] of Object.entries(components)) {
    const dir = join(root, "deployments", "foundry", "dev", component)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, "latest.json"), JSON.stringify({ contracts }))
  }
  return root
}

test("reads a contract from a deployed component", () => {
  const root = fixtureRoot({ forwarder: { Forwarder: FORWARDER } })
  assert.equal(readOptionalContractAddress(root, config, "forwarder", "Forwarder"), FORWARDER)
})

// A chain that predates the standalone deploy has no `forwarder` component at all;
// resolving the relay must fall through to `accounts` rather than blow up on ENOENT.
test("a component that was never deployed reads as null", () => {
  const root = fixtureRoot({ accounts: { Forwarder: FORWARDER } })
  assert.equal(readOptionalContractAddress(root, config, "forwarder", "Forwarder"), null)
  assert.equal(readOptionalContractAddress(root, config, "accounts", "Forwarder"), FORWARDER)
})

test("a deployed component missing the contract reads as null", () => {
  const root = fixtureRoot({ accounts: { TrustedCalls: FORWARDER } })
  assert.equal(readOptionalContractAddress(root, config, "accounts", "Forwarder"), null)
})
