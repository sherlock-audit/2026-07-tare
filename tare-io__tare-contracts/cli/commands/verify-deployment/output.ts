import chalk from "chalk"
import type { Check } from "./types.js"

export function printResults(results: Check[], jsonOutput: boolean): void {
  const passed = results.filter((check) => check.status === "pass").length
  const failed = results.filter((check) => check.status === "fail").length
  const skipped = results.filter((check) => check.status === "skip").length
  const total = passed + failed + skipped

  if (jsonOutput) {
    process.stdout.write(
      JSON.stringify({
        status: failed > 0 ? "fail" : "pass",
        summary: { passed, failed, skipped, total },
        checks: results,
      }) + "\n"
    )
    if (failed > 0) process.exit(1)
    return
  }

  const style = {
    pass: { icon: "✓", fmt: chalk.green },
    fail: { icon: "✗", fmt: chalk.red },
    skip: { icon: "○", fmt: chalk.yellow },
    info: { icon: "ℹ", fmt: chalk.cyan },
  } as const

  let currentSection = ""
  for (const check of results) {
    if (check.section !== currentSection) {
      currentSection = check.section
      console.log(
        `\n${chalk.dim("──")} ${chalk.bold(currentSection)} ${chalk.dim("─".repeat(Math.max(0, 58 - currentSection.length)))}`
      )
    }
    const { icon, fmt } = style[check.status]
    const detail = check.detail && check.status !== "pass" ? ` ${fmt(`(${check.detail})`)}` : ""
    console.log(`  ${fmt(icon)} ${check.name}${detail}`)
  }

  console.log(`\n${chalk.dim("─".repeat(62))}`)
  const summary = `${passed} passed, ${failed} failed, ${skipped} skipped (${total} total)`
  if (failed > 0) {
    console.log(chalk.red.bold(`✗ FAILED: ${summary}`))
    process.exit(1)
  } else {
    console.log(chalk.green.bold(`✓ ALL CHECKS PASSED: ${summary}`))
  }
}
