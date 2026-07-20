import { keccak256, toBytes, type Address } from "viem"
import type { SelectorGroup } from "./types.js"

// ── Role constants ──────────────────────────────────────────────────────────

export const ADMIN_ROLE = "0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775" as const
export const GUARDIAN_ROLE = "0x55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041" as const
export const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000" as const
export const DEAD_ADDRESS = "0x000000000000000000000000000000000000dEaD" as Address

// OZ TimelockController roles.
export const PROPOSER_ROLE = keccak256(toBytes("PROPOSER_ROLE"))
export const CANCELLER_ROLE = keccak256(toBytes("CANCELLER_ROLE"))
export const EXECUTOR_ROLE = keccak256(toBytes("EXECUTOR_ROLE"))

// ── Minimal ABIs (only view functions we need) ──────────────────────────

export const hasRoleAbi = [
  {
    type: "function",
    name: "hasRole",
    inputs: [
      { type: "bytes32", name: "role" },
      { type: "address", name: "account" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const

export const getRoleAdminAbi = [
  {
    type: "function",
    name: "getRoleAdmin",
    inputs: [{ type: "bytes32", name: "role" }],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
] as const

export const trustedCallsAbi = [
  {
    type: "function",
    name: "trustedCalls",
    inputs: [{ type: "bytes32", name: "key" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const

// ── Trusted call selectors to verify ────────────────────────────────────

export const SELECTOR_GROUPS: SelectorGroup[] = [
  {
    label: "Loans",
    contract: "loans",
    entries: [
      { name: "create", sig: "create(address,address,address,address,int128,uint48)" },
      { name: "accrue", sig: "accrue(uint64,int128,uint48,bytes32)" },
      { name: "fund", sig: "fund(uint64,int128,uint48,bytes32)" },
      { name: "disburse", sig: "disburse(uint64,int128,int128,uint48,uint48,uint48,uint32,int128,uint48,bytes32)" },
      { name: "pay", sig: "pay(uint64,int128,uint48,bytes32)" },
      { name: "applyWaterfall", sig: "applyWaterfall(uint64,int128,int128,int128,int128,uint48,uint48,bytes32)" },
      { name: "servicerWithdraw", sig: "servicerWithdraw(uint64[],uint48,bytes32)" },
      { name: "investorWithdraw", sig: "investorWithdraw(uint64[],uint48,bytes32)" },
      { name: "originatorWithdraw", sig: "originatorWithdraw(uint64[],uint48,bytes32)" },
      { name: "updateLoanData", sig: "updateLoanData(uint64,uint8,uint48,uint48,uint48)" },
      { name: "chargeMiscFee", sig: "chargeMiscFee(uint64,int128,uint48,bytes32)" },
      { name: "createLedgerEntries", sig: "createLedgerEntries(uint64,uint48,(uint8,uint8,int128,uint16,bytes32)[])" },
      { name: "refundBorrower", sig: "refundBorrower(uint64,uint8,int128,uint48,uint16,bytes32)" },
      { name: "returnFunds", sig: "returnFunds(uint64,uint8,int128,uint48,uint16,bytes32)" },
    ],
  },
  {
    label: "Exchange",
    contract: "exchange",
    entries: [
      { name: "createOffer", sig: "createOffer(address,uint128,uint48,uint64[])" },
      { name: "acceptOffer", sig: "acceptOffer(uint64)" },
      { name: "cancelOffer", sig: "cancelOffer(uint64)" },
    ],
  },
  {
    label: "Vault",
    contract: "vault",
    entries: [
      { name: "updateNav", sig: "updateNav(uint256)" },
      { name: "collectCashflows", sig: "collectCashflows(uint64[],bytes32)" },
      { name: "acceptSaleOffer", sig: "acceptSaleOffer(uint64)" },
      { name: "createSaleOffer", sig: "createSaleOffer(address,uint128,uint48,uint64[])" },
      { name: "cancelSaleOffer", sig: "cancelSaleOffer(uint64)" },
      { name: "requestDeposit", sig: "requestDeposit(uint256,address,address)" },
      { name: "deposit", sig: "deposit(uint256,address,address)" },
      { name: "approveDeposit", sig: "approveDeposit(address,uint256)" },
      { name: "cancelDepositRequest", sig: "cancelDepositRequest(address,address)" },
      { name: "requestRedeem", sig: "requestRedeem(uint256,address,address)" },
      { name: "redeem", sig: "redeem(uint256,address,address)" },
      { name: "approveRedemption", sig: "approveRedemption(address,uint256)" },
      { name: "cancelRedeemRequest", sig: "cancelRedeemRequest(address,address)" },
    ],
  },
]
