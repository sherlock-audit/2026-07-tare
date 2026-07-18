# Post-deployment Configuration — Testnet

## Overview

This document describes how to bring Tare smart contracts to operational state on a **testnet** network (e.g., Avalanche Fuji) after contract deployment. All steps are executed by a single signer via the CLI.

## Prerequisites

- **Deployed contracts:** Loans, LoansNFT, SmartAccountFactory, TrustedCalls, TrustedSpender, USDC (or currency token)
- **Admin/Guardian Safe:** A Gnosis Safe (threshold 1/N) that holds `GUARDIAN_ROLE` on Loans. The signer must be funded with native gas token.
- **Hot Proxy Safe:** A threshold-1 Safe that is the sole owner of all Smart Accounts. The backend signs through this Safe to execute TrustedCalls and TrustedSpender operations without a multisig ceremony.
- **Smart Accounts:** Four Safes deployed via SmartAccountFactory (Originator, Investor, Borrower, Servicer), each owned by the Hot Proxy (threshold 1/1).

## What the Factory Already Does

When a Smart Account is deployed via `SmartAccountFactory.deploySmartAccount(...)`, the factory's `configureSmartAccount` delegatecall handles:

- Enables TrustedCalls as a Safe module on the SA
- Approves each configured currency for TrustedSpender (unlimited ERC20 approval)
- Adds each delegate (Hot Proxy) to both TrustedCalls and TrustedSpender
- Sets unlimited allowances on TrustedSpender for each trusted recipient (e.g., offramp address)

See [smart-accounts.md](../smart-accounts.md) for full details.

## Execution

All steps are executed via the `setup-smart-account` CLI command. A single signer (EOA with encrypted keystore or private key) submits all transactions through the Admin Safe.

### Pattern A: Admin Safe → Target Contract

The `safeExec` helper computes the Safe tx hash, calls `approveHash`, and executes in a single broadcast. One on-chain transaction per call.

Example: `Loans.approveOriginator(originatorSA)` — the Admin Safe calls Loans directly.

### Pattern B: Admin Safe → Target SA → Inner Call (Owner Path)

The `nestedSafeExec` helper handles the full flow:

1. Compute `safeTxHash` on the target SA
2. `safeExec(adminSafe, targetSA, approveHashCalldata)` — Admin Safe approves the hash
3. `castSend(targetSA, execTransaction, ...)` — execute with the pre-approved signature (type-1)

Two on-chain transactions per SA (approveHash + execTransaction).

Example: `USDC.approve(Loans, MAX)` executed by the Investor SA — the Admin Safe (as owner of the SA) instructs the Investor SA to approve the Loans contract.

## Setup Steps

### Step 1: Run `setup-smart-account`

```bash
npx tsx cli/index.ts setup-smart-account \
  --chain fuji \
  --originator <ORIGINATOR_SA> \
  --borrower <BORROWER_SA> \
  --investor <INVESTOR_SA> \
  --servicer <SERVICER_SA> \
  --hot-proxy <HOT_PROXY> \
  --admin-safe <ADMIN_SAFE> \
  --private-key $ADMIN_SIGNER_KEY
```

This single command executes all required configuration in one run:

**Pattern A calls** (Admin Safe → Loans):

```solidity
Loans.approveOriginator(originatorSA)
Loans.registerAddressOnBehalfOf(originatorSA, Roles.Borrower, borrowerSA)
Loans.registerAddressOnBehalfOf(originatorSA, Roles.Investor, investorSA)
Loans.registerAddressOnBehalfOf(originatorSA, Roles.Servicer, servicerSA)
```

**Pattern B calls** (Admin Safe → target SA → USDC):

```solidity
// From Investor SA:
USDC.approve(LoansContract, type(uint256).max)

// From Borrower SA:
USDC.approve(LoansContract, type(uint256).max)
```

**Why each call is needed:**

| Call | Reason |
|------|--------|
| `approveOriginator` | `create()` requires `isAdminOrApprovedOriginator(msg.sender)` |
| `registerAddressOnBehalfOf` | `_create()` validates participants against the originator's address book |
| Investor USDC approval | `fund()` calls `currency.safeTransferFrom(investorAddress, ...)` |
| Borrower USDC approval | `pay()` calls `currency.safeTransferFrom(borrowers[loanId], ...)` |

The command skips steps that are already configured (idempotent) and outputs a verification summary at the end. It also includes factory-configuration steps (addDelegate, enableModule, approve TrustedSpender) for repair/migration of SAs not deployed via the factory.

### Step 2: Fund Smart Accounts (Manual)

Transfer USDC and native gas token to:
- **Investor SA** — needs USDC to fund loans
- **Borrower SA** — needs USDC to make payments (if paying on-chain directly)

The method to use depends on the address of `currency` specified in the configuration: 
- For official USDC, use the Circle faucet: [https://faucet.circle.com/](https://faucet.circle.com/)
- For MockUSDC: call `mint()`

# Work In Progress

## LoansExchange Setup

### Register Buyer in Seller's Address Book (Pattern B — self-service)

```solidity
// Executed by Seller SA (e.g., Originator or current investor)
Loans.registerAddress(Roles.Investor, buyerAddress)
```

**Why:** `createOffer()` checks `isRegisteredForRole(msg.sender, Roles.Investor, buyer)`. The seller must register the buyer in their own address book.

### Buyer USDC Approval for Exchange (Pattern B)

```solidity
// Executed by Buyer SA
USDC.approve(LoansExchangeContract, type(uint256).max)
```

**Why:** `acceptOffer()` pulls the purchase price from the buyer via `safeTransferFrom`.

## PortfolioVault Setup

### Grant Vault Roles (Pattern A)

```solidity
PortfolioVault.grantRole(PORTFOLIO_MANAGER, managerAddress)
PortfolioVault.grantRole(INVESTOR_MANAGER, managerAddress)
```

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

## Verification

After setup, confirm state using the CLI:

```bash
npx tsx cli/index.ts verify-deployment \
  --chain fuji \
  --originator <address> \
  --borrower <address> \
  --investor <address> \
  --servicer <address> \
  --hot-proxy <address>
```
