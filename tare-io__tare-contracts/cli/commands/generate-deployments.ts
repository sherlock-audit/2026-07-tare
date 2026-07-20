import type { Command } from "commander"
import { runGenerateDeployments } from "../lib/generate-deployments.js"
import type { GlobalOpts } from "../lib/cast.js"

export function registerGenerateDeployments(program: Command): void {
  program
    .command("generate-deployments")
    .description("Generate src/deployments.ts from deployments/ JSON artifacts")
    .action(function (this: Command) {
      const { root } = this.optsWithGlobals() as GlobalOpts
      runGenerateDeployments(root)
    })
}
