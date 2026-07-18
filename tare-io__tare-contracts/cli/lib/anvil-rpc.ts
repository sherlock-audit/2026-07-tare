import { execFileSync } from "node:child_process"
import type { ResolvedDeployment } from "./cast.js"

/** `cast rpc <method> [params...]` against the deployment's RPC (anvil cheatcodes etc.). */
export function castRpc(method: string, params: string[], deployment: ResolvedDeployment): string {
  return execFileSync("cast", ["rpc", method, ...params, "--rpc-url", deployment.rpcUrl], {
    encoding: "utf8",
  }).trim()
}

/** `cast send --from <addr> --unlocked` — a tx from an anvil-impersonated account. */
export function castSendUnlocked(
  from: string,
  to: string,
  signature: string,
  args: string[],
  deployment: ResolvedDeployment
): string {
  const output = execFileSync(
    "cast",
    ["send", to, signature, ...args, "--from", from, "--unlocked", "--json", "--rpc-url", deployment.rpcUrl],
    { encoding: "utf8" }
  )
  return (JSON.parse(output) as { transactionHash: string }).transactionHash
}

/** Run `fn` while impersonating `account` (funded with 1 ETH for gas). Anvil only. */
export function withImpersonation<T>(account: string, deployment: ResolvedDeployment, fn: () => T): T {
  castRpc("anvil_impersonateAccount", [account], deployment)
  // 1 ETH so the impersonated account can pay gas.
  castRpc("anvil_setBalance", [account, "0xDE0B6B3A7640000"], deployment)
  try {
    return fn()
  } finally {
    castRpc("anvil_stopImpersonatingAccount", [account], deployment)
  }
}
