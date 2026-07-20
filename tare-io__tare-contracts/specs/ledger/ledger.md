# Loan Ledger Specification

## Overview

The Loans contract implements a double-entry accounting system for tracking all financial movements related to each loan. For each loan the contract maintains balances of the different accounts. We use `uint8` constants for defining accounts and therefore support a maximum of 256 accounts per loan. Each transaction debits and credits an account.

## Core Principles

### Transfer-Based Accounting

- Each entry transfers an amount from one account to another
- From account balance decreases, To account balance increases
- We do not enforce balancing of accounts onchain

### Sign Convention

Our approach differs from regular accounting convention: rather than using traditional "debit" and "credit" terminology with different rules per account type, we use simple addition and subtraction uniformly across all accounts.

Traditional accounting requires knowing whether an account is "debit-normal" or "credit-normal" to determine if a debit increases or decreases the balance. Instead, we treat all accounts uniformly:

- **From account**: balance decreases (subtraction)
- **To account**: balance increases (addition)

The rule for mapping traditional debit/credit to from/to:

| Traditional | Maps to | Effect            | Result                                                            |
| ----------- | ------- | ----------------- | ----------------------------------------------------------------- |
| Debit       | `to`    | balance += amount | Debit-normal accounts (Assets/Expenses) become more positive      |
| Credit      | `from`  | balance -= amount | Credit-normal accounts (Liabilities/Revenue) become more negative |

To summarize:

- Assets and Expenses usually carry a **positive** balance;
- Liabilities and Revenue usually carry a **negative** balance.

In our system, a debit (+) of a debit-normal account pushes its balance towards its expected direction (more positive). Similarly, a credit (-) of a credit-normal account pushes its balance towards its expected direction (more negative).

This simplifies all operations to straightforward additions while maintaining the accounting equation.
For conventional reporting which has to adhere to normal accounting conventions, use `getLoanAccountBalanceNormalized()` which flips the sign for normally-negative accounts.

For more details, see Beancount's explanation of this approach: [https://beancount.github.io/docs/the_double_entry_counting_method.html#credits-debits](https://beancount.github.io/docs/the_double_entry_counting_method.html#credits-debits)

#### Example A: Both Accounts Increase (Accrue Borrower Obligation)

_Scenario_: Accrue $100 total borrower obligation (interest + fees combined).

**Traditional accounting**:

Debit: InterestReceivable $100
Credit: UnallocatedBorrowerInterestPayable $100

- InterestReceivable (Asset, debit-normal) — debited, so **increases**
- UnallocatedBorrowerInterestPayable (Liability, credit-normal) — credited, so **increases**

**Our implementation**: `from=UnallocatedBorrowerInterestPayable → to=InterestReceivable`, amount=100

- UnallocatedBorrowerInterestPayable: `0 − 100 = −100` (liability carries negative balance ✓)
- InterestReceivable: `0 + 100 = +100` (asset carries positive balance ✓)

### Account Structure

See [ledger_accounts.md](ledger_accounts.md) for the complete chart of accounts with descriptions and debit/credit normal conventions.

## Example Entries

- **Borrower Payment**: From=BorrowerPaymentClearing, To=Cash (deposit pulls tokens)
- **Accrue borrower obligation**: From=UnallocatedBorrowerInterestPayable, To=InterestReceivable
- **Allocate servicer fee**: From=ServicerFeePayable, To=UnallocatedBorrowerInterestPayable
- **Allocate investor interest**: From=InvestorInterestPayable, To=UnallocatedBorrowerInterestPayable
- **Clear interest debt**: From=BorrowerInterestPaid, To=BorrowerPaymentClearing
- **Payout To Servicer**: From=Cash, To=ServicerFeePaid (withdrawal)
- **Principal Payout To Investor**: From=Cash, To=InvestorPrincipalRepaid (withdrawal)

## Data Structure

### Accounts

We only need to support a standard set of accounts for all loans. Accounts are defined as `uint8` constants with an `ACC_` prefix. This limits the number of accounts to 256 (a limit we will not reach).

For each account in a loan we keep track of the balance in a mapping.

See [ledger_accounts.md](ledger_accounts.md) for the complete account constants definition with all account types.

```solidity
// Loan-specific balance tracking using concatenated key
// Key of the mapping is (uint64 loanId || uint8 account)
mapping(uint72 => int128) public accountBalances;
```

### Entries

Entries keep track of amount, timestamp, an external reference, a debit and credit account, and the type of transaction.

The `entryType` field is a `uint16` value, allowing for up to 65,535 different entry types without requiring contract changes. This means that although some of the first entry types are defined as constants in the smart contracts, off-chain callers have the flexibility to pass a new entry type, not defined in the smart contract, while using the same data structure.

```solidity
struct Entry {
    int128 amount;         // Transfer amount
    uint48 timestamp;      // Unix timestamp
    uint64 loanId;         // Supports up to 18 quintillion loans
    uint8 from;            // Source account (balance decreases)
    uint8 to;              // Destination account (balance increases)
    uint16 entryType;      // Type of transaction
    bytes32 ref;           // External reference
}

// Entry storage using concatenated loanId + incrementing counter
mapping(uint128 => Entry) public entries;
```

#### Autoincrementing Entry IDs

We keep track of a struct for each entry. The entry ID is created by concatenating `loanId` and `entryCount`. A helper function increments the entry index to be used in functions creating new entries.

```solidity
// mapping (loanID => entryCount);
mapping(uint64 => uint64) public entryCount;

function _createNextEntryIndex(uint64 loanId) internal returns (uint128) {
    uint64 entryNumber = ++entryCount[loanId];
    return uint128(loanId) << 64 | uint128(entryNumber);
}
```

## Bookkeeping with Entry creation

For all functions that create entries, we ensure:

- From and To accounts must be different
- Amounts must be positive and non-zero

### Internal Entry Creation (Batch)

The `createLedgerEntries` function allows the servicer or admin to create multiple internal-only ledger entries in a single transaction. These entries do not trigger any token transfers and are not allowed to modify the Cash account balance. This is used for corrections, reversals, and reclassifications.

The function takes an array of `LedgerEntryInput` structs, each specifying a from/to account pair, amount, entry type, and reference. All entries share the same timestamp.

**Validation per entry:**
- Neither `from` nor `to` may be `ACC_CASH`
- `from` and `to` must be different
- `amount` must be positive

**Access Control:** Servicer (for the given loan) or admin.

**Not blocked when Cancelled or Closed** — to allow post-cancellation ledger corrections.

### Functions moving "Cash"

#### Deposits

Deposits pull tokens into the Loans contract via `currency.safeTransferFrom(addr, this, amount)`. There is no generic public `deposit` function; instead, deposits happen through purpose-specific functions:

- **`pay`** — pulls tokens from the borrower address, credits `BorrowerPaymentClearing → Cash`
- **`fund`** — pulls tokens from the investor address, credits `InvestorPrincipalPayable → Cash`
- **`returnFunds`** — pulls tokens from the servicer (msg.sender), credits a servicer-paid account → `Cash`

See [servicing.md](servicing.md) for full function signatures and validation rules.

#### Withdrawals

Purpose-specific withdrawal functions exist, allowing for one or more loans:

- **`investorWithdraw`** — withdraws principal and/or interest to the investor
- **`servicerWithdraw`** — withdraws misc fees / servicing fees to the servicer
- **`originatorWithdraw`** — withdraws origination fees to the originator
- **`refundBorrower`** — withdraws cash to the borrower address (refunds against `ACC_BORROWER_INTEREST_PAID`, `ACC_BORROWER_MISC_FEE_PAID`, or surplus held in `ACC_BORROWER_PAYMENT_CLEARING`)

See [servicing.md](servicing.md) for full function signatures and validation rules.

## Events

The contract emits comprehensive events to track all ledger operations for off-chain monitoring and analysis.

### EntryCreated Event

Emitted whenever a new ledger entry is created through any of the entry creation functions.

```solidity
event EntryCreated(
    uint128 indexed entryIndex,
    uint8 indexed from,
    uint8 to,
    int128 amount,
    int128 updatedFromBalance,
    int128 updatedToBalance,
    uint16 entryType,
    bytes32 ref
);
```

**Parameters:**

- `entryIndex`: Unique identifier for the entry (loanId concatenated with entry number)
- `from`: Source account (balance decreases)
- `to`: Destination account (balance increases)
- `amount`: Transfer amount (always positive)
- `updatedFromBalance`: Balance of the `from` account after this entry is applied
- `updatedToBalance`: Balance of the `to` account after this entry is applied
- `entryType`: Type of transaction (borrower payment, fee charge etc..)
- `ref`: External reference for tracking

**Note:** The loanId can be extracted from the entryIndex (upper 64 bits) if needed for filtering or analysis.

**Usage:**

- All entry creation functions (`createInternalEntry`, `_deposit`, and `_withdraw`) emit this event
- High-level functions (`accrue`, `pay`, `applyWaterfall`, `investorWithdraw`, `servicerWithdraw`) emit this event for each ledger entry they create
- Enables off-chain systems to track all financial movements in real-time
- Supports filtering by loan, account types, or transaction types

## Access Control

- Inherits from `LoansAuth` role system
- Admin-gated functions use the `onlyAdmin` modifier (see `Auth`)
- Read functions are public

### Cash Account Protection

The Loans contract holds cash for multiple loans in a single token balance. Each loan maintains its own Cash account balance to track how much of the total contract balance belongs to that specific loan. To prevent loans from spending cash that belongs to other loans, the system enforces per-loan cash balance limits.

**Implementation**: The `_updateBalances` function validates that any operation reducing a loan's Cash account balance does not result in a negative balance:

```solidity
if (from == ACC_CASH) {
    require(accountBalances[fromKey] >= amount, InsufficientCashBalance());
}
```

This safeguard ensures that each loan can only spend cash that it has actually received, preventing cross-loan cash usage and maintaining proper segregation of funds.

### System Invariants

1. Sum of all account balances per loan equals zero (accounting equation)
2. Asset accounts have positive balances or zero per loan
3. Liability accounts have negative balances or zero per loan
4. **Each loan's Cash account balance must never be negative (≥ 0)**
5. **Loans cannot spend cash belonging to other loans**
6. **Total outflows from a loan's Cash cannot exceed total inflows to that loan's Cash**

### Reentrancy Protection

- All state-changing functions use reentrancy guards
- External calls limited to trusted contracts only

### Overflow Protection

- Validate input ranges before processing

### Access Validation

- Verify loan ownership before creating entries
- Validate withdrawal destinations (servicer, investor, etc.)
- Ensure only authorized contracts can modify ledger
- Protect balance updates to maintain consistency

## Testing

### Capture an incoming payment from a borrower

1. Mint 1000 MockUSDC into test account
2. Create a loan
3. Deposit 1000 USDC into the Loan
4. Create internal transaction with 100 USDC in servicing fees
5. Create internal transaction noting 100 USDC in fees paid
6. Create internal transaction noting 800 USDC in principal repaid
7. Pay out fees to a fee account
8. Pay out principal to investor account
9. Pay out interest to investor account (same account, separate transaction)

### Unit Tests

- Validate balance transfer mechanics
- Test account balance calculations
- Verify entry creation and validation

### Integration Tests

- Test synchronization with Loans contract
- Validate end-to-end entry flows
- Test batch operation performance

### Invariant Tests

- Continuous loan balance verification
- Account type constraint validation per loan
- Zero-sum balance validation per loan
