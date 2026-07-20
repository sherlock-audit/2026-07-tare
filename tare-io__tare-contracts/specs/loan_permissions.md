# Loan Permissioning Specification (WiP)

## Context

**Overall Goal: Keeping Funds Secure and Transacting from the Tare Backend without requiring frequent Multisig Transactions**

Our approach to keeping funds secure is by generally distinguishing between two different actions within our system: trusted actions and risky actions. A trusted action for example is to charge a late fee to the borrower or send money to a known offramp account. A risky action is adding a new withdrawal address to send USDC to and then sending USDC there. The Tare contracts are designed so that we can easily separate these transactions and use hot wallets for trusted transactions without any chance of them doing any risky transactions. Below describes this architecture.

We will want to use a Safe for every user that interacts with our system and create modules for the Safe that allow us to customize them. See the https://docs.safe.global/advanced/smart-account-modules for more information on how to build them.For each user we deploy a standard Safe with an Admin Account (at a custodian or hardware wallet). The keys marked in blue are hosted on a hardware wallet or with a custodian and are considered cold storage. They’re not used in the day to day transactions.

This is defined in [specs/smart-accounts.md](./smart-accounts.md)

In addition to the regular multisig signers, there are two modules on the Safe that allow a less trustworthy key (our Tare Hot Proxy) to do interactions on behalf of the user:

### Trusted Caller Safe Plugin

The Whitelisted Caller Safe plugin maintains a list of trusted function calls that can not lead to any unsafe results in the Tare LMS. These calls can be called by the Tare Hot Wallet (through the Tare Hot Proxy). Any other call will require a multisig transaction that requires manual actions by owners of the signing keys.

This is defined in [specs/trusted-calls.md](./trusted-calls.md)

### Trusted Withdrawals Safe Plugin

This module keeps track of addresses that are “trusted” by the user and thus allow withdrawals to from the Safe without a multisig transaction. As an example originators would configure their fiat offramp wallet as a trusted withdrawal address.

This is defined in [specs/trusted-spender.md](./trusted-spender.md)

### Roles & Permissions

The permissioned actions are defined below and should be implemented across smart contracts and offchain backend. The individual permissions are described below:

## Permissioned Actions

| Action                               | Description/Comments                                                                                                      | Who can do it                                  |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| **Loan Creation & Funding**          |                                                                                                                           |                                                |
| Create a loan                        | Creates loan onchain (caller must be the named originator; addresses must be pre-registered in originator's address book) | Originator (own loans only) / Admin / Guardian |
| Fund loan                            | Pull funds from specified address                                                                                         | Investor                                       |
| Cancel loan pre-funding              | Cancel loan before any funds are disbursed                                                                                | Servicer                                       |
| **Disbursement**                     |                                                                                                                           |                                                |
| Add/remove borrower payout addresses | Manage allowed payout addresses                                                                                           | Originator, Servicer                           |
| Pay borrower                         | Trigger disbursement to borrower                                                                                          | Originator                                     |
| **Access Control**                   |                                                                                                                           |                                                |
| Edit servicing permissions           | Change the servicer on a loan                                                                                             | Guardian                                       |
| Transfer ownership                   | Transfer the loan to new investor via ERC721 transfer (`transferFrom`/`safeTransferFrom`)                                 | Current Investor (or approved operator)        |
| **Loan Terms**                       |                                                                                                                           |                                                |
| Update loan details                  | Modify expected maturity, delinquency, etc.                                                                               | Servicer                                       |
| **Fees & Interest**                  |                                                                                                                           |                                                |
| Accrue interest                      | Calculate and add interest charges                                                                                        | Servicer                                       |
| Charge fees                          | Add fees (late fees, modification fees, etc.)                                                                             | Servicer                                       |
| Record payments                      | Log borrower payments (principal, interest, fees)                                                                         | Borrower / Admin                               |
| Record external payments             | Track payments made outside the contract system                                                                           | Servicer                                       |
| **Third-parties Payouts**            |                                                                                                                           |                                                |
| Trigger investor payout              | Investor withdraws principal and interest                                                                                 | Investor                                       |
| Trigger originator payout            | Originator withdraws origination fees                                                                                     | Originator                                     |
| Trigger servicer payout              | Servicer withdraws servicing fees                                                                                         | Servicer                                       |
| **Loan Lifecycle Events**            |                                                                                                                           |                                                |
| Write off loan                       | Mark loan value to $0 (bad debt)                                                                                          | Servicer                                       |
| Recover funds                        | Recover funds on a loan                                                                                                   | Servicer                                       |
| Update loan status                   | Change status (active/fully-paid/cancelled/charged-off/closed)                                                            | Servicer                                       |
| **Address Management**               |                                                                                                                           |                                                |
| Register address for role            | Add address to entity's address book for a role                                                                           | Book Owner, Admin                              |
| Unregister address                   | Remove address from entity's address book                                                                                 | Book Owner, Admin                              |

## Roles

For each loan we track 4 roles:

- Borrower
- Originator
- Investor
- Servicer

In addition there is one universal role: being an admin grants permissions across all loans and can perform any of these actions. This is used by Tare as a last resort measure.

## RBAC (Role-Based Access Control)

The roles defined above are declared and identified with an enum:

```solidity
enum Roles {
    Borrower,       // 0
    Originator,     // 1
    Investor,       // 2
    Servicer        // 3
}
```

### Querying a role

Each loan stores role ownership as direct addresses in per-loan mappings, except for the investor role which is stored as the ERC721 token owner — `ownerOf(loanId)` returns the investor address.

Loan NFTs also support ERC-5753-compatible locking. A lock does not change `ownerOf(loanId)`, but it is protocol-significant:

- `fund()` requires the caller to be the current NFT owner or an admin/guardian. Locking has no effect on `fund()`.
- `investorWithdraw()` is a single function that handles both **unlocked** and **locked** loans. The route is determined per call by the lock state of the loans in the batch:
  - **Unlocked batch**: callable by the investor (NFT owner) or admin. Funds go to the investor.
  - **Locked batch**: callable only by the current unlocker (`msg.sender == getLocked(loanId)`). Funds go to the unlocker, not the investor.
  - All loans in a batch must share the same lock state and the same investor; mixing reverts with `Unauthorized`.

This split prevents batch-mixing attacks where locked and unlocked loans share a single recipient, and isolates the trust boundary: locking a loan to a contract grants that contract control over cashflow withdrawal.

```solidity
mapping(uint64 loanId => address borrower) public borrowers;
mapping(uint64 loanId => address originator) public originators;
// Investor role = ownerOf(loanId) via ERC721
mapping(uint64 loanId => address servicer) public servicers;
```

Thus, verifying if a caller has a specific role for a loan involves comparing the role address for that `loanId` with the caller's address.

```solidity
function _requireCallerOrAdmin(address addr) private view {
    require(addr == msg.sender || _isAdminOrGuardian(msg.sender), Unauthorized());
}
```

For investor-owner actions, role lookup differs per function:

- `fund()`: caller must be the NFT owner or admin/guardian
- `investorWithdraw()` on an unlocked batch: caller must be the NFT owner or admin
- `investorWithdraw()` on a locked batch: caller must be the unlocker; every loan must be locked to that caller

### Gating functions

Modifiers are used to add permissioning to any function:

- `only<Role>OrAdmin(uint64 loanId)`: Only the specified role for the loan, or an admin, is allowed to call the function

Example:

```solidity
function pay(
    uint64 loanId,
    int128 amount,
    uint48 timestamp,
    bytes32 ref
) external onlyBorrowerOrAdmin(loanId) nonReentrant loanExists(loanId)
```

### Status-Based Restrictions

Some functions are blocked when a loan is in a terminal state (`Cancelled` or `Closed`). This prevents modifications to loans that should no longer have activity.

**Functions blocked when Cancelled or Closed:**

- fund
- accrue
- chargeMiscFee
- pay
- updateBorrower
- updateServicer

**Functions intentionally NOT blocked** (to allow post-cancellation recovery/cleanup):

- `updateLoanData` — Must allow transitioning to/from terminal states
- `createLedgerEntries` — Servicer/admin ledger corrections (internal entries only)
- `refundBorrower` — Servicer/admin refund to borrower (interest, misc fee, or unallocated payment clearing overpayments)
- `originatorWithdraw` — May need to distribute remaining funds

### Pause Restrictions

The Loans contract inherits OZ `Pausable` via `GuardianAccessControl`. When paused, all operational functions revert with `EnforcedPause()`. Admin, guardian, or pauser (`PAUSER_ROLE`, a least-privilege pause-only role administered by the guardian) can pause; only guardian can unpause.

**Functions blocked when paused** (`whenNotPaused`):

- `create` — Loan origination
- `fund` — Investor funding
- `disburse` — Disbursement to borrower
- `accrue` — Interest/fee accrual
- `chargeMiscFee` — Miscellaneous fee charges
- `pay` — Payment recording with token transfer
- `applyWaterfall` — Payment allocation
- `servicerWithdraw` — Servicer fee withdrawal
- `investorWithdraw` — Investor or unlocker principal/interest withdrawal
- `originatorWithdraw` — Originator fee withdrawal
- `refundBorrower` — Refund overpayments to borrower
- `returnFunds` — Servicer returning overpaid fees to loan
- `updateBorrower` — Borrower role changes
- `updateServicer` — Servicer role changes
- `createLedgerEntries` — Internal bookkeeping entries (no token movement)
- `rescueERC20Tokens` — ERC20 recovery (inherited from `Rescuable`)
- `rescueERC721Tokens` — ERC721 recovery (inherited from `Rescuable`)
- `pause` — Pausing the contract (admin, guardian, or pauser; reverts if already paused)

**Functions intentionally NOT paused** (administrative or corrective operations):

- `updateLoanData` — Status transitions (e.g. marking charged-off) needed during pause
- `setLoansNFT` — Initial contract wiring
- `setRecoveryAddress` — Setting rescue destination
- `setRoleAdmin` — Role hierarchy configuration
- `grantRole` / `revokeRole` — OZ AccessControl role management (`renounceRole` is disabled and always reverts)
- `approveOriginator` / `revokeOriginator` — Originator approval management
- `approveServicer` / `revokeServicer` — Servicer approval management
- `registerAddress` / `unregisterAddress` — Address book management
- `registerAddressOnBehalfOf` / `unregisterAddressOnBehalfOf` — Admin address book management

**Only callable when paused**:

- `unpause` — Unpausing the contract (guardian only)

## Address Book System

### Overview

To enhance security, the contract implements an address book system that requires addresses to be pre-registered before they can participate in loans. This prevents arbitrary addresses from being passed to loan creation or update functions.

### Address Registration

Each entity (originator, servicer) maintains their own address book where they can register addresses for specific roles. Registration is required before addresses can be used in loan operations.

**Functions for Address Management:**

```solidity
// Register an address for a specific role in caller's address book
function registerAddress(Roles role, address addr) external;

// Remove role assignment from address in caller's address book
function unregisterAddress(Roles role, address addr) external;

// Check if address is registered for role in a book owner's address book
function isRegisteredForRole(address bookOwner, Roles role, address addr) external view returns (bool);
```

### Validation Rules

1. **Loan Creation**: All addresses (borrower, investor, servicer) must be registered in the **originator's** address book with appropriate roles before calling `create()`
2. **Borrower Updates**: When updating a borrower via `updateBorrower()`, the new borrower address must be registered in the **servicer's** address book
3. **Address Book Ownership**: Each entity manages their own address book independently

```solidity
// Loan creation validates against originator's address book
require(isRegisteredForRole(originator, Roles.Borrower, borrower), UnregisteredAddress(borrower));
require(isRegisteredForRole(originator, Roles.Investor, investor), UnregisteredAddress(investor));
require(isRegisteredForRole(originator, Roles.Servicer, servicer), UnregisteredAddress(servicer));

// Borrower updates validate against servicer's address book
require(isRegisteredForRole(servicers[loanId], Roles.Borrower, newBorrower), UnregisteredAddress(newBorrower));
```

### Bitmask Storage

Address books use bitmask storage for efficient multi-role support. Each address can be registered for multiple roles using a single storage slot:

```solidity
mapping(address bookOwner => mapping(address grantee => uint256 roleBitmask)) public addressBook;
```

### Canonical Address Book

The contract itself (`address(this)`) serves as the canonical address book for protocol-level approvals:

- Approved originators are registered in the canonical book with `Roles.Originator`
- Approved servicers are registered in the canonical book with `Roles.Servicer`

```solidity
function approveOriginator(address user) external onlyRole(GUARDIAN_ROLE);
function revokeOriginator(address user) external; // requires admin or guardian
function approveServicer(address user) external onlyRole(GUARDIAN_ROLE);
function revokeServicer(address user) external; // requires admin or guardian
```

### Events

```solidity
event AddressRegistered(address indexed bookOwner, Roles role, address indexed addr);
event AddressUnregistered(address indexed bookOwner, Roles role, address indexed addr);
event OriginatorApproved(address indexed user);
event OriginatorRevoked(address indexed user);
event ServicerApproved(address indexed user);
event ServicerRevoked(address indexed user);
```
