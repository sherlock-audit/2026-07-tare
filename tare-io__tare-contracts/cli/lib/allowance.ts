import { castCall, castCalldata, readContractAddress, safeExec, type ResolvedDeployment, type SafeExecOptions, type SafeExecResult } from "./cast.js"

export function checkAllowance(trustedSpender: string, token: string, from: string, to: string, deployment: ResolvedDeployment): string {
  return castCall(trustedSpender, "getAllowance(address,address,address)(uint256,uint48)", [token, from, to], deployment)
}

export function setAllowanceViaSafe(
  safeAddress: string,
  trustedSpender: string,
  token: string,
  from: string,
  to: string,
  amount: string,
  validUntil: string,
  deployment: ResolvedDeployment,
  execOpts?: SafeExecOptions,
): SafeExecResult {
  const data = castCalldata("setAllowance(address,address,address,uint208,uint48)", [token, from, to, amount, validUntil])
  return safeExec(safeAddress, trustedSpender, data, deployment, execOpts)
}

export function resolveCurrency(deployment: ResolvedDeployment): string {
  const loansAddress = readContractAddress(deployment.root, deployment.config, "loans", "Loans")
  return castCall(loansAddress, "currency()(address)", [], deployment)
}
