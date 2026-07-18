import type { Command } from "commander"
import { runExtractEnums } from "../lib/extract-enums.js"
import type { GlobalOpts } from "../lib/cast.js"

export function registerExtractEnums(program: Command): void {
  program
    .command("extract-enums")
    .description("Extract enums and constants from Solidity contracts to src/enums.ts")
    .action(function (this: Command) {
      const { root } = this.optsWithGlobals() as GlobalOpts
      runExtractEnums(root)
    })
}
