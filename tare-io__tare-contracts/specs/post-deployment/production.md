# Post-deployment Configuration — Production

## Overview

This document describes how to bring Tare smart contracts to operational state on a **production** network (e.g., Avalanche C-Chain) after contract deployment. Production uses multi-signature Safes requiring coordination between a hardware wallet operator and the backend.

## Prerequisites

- **Deployed contracts:** Loans, LoansNFT, SmartAccountFactory, TrustedCalls, TrustedSpender, USDC (or currency token)
- **Admin Safe:** A Gnosis Safe that holds `GUARDIAN_ROLE` on Loans. Owned exclusively by hardware wallet(s). The backend is registered as a **Transaction Service delegate** (off-chain role) allowing it to propose transactions that appear in Safe{Wallet} UI, but it cannot sign or execute.
- **Hot Proxy Safe:** A threshold-1 Gnosis Safe controlled by the backend. Serves as a delegate on TrustedCalls and TrustedSpender for all Smart Accounts, and as a co-owner of each Smart Account (alongside the Admin Safe).
- **Smart Accounts:** Four Safes deployed via SmartAccountFactory (Originator, Investor, Borrower, Servicer), each with threshold 2/2 (owners: Hot Proxy + Admin Safe).
- **Safe Transaction Service:** Must be available on the target chain (Avalanche C-Chain is supported). The CLI uses `@safe-global/api-kit` to propose transactions.

## What the Factory Already Does

When a Smart Account is deployed via `SmartAccountFactory.deploySmartAccount(...)`, the factory's `configureSmartAccount` delegatecall handles:

- Enables TrustedCalls as a Safe module on the SA
- Approves each configured currency for TrustedSpender (unlimited ERC20 approval)
- Adds each delegate (Hot Proxy) to both TrustedCalls and TrustedSpender
- Sets unlimited allowances on TrustedSpender for each trusted recipient (e.g., offramp address)

See [smart-accounts.md](../smart-accounts.md) for full details.

## CLI Command: `production-setup`

**Status:** Not yet implemented.

```bash
npx tsx cli/index.ts production-setup \
  --chain <chain> \
  --originator <address> \
  --borrower <address> \
  --investor <address> \
  --servicer <address>
```

**What it does:**

1. Reads `admin-safe` and `hot-proxy` addresses from the deployment config
2. Executes Hot Proxy's `approveHash` calls on each target SA immediately (automated, Hot Proxy is an SA owner)
3. Proposes all Admin Safe transactions to the Safe Transaction Service via API Kit (as delegate)
4. Human operator opens Safe{Wallet} UI, reviews pending transactions, signs with hardware wallet, and executes

No private keys needed from the human. No TX Builder JSON files to import.

**Proposed transactions on Admin Safe:**

| # | Transaction | Pattern |
|---|-------------|---------|
| 1 | MultiSend: `approveOriginator` + `registerAddressOnBehalfOf` × 3 | A |
| 2 | MultiSend: `investorSA.approveHash(hash)` + `investorSA.execTransaction(...)` | B |
| 3 | MultiSend: `borrowerSA.approveHash(hash)` + `borrowerSA.execTransaction(...)` | B |

## Execution Patterns

### Pattern A: Admin Safe → Target Contract

A direct call from the Admin Safe to a target contract.

```
Hardware Wallet(s) ──► Admin Safe ──► Target Contract
```

**Workflow:**

1. CLI proposes the transaction on the Admin Safe via the Safe Transaction Service (as delegate)
2. Human operator opens Safe{Wallet} UI, sees pending transaction, reviews it
3. Human connects hardware wallet, signs, and executes

**Result:** One on-chain transaction. One signing action.

### Pattern B: Admin Safe → Target SA → Inner Call (Owner Path)

A nested execution where the Admin Safe acts as a co-owner of a target Smart Account and instructs it to make an external call.

```
Hot Proxy ──► targetSA.approveHash(hash)              ← automated (step 1)

Hardware Wallet(s) ──► Admin Safe ──► MultiSend:      ← human signs (step 2)
                                        ├─ targetSA.approveHash(hash)
                                        └─ targetSA.execTransaction(innerCall)
```

**Workflow:**

1. CLI computes the `safeTxHash` on the target SA by calling `getTransactionHash(to, value, data, operation, ..., nonce)` — this uniquely identifies the inner call to be executed
2. CLI executes Hot Proxy's `targetSA.approveHash(safeTxHash)` immediately (Hot Proxy is an SA owner, threshold-1 Safe)
3. CLI proposes a **MultiSend** on the Admin Safe containing:
   - `targetSA.approveHash(safeTxHash)` — Admin Safe approves the hash (now both SA owners have approved)
   - `targetSA.execTransaction(innerCall)` — executes with two type-1 pre-approved signatures
4. Human signs and executes the MultiSend in Safe{Wallet} UI

**Result:** One signing action for the human. Everything completes atomically in one on-chain transaction.

## Setup Steps

### Step 1: Run `production-setup`

```bash
npx tsx cli/index.ts production-setup \
  --chain avalanche \
  --originator <ORIGINATOR_SA> \
  --borrower <BORROWER_SA> \
  --investor <INVESTOR_SA> \
  --servicer <SERVICER_SA>
```

This single command:
1. Executes Hot Proxy's `approveHash` on Investor SA and Borrower SA (automated)
2. Proposes 3 transactions on the Admin Safe via the Transaction Service

**What the human operator does next:**

1. Open Safe{Wallet} UI → select the Admin Safe
2. See 3 pending transactions
3. Review each, sign with hardware wallet, execute

**Calls included:**

| Call | Pattern | Reason |
|------|---------|--------|
| `Loans.approveOriginator(originatorSA)` | A (MultiSend) | `create()` requires `isAdminOrApprovedOriginator(msg.sender)` |
| `Loans.registerAddressOnBehalfOf` × 3 | A (MultiSend) | `_create()` validates participants against address book |
| `USDC.approve(Loans, X amount)` from Investor SA | B (MultiSend) | `fund()` calls `safeTransferFrom(investorAddress, ...)` |
| `USDC.approve(Loans, Y amount)` from Borrower SA | B (MultiSend) | `pay()` calls `safeTransferFrom(borrowers[loanId], ...)` |

### Step 2: Fund Smart Accounts (Manual)

Transfer USDC and native gas token to:
- **Investor SA** — needs USDC to fund loans
- **Borrower SA** — needs USDC to make payments (if paying on-chain directly)

Use any method: exchange withdrawal, bridge, direct transfer from a funded wallet.

## LoansExchange Setup

### Register Buyer in Seller's Address Book (Pattern B)

```solidity
// Executed by Seller SA
Loans.registerAddress(Roles.Investor, buyerAddress)
```

**Why:** `createOffer()` checks `isRegisteredForRole(msg.sender, Roles.Investor, buyer)`.

Use `approve-sa-tx` with the Seller SA and calldata `registerAddress(uint8,address)`.

### Buyer USDC Approval for Exchange (Pattern B)

```solidity
// Executed by Buyer SA
USDC.approve(LoansExchangeContract, type(uint256).max)
```

Use `approve-sa-tx` with the Buyer SA.


# Work In Progress

## PortfolioVault Setup

### Grant Vault Roles (Pattern A)

```solidity
PortfolioVault.grantRole(PORTFOLIO_MANAGER, managerAddress)
PortfolioVault.grantRole(INVESTOR_MANAGER, managerAddress)
```

Add these to the Step 1 MultiSend batch, or propose as a separate transaction.

### Grant Shareholder Role (Pattern A)

```solidity
VaultShareToken.grantRole(SHAREHOLDER_ROLE, investorAddress)
```

### Register Address Book on Vault (Pattern A)

```solidity
PortfolioVault.registerAddress(address)
```

### Investor USDC Approval for Vault (Pattern B)

```solidity
USDC.approve(PortfolioVaultContract, type(uint256).max)
```

Use `approve-sa-tx` with the Investor SA.

## CLI Command: `approve-sa-tx`

**Status:** Not yet implemented.

After the initial setup is complete, day-2+ operations may require making arbitrary calls from a Smart Account — e.g., registering a new buyer, approving a new contract, or any future SA interaction. This command orchestrates a single Pattern B call on demand.

```bash
npx tsx cli/index.ts production-setup approve-sa-tx \
  --chain <chain> \
  --smart-account <address> \
  --target <address> \
  --calldata <hex>
```

**What it does:**

1. Computes `safeTxHash` on the target SA for the given call
2. Executes Hot Proxy's `targetSA.approveHash(hash)` immediately
3. Proposes a MultiSend on the Admin Safe via the Transaction Service:
   - `targetSA.approveHash(hash)`
   - `targetSA.execTransaction(innerCall)`
4. Human signs and executes in Safe{Wallet} UI

**Examples:**

```bash
# Register a new buyer in the originator's address book
npx tsx cli/index.ts production-setup approve-sa-tx \
  --chain avalanche \
  --smart-account <ORIGINATOR_SA> \
  --target <LOANS_ADDRESS> \
  --calldata $(cast calldata "registerAddress(uint8,address)" 2 <BUYER_ADDRESS>)

# Approve USDC spending for LoansExchange from a buyer SA
npx tsx cli/index.ts production-setup approve-sa-tx \
  --chain avalanche \
  --smart-account <BUYER_SA> \
  --target <USDC_ADDRESS> \
  --calldata $(cast calldata "approve(address,uint256)" <EXCHANGE_ADDRESS> $(cast max-uint))
```

## Verification

After setup, confirm state using the CLI:

```bash
npx tsx cli/index.ts verify-deployment \
  --chain avalanche \
  --originator <address> \
  --borrower <address> \
  --investor <address> \
  --servicer <address> \
  --hot-proxy <address>
```


