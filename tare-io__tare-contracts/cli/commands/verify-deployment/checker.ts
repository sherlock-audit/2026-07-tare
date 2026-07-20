import {
  createPublicClient,
  getAddress,
  http,
  toFunctionSelector,
  keccak256,
  encodePacked,
  type Address,
  type PublicClient,
  type Transport,
  type Chain,
} from "viem"
import { hasRoleAbi, getRoleAdminAbi, trustedCallsAbi } from "./constants.js"
import type { Check } from "./types.js"

export class Checker {
  readonly results: Check[] = []
  private readonly client: PublicClient<Transport, Chain | undefined>

  constructor(rpcUrl: string) {
    this.client = createPublicClient({ transport: http(rpcUrl) })
  }

  // ── Result helpers ──

  pass(section: string, name: string) {
    this.results.push({ section, name, status: "pass" })
  }

  fail(section: string, name: string, detail: string) {
    this.results.push({ section, name, status: "fail", detail })
  }

  skip(section: string, name: string, detail: string) {
    this.results.push({ section, name, status: "skip", detail })
  }

  // Informational line — printed but never affects the pass/fail gate.
  info(section: string, name: string, detail?: string) {
    this.results.push({ section, name, status: "info", detail })
  }

  // ── On-chain reads (generic via raw ABI construction) ──

  async readAddress(contract: Address, functionName: string, args?: Address[]): Promise<Address> {
    const inputs = args ? args.map((_, i) => ({ type: "address" as const, name: `arg${i}` })) : []
    const abi = [
      {
        type: "function" as const,
        name: functionName,
        inputs,
        outputs: [{ type: "address" as const }],
        stateMutability: "view" as const,
      },
    ] as const
    return this.client.readContract({ address: contract, abi, functionName, args: args ?? [] }) as Promise<Address>
  }

  async readBytes32(contract: Address, functionName: string): Promise<`0x${string}`> {
    const abi = [
      {
        type: "function" as const,
        name: functionName,
        inputs: [],
        outputs: [{ type: "bytes32" as const }],
        stateMutability: "view" as const,
      },
    ] as const
    return this.client.readContract({ address: contract, abi, functionName }) as Promise<`0x${string}`>
  }

  async readUint(contract: Address, functionName: string): Promise<bigint> {
    const abi = [
      {
        type: "function" as const,
        name: functionName,
        inputs: [],
        outputs: [{ type: "uint256" as const }],
        stateMutability: "view" as const,
      },
    ] as const
    return this.client.readContract({ address: contract, abi, functionName }) as Promise<bigint>
  }

  // ── High-level assertions ──

  async checkDeployed(section: string, label: string, address: Address): Promise<boolean> {
    const code = await this.client.getCode({ address })
    const hasCode = !!code && code !== "0x"
    this.results.push({
      section,
      name: `${label} deployed`,
      status: hasCode ? "pass" : "fail",
      detail: hasCode ? undefined : `No code at ${address}`,
    })
    return hasCode
  }

  async checkWiring(
    section: string,
    label: string,
    contract: Address,
    getter: string,
    expected: Address,
    args?: Address[]
  ): Promise<void> {
    try {
      const actual = await this.readAddress(contract, getter, args)
      const matches = getAddress(actual) === getAddress(expected)
      this.results.push({
        section,
        name: label,
        status: matches ? "pass" : "fail",
        detail: matches ? undefined : `expected ${expected}, got ${actual}`,
      })
    } catch (err) {
      this.fail(section, label, String(err))
    }
  }

  async checkHasRole(
    section: string,
    contractName: string,
    contract: Address,
    roleName: string,
    roleHash: `0x${string}`,
    holder: Address,
    holderLabel: string
  ): Promise<void> {
    try {
      const has = await this.client.readContract({
        address: contract,
        abi: hasRoleAbi,
        functionName: "hasRole",
        args: [roleHash, holder],
      })
      const label = `${contractName}: ${holderLabel} has ${roleName}`
      this.results.push({
        section,
        name: label,
        status: has ? "pass" : "fail",
        detail: has ? undefined : "expected true, got false",
      })
    } catch (err) {
      this.fail(section, `${contractName}: ${holderLabel} has ${roleName}`, String(err))
    }
  }

  async checkDoesNotHaveRole(
    section: string,
    contractName: string,
    contract: Address,
    roleName: string,
    roleHash: `0x${string}`,
    holder: Address,
    holderLabel: string
  ): Promise<void> {
    try {
      const has = await this.client.readContract({
        address: contract,
        abi: hasRoleAbi,
        functionName: "hasRole",
        args: [roleHash, holder],
      })
      const label = `${contractName}: ${holderLabel} does not have ${roleName}`
      this.results.push({
        section,
        name: label,
        status: has ? "fail" : "pass",
        detail: has ? "expected false, got true" : undefined,
      })
    } catch (err) {
      this.fail(section, `${contractName}: ${holderLabel} does not have ${roleName}`, String(err))
    }
  }

  async checkAddressGetter(
    section: string,
    contractName: string,
    contract: Address,
    getter: string,
    expected: Address
  ): Promise<void> {
    try {
      const actual = await this.readAddress(contract, getter)
      const matches = getAddress(actual) === getAddress(expected)
      const label = `${contractName}: ${getter} is ${expected}`
      this.results.push({
        section,
        name: label,
        status: matches ? "pass" : "fail",
        detail: matches ? undefined : `expected ${expected}, got ${actual}`,
      })
    } catch (err) {
      this.fail(section, `${contractName}: ${getter} is ${expected}`, String(err))
    }
  }

  async checkRoleAdmin(
    section: string,
    contractName: string,
    contract: Address,
    roleName: string,
    roleHash: `0x${string}`,
    expectedAdmin: `0x${string}`
  ): Promise<void> {
    try {
      const actual = await this.client.readContract({
        address: contract,
        abi: getRoleAdminAbi,
        functionName: "getRoleAdmin",
        args: [roleHash],
      })
      const matches = actual.toLowerCase() === expectedAdmin.toLowerCase()
      const label = `${contractName}: ${roleName} admin is ${expectedAdmin}`
      this.results.push({
        section,
        name: label,
        status: matches ? "pass" : "fail",
        detail: matches ? undefined : `expected ${expectedAdmin}, got ${actual}`,
      })
    } catch (err) {
      this.fail(section, `${contractName}: ${roleName} admin is ${expectedAdmin}`, String(err))
    }
  }

  async checkTrustedCall(
    section: string,
    trustedCallsAddr: Address,
    target: Address,
    groupLabel: string,
    fnName: string,
    fnSig: string
  ): Promise<void> {
    try {
      const selector = toFunctionSelector(fnSig) as `0x${string}`
      const key = keccak256(encodePacked(["address", "bytes4"], [target, selector]))
      const trusted = await this.client.readContract({
        address: trustedCallsAddr,
        abi: trustedCallsAbi,
        functionName: "trustedCalls",
        args: [key],
      })
      const label = `TrustedCalls: ${groupLabel}.${fnName} whitelisted`
      this.results.push({
        section,
        name: label,
        status: trusted ? "pass" : "fail",
        detail: trusted ? undefined : `${fnName} not trusted on ${target}`,
      })
    } catch (err) {
      this.fail(section, `TrustedCalls: ${groupLabel}.${fnName} whitelisted`, String(err))
    }
  }
}
