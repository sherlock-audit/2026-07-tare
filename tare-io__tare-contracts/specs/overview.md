# Tare Smart Contracts - Overview

## Introduction

Tare is a lending platform that connects loan originators with investors. Originators underwrite unsecured consumer loans — borrowers receive a lump sum upfront and repay it with fixed monthly payments over a set term (e.g., 36 months). Investors fund these loans and earn returns through interest payments. A servicer manages day-to-day operations: collecting payments from borrowers, distributing funds to investors, and handling loan modifications.

Borrowers interact entirely in fiat — they receive USD in their bank accounts and make USD payments. Investors interact entirely in stablecoins (USDC) on-chain. Tare handles the conversion between fiat and stablecoins; the smart contracts only manage stablecoin flows.

Each loan is represented as an ERC721 NFT. The NFT owner is the investor for that loan and receives all cashflows. Loans can be traded between investors — either directly via NFT transfer or through an on-chain exchange that settles USDC and NFTs atomically. A portfolio vault allows investors to gain diversified exposure to many loans through a single ERC20 share token, rather than managing individual loan NFTs.

The smart contracts serve as the single source of truth for loan state. Every financial movement — funding, disbursement, borrower payment, fee allocation, withdrawal — is recorded in a per-loan double-entry ledger. Interest and payment schedules are calculated off-chain by the servicer and submitted on-chain, where the contracts enforce accounting accuracy and cash segregation.

### System Components

1. **Loans** — Core lending protocol that manages loan lifecycle, cashflows, and accounting through a double-entry ledger.
2. **Portfolio Vault** — An ERC-7540/7575 tokenized fund that enables investors to gain exposure to a portfolio of loans through a single ERC20 share token, with on-chain NAV computation.
3. **Loans Exchange** — A peer-to-peer marketplace for atomic USDC-for-NFT loan trades between investors.

All contracts implement role-based access control with a two-tier guardian/admin model and secure fund management using Safe smart accounts with delegated execution capabilities.

### Primary Objectives

- Manage payments from borrowers and distributions to investors with an on-chain auditable record that acts as the single source of truth for loan state
- Each loan is tokenized as an ERC721 NFT (symbol "LOAN"), minted to the investor on creation. The NFT owner is the canonical investor for a loan — transferring the NFT transfers investor rights (funding, withdrawals, distributions)
- Enable investors to trade loans via ERC721 NFT transfers and receive monthly payments in stablecoins
- Provide a tokenized fund vehicle (Portfolio Vault) for pooled investment in loan portfolios with fully async deposit/redemption flows and on-chain NAV derived from authoritative ledger data and configurable discount factors

Due to the complexity of regulated consumer loans paid out in fiat, interest calculation, payment schedules etc. are not implemented onchain and instead the Servicer is the trusted party that calculates offchain and submits ledger entries for the loans that then are logged and affect transfer of stablecoins to different parties.

In addition to transfering value and keeping a ledger of transactions onchain, minimal key information is stored on loans as metadata.

### Supporting Goals

- Complete audit trail of all financial movements via double-entry ledger
- Secure fund custody with hot wallet convenience for approved operations
- Clear role separation between originators, servicers, investors, and borrowers
- Atomic loan trading via exchange with USDC settlement
- On-chain NAV computation from authoritative loan ledger data with discount and portfolio adjustment factors
- Whitelisted shareholder access for regulated fund operations

### Security Model

- Two-tier admin model: guardian (timelocked) for critical operations, admin (multisig) for immediate actions
- Hot wallets execute pre-approved "trusted calls" without multisig
- High-risk operations require multisig approval from Safe owners
- Per-loan cash segregation prevents cross-loan fund usage
- Address book system requires pre-registration of all participants
- Vault operations gated by NAV freshness checks to prevent stale-price exploitation
- Shareholder whitelist enforced at the share token level for all transfers, deposits, and redemptions

## System Actors

### Protocol-Level Roles

These roles apply across all contracts via `GuardianAccessControl`:

**Guardian**: A TimelockController that holds `GUARDIAN_ROLE` across all contracts. All critical operations (unpause, role grants, rescue, contract parameter changes) require guardian approval with a publicly visible time delay. See [timelocked-tx.md](./timelocked-tx.md).

**Admin**: A multisig that holds `ADMIN_ROLE`. Provides immediate operational control for time-sensitive actions (e.g., `pause`) that cannot wait for the timelock delay. Cannot perform guardian-only operations.

### Loan-Level Parties

Each loan has four per-loan roles, assigned at creation:

**Borrower**: Receives loan funds and makes payments over time. In this protocol, the borrower address is typically an off-ramp service that converts USDC to fiat—the actual end borrower does not interact on-chain. Tare handles the on/off-ramping: borrowers receive fiat (USD) in their bank accounts and make fiat payments, while investors transact entirely in stablecoins (USDC) on-chain.

**Originator**: Creates and underwrites loans, evaluating creditworthiness and setting terms. Earns upfront origination fees. They're the creator of the loans onchain.

**Investor**: Provides capital for loans, expecting returns through interest payments. Receives principal and interest distributions for loans they own. They fund loans. The investor is the loan NFT owner — transferring the NFT transfers investor rights. The Portfolio Vault can act as an investor, holding loan NFTs on behalf of shareholders.

**Servicer**: Manages day-to-day loan operations—collecting payments, charging fees, processing modifications, and distributing funds to investors. Earns ongoing servicing fees.

### Vault Roles

These roles are specific to the Portfolio Vault, granted by the guardian:

**Portfolio Manager**: Manages the vault's loan portfolio — purchases loans via LoansExchange, collects cashflows, computes NAV, and can transfer or sell loans.

**Investor Manager**: Manages vault shareholders — approves deposits and redemptions, computes NAV, collects cashflows, and manages the shareholder whitelist.

**Whitelister**: Holds `WHITELISTER_ROLE` on the VaultShareToken. Can grant and revoke `SHAREHOLDER_ROLE`, which controls who may hold and transfer vault shares. Typically granted to the Investor Manager address.

## Security Architecture

There are several security relevant decisions we made with the smart contracts

### Guardian & Admin Roles

All contracts inherit `GuardianAccessControl` which provides a two-tier admin model:

- **Guardian** (`GUARDIAN_ROLE`): Held by a TimelockController. Controls critical operations (unpause, contract address updates, role grants/revocations, rescue functions) with a publicly visible delay. Self-administered — only guardians can grant/revoke other guardians. Self-renouncing roles is disabled (`renounceRole` always reverts) and the last remaining guardian cannot be revoked, so the contract can never be left without a guardian.
- **Admin** (`ADMIN_ROLE`): Held by a multisig. Provides immediate operational control for time-sensitive actions (e.g., `pause`). Administered by guardian (granting/revoking admin requires timelock).
- **Pauser** (`PAUSER_ROLE`): Least-privilege incident-response role that can only `pause`. Intended for 3rd-party monitoring/incident-response services. Administered by guardian; not granted at deployment.

### Pause / Unpause

All contracts support pausing via OpenZeppelin `Pausable`. Admin, guardian, or a dedicated pauser (`PAUSER_ROLE`) can pause (immediate); only guardian can unpause (timelocked). When paused, all operational functions revert — only administrative functions remain available.

### Role-Based Permissions

- Functions gated by role (originator, servicer, investor, borrower)
- Per-loan role assignment
- Admin/guardian override available

### Address Book System

- Users maintain a list of trusted parties they want to interact with
- Users can't approve a new address without a multisig transaction but interact with trusted parties via hot wallet
- Prevents arbitrary address injection attacks
- Per-entity address books (originators manage their own)
- All addresses must be pre-registered before participating in loans, preventing typo errors and unauthorized participants

See [loan_permissions.md](./loan_permissions.md) for details.

### Trusted Operations & Withdrawal Addresses Whitelist

- Each user has a Safe smart account, hot wallets are added as delegates
- Delegates can only call whitelisted functions (e.g., `accrue()`, `pay()`)
- Delegates can only withdraw funds to a whitelisted address

### Cash Segregation

- Each loan tracks its own cash balance
- Cannot spend other loans' funds
- Enforced by ledger balance checks

## Key Architectural Decisions

### Double-Entry Ledger

Every financial movement creates ledger entries transferring amounts between accounts. Each loan maintains its own set of account balances (assets, liabilities, income/expense). This provides:

- Complete audit trail of all fund movements
- Smart Contracts ensure accounting accuracy removing need for audits of books
- Per-loan cash segregation enforcement

See [ledger.md](./ledger/ledger.md) for detailed specification.

### Safe Smart Accounts

Rather than custom multisig logic, the system uses Safe smart accounts with two extensions:

- **TrustedCalls module**: Allows delegates to execute whitelisted functions
- **TrustedSpender contract**: Allows delegates to transfer to pre-approved addresses

This provides battle-tested security with operational flexibility. See [smart-accounts.md](./smart-accounts.md) for details.

### Loan NFTs & Locking

NFTs support a locking mechanism: while a loan NFT is locked, transfers are blocked and investor cashflow withdrawals are routed to the unlocker instead of the owner. The LoansExchange locks NFTs for the lifetime of a sale offer.

See [loans_nft.md](./loans_nft.md) for details.

## Operational Workflow

### Creating a Loan

```
1. Originator calls create(borrower, investor, servicer, originator, principalAmount, timestamp)
   → Validates all addresses are in originator's address book
   → Creates loan with status: Created
   → Creates ledger entry: UnfundedCommitment → BorrowerPrincipalReceivable

2. Investor calls fund(loanId, amount, timestamp, ref)
   → Pulls USDC from the investor (loan NFT owner) address to contract
   → Creates ledger entry: Cash + InvestorPrincipalPayable
   → Requires a single full-commitment amount (no partial funding)
   → On success, updates status: Created → FullyFunded

3. Originator calls disburse(loanId, netDisbursedAmount, originationFee, originationDate,
   nextDueDate, maturityDate, interestRate, expectedMonthlyPayment, timestamp, ref)
   → Sets loan terms (origination date, interest rate, expected payment)
   → Withholds origination fee: OriginatorFeePayable
   → Transfers USDC to borrower address (off-ramp)
   → Updates status: FullyFunded → Active

4. Originator calls originatorWithdraw([loanIds], timestamp, ref)
   → Automatically withdraws all available origination fees per loan
   → Sends USDC to originator in a single consolidated transfer
```

### Processing a Payment

```
1. Borrower makes USD payment (off-chain ACH)
2. Tare converts USD → USDC via on-ramp
3. Borrower calls pay(loanId, amount, timestamp, ref)
   → Deposits USDC from borrower address into contract
   → Creates entry: BorrowerPaymentClearing → Cash
4. Servicer calls applyWaterfall(loanId, miscFees, servicingFees, investorInterest, principal, nextDueDate, timestamp, ref)
   → Allocates payment across accounts
   → Creates entries for fee, interest, and principal allocation
5. Investor calls investorWithdraw([loanIds], timestamp, ref)
   → If a selected loan NFT is locked, the unlocker (not the investor) must call investorWithdraw and receives the funds
   → Sends USDC to investor
6. Servicer calls servicerWithdraw([loanIds], timestamp, ref)
   → Automatically withdraws all available servicing fees and misc fees per loan
   → All loans in the batch must share the same servicer
   → Sends USDC to servicer in a single consolidated transfer
```

### Investing via Vault (ERC-7540)

```
1. Investor calls requestDeposit(assets, controller, owner)
   → USDC transferred from owner to vault (held as pending)
   → Request recorded as pending for the controller

2. Manager calls approveDeposit(controller, assets)
   → NAV updated, shares calculated: shares = assets * totalSupply / lastNav
   → Shares minted to vault, lastNav adjusted upward

3. Investor calls deposit(assets, receiver, controller)
   → Pre-minted shares transferred from vault to receiver

4. Manager purchases loans via LoansExchange (acceptSaleOffer)
   → Vault becomes NFT owner (investor) for acquired loans
   → Cashflows accumulate in Loans contract
   → Alternatively, the manager funds Created loans directly (fundLoan / fundLoans)
     when the vault already owns the loan NFT

5. Manager calls collectCashflows(loanIds, ref)
   → Calls investorWithdraw on Loans contract (vault-owned loans are unlocked)
   → USDC flows from Loans into vault, increasing available liquidity
```

See [vault.md](./vault.md) for full specification.

### Selling/Buying Loans (Exchange)

```
1. Seller and buyer negotiate bundle and price offchain
   → Buyer provides EVM address for new investor role
   → Seller registers buyer in their address book for Roles.Investor

2. Seller calls createOffer(buyer, price, deadline, loanIds)
   → Each loan NFT locked to the exchange (seller retains ownerOf)
   → Offer stored with unique offerId

3. Buyer approves exchange to pull USDC (if price > 0)

4. Buyer calls acceptOffer(offerId)
   → USDC transferred from buyer to seller
   → Loan NFTs transferred from seller to buyer (locks cleared)
   → Buyer becomes new investor (NFT owner) for each loan
```

See [loans_exchange.md](./loans_exchange.md) for full specification.

## Admin Key

The system uses a two-tier admin model across all contracts:

**Guardian** (`GUARDIAN_ROLE`) — held by a TimelockController:

- Unpause contracts
- Update contract addresses (calculator, exchange, loansNFT, etc.)
- Grant/revoke all roles (admin, portfolio manager, investor manager)
- Rescue tokens from contracts
- Set recovery addresses

All guardian operations execute with a publicly visible time delay, giving stakeholders advance notice. See [timelocked-tx.md](./timelocked-tx.md).

**Admin** (`ADMIN_ROLE`) — held by a multisig:

- Pause contracts (immediate, no timelock)
- Override per-loan role-based permissions
- Create arbitrary ledger entries
- Manage address books
- Configure operational parameters (NAV age, computation time)

The admin account provides immediate operational control. The guardian provides ultimate authority with accountability through the timelock.

## Related Specifications

- [ledger.md](./ledger/ledger.md) - Double-entry accounting system
- [ledger_accounts.md](./ledger/ledger_accounts.md) - Chart of accounts
- [servicing.md](./servicing.md) - Loan operations and workflows
- [loan_permissions.md](./loan_permissions.md) - Role-based access control and address books
- [loans_nft.md](./loans_nft.md) - Loan NFT collection and locking mechanism
- [loan_status_lifecycle.md](./loan_status_lifecycle.md) - Loan status state machine
- [early_cancellation.md](./early_cancellation.md) - Early loan cancellation flows
- [loans_exchange.md](./loans_exchange.md) - Peer-to-peer loan NFT exchange
- [vault.md](./vault.md) - Portfolio vault (ERC-7540 tokenized fund)
- [vault-migration-runbook.md](./vault-migration-runbook.md) - Vault migration procedures
- [nav-calculator.md](./nav-calculator.md) - Loan valuation strategy for NAV computation
- [smart-accounts.md](./smart-accounts.md) - Safe smart account factory
- [trusted-calls.md](./trusted-calls.md) - Whitelisted function execution module
- [trusted-spender.md](./trusted-spender.md) - Allowance-based token transfers
- [timelocked-tx.md](./timelocked-tx.md) - Timelocked admin operations via OpenZeppelin TimelockController
- [ledger_e2e_example.md](./ledger/ledger_e2e_example.md) - End-to-end workflow example
- [ledger/irregular_scenarios/](./ledger/irregular_scenarios/) - Irregular scenario walkthroughs (ACH bounce, late fees, over-accrual, waterfall errors)
