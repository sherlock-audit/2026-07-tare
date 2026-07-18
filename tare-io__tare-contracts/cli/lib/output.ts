import type { Command } from "commander"

export interface CommandResult {
  status: "ok" | "error"
  command: string
  data: Record<string, unknown>
  txHash?: string
}

export function isJsonMode(cmd: Command): boolean {
  return (cmd.optsWithGlobals() as { json?: boolean }).json === true
}

const ADDRESS_RE = /0x[0-9a-fA-F]{40}/g

/**
 * Annotate any 40-hex address in `text` with its known label, e.g.
 * `0x7417…6bf5 (operationalManagementSafe)`. `labels` is keyed by lowercased
 * address. Used for human-readable output only — JSON output stays raw.
 */
function annotateAddresses(text: string, labels?: Record<string, string>): string {
  if (!labels) return text
  return text.replace(ADDRESS_RE, (match) => {
    const label = labels[match.toLowerCase()]
    return label ? `${match} (${label})` : match
  })
}

export function outputResult(cmd: Command, result: CommandResult, labels?: Record<string, string>): void {
  if (isJsonMode(cmd)) {
    process.stdout.write(JSON.stringify(result, null, 2) + "\n")
  } else {
    if (result.status === "error") {
      console.error(`Error: ${annotateAddresses(String(result.data.message ?? "unknown error"), labels)}`)
      return
    }
    for (const [key, value] of Object.entries(result.data)) {
      if (value !== null && typeof value === "object") {
        // Render nested objects/arrays readably instead of "[object Object]".
        console.log(`${key}:`)
        for (const line of JSON.stringify(value, null, 2).split("\n")) {
          console.log(`  ${annotateAddresses(line, labels)}`)
        }
      } else {
        console.log(`${key}: ${annotateAddresses(String(value), labels)}`)
      }
    }
    if (result.txHash) {
      console.log(`txHash: ${result.txHash}`)
    }
  }
}
