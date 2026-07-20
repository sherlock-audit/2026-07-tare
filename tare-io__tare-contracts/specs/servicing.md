# Loan Servicing Specification

This spec defines the high-level interactions that the contracts support for loan servicing. This involves tracking loan state, processing payments from borrowers, and forwarding funds to investors and servicers using the double-entry ledger system defined in [ledger.md](ledger.md).

## Loan Servicing Workflows

### On-time payment

When a loan is paid on time, the following steps happen:

1. We calculate the interest, fees, and principal owed off-chain (or in the future with some other on-chain module)
2. The loan gets updated with the accrued but not yet paid amounts on-chain via `accrue`
3. Payments Provider deposits USDC into a pass-through account
4. The borrower (or admin) submits a transaction via `pay` that pulls funds from the `borrower` address into the Loans contract
5. Internal bookkeeping is updated with the payment allocation via `applyWaterfall`
6. Transactions are submitted to withdraw the respective amounts:
   - Investor or admin calls `investorWithdraw` to receive both principal and interest (as separate entries within one call)
   - Servicer calls `servicerWithdraw` to receive fees

## Function to Account Transfer Matrix

This table summarizes the ledger transfers created by each Loans function. Multi-entry functions create one row per possible entry.

| Function | Transfer (From -> To) | Entry Type |
| :--- | :--- | :--- |
| `create` | `ACC_UNFUNDED_COMMITMENT -> ACC_BORROWER_PRINCIPAL_RECEIVABLE` | `ENTRY_LOAN_COMMITMENT` |
| `accrue` | `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE -> ACC_BORROWER_INTEREST_RECEIVABLE` | `ENTRY_INTEREST_ACCRUAL` |
| `chargeMiscFee` | `ACC_SERVICER_MISC_FEE_PAYABLE -> ACC_BORROWER_MISC_FEE_RECEIVABLE` | `ENTRY_MISC_FEE_CHARGE` |
| `fund` | `ACC_INVESTOR_PRINCIPAL_PAYABLE -> ACC_CASH` | `ENTRY_INVESTOR_CAPITAL_RECEIVED` |
| `disburse` (origination fee withholding, if `originationFee > 0`) | `ACC_ORIGINATOR_FEE_PAYABLE -> ACC_UNFUNDED_COMMITMENT` | `ENTRY_ORIGINATOR_FEE_WITHHOLDING` |
| `disburse` (borrower disbursement) | `ACC_CASH -> ACC_UNFUNDED_COMMITMENT` | `ENTRY_DISBURSEMENT_TO_BORROWER` |
| `pay` | `ACC_BORROWER_PAYMENT_CLEARING -> ACC_CASH` | `ENTRY_BORROWER_PAYMENT` |
| `applyWaterfall` (misc fee debt clearance, if `miscFees > 0`) | `ACC_BORROWER_MISC_FEE_PAID -> ACC_BORROWER_PAYMENT_CLEARING` | `ENTRY_MISC_FEE_DEBT_CLEARANCE` |
| `applyWaterfall` (servicer fee allocation, if `servicingFees > 0`) | `ACC_SERVICER_FEE_PAYABLE -> ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE` | `ENTRY_SERVICER_FEE_ALLOCATION` |
| `applyWaterfall` (investor interest allocation, if `investorInterest > 0`) | `ACC_INVESTOR_INTEREST_PAYABLE -> ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE` | `ENTRY_INVESTOR_INTEREST_ALLOCATION` |
| `applyWaterfall` (borrower interest debt clearance, if `servicingFees + investorInterest > 0`) | `ACC_BORROWER_INTEREST_PAID -> ACC_BORROWER_PAYMENT_CLEARING` | `ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE` |
| `applyWaterfall` (principal debt clearance, if `principal > 0`) | `ACC_BORROWER_PRINCIPAL_REPAID -> ACC_BORROWER_PAYMENT_CLEARING` | `ENTRY_BORROWER_PRINCIPAL_PAYMENT` |
| `investorWithdraw` (interest, if amount > 0) | `ACC_CASH -> ACC_INVESTOR_INTEREST_PAID` | `ENTRY_INVESTOR_INTEREST_WITHDRAWAL` |
| `investorWithdraw` (principal, if amount > 0) | `ACC_CASH -> ACC_INVESTOR_PRINCIPAL_REPAID` | `ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL` |
| `servicerWithdraw` (servicing fee, if amount > 0) | `ACC_CASH -> ACC_SERVICER_FEE_PAID` | `ENTRY_SERVICER_FEE_WITHDRAWAL` |
| `servicerWithdraw` (misc fee, if amount > 0) | `ACC_CASH -> ACC_SERVICER_MISC_FEE_PAID` | `ENTRY_MISC_FEE_WITHDRAWAL` |
| `returnFunds` | `from (must be servicer-paid account) -> ACC_CASH` | caller-provided `entryType` |
| `refundBorrower` | `ACC_CASH -> toAccount (must be borrower-paid account)` | caller-provided `entryType` |
| `originatorWithdraw` (if amount > 0) | `ACC_CASH -> ACC_ORIGINATOR_FEE_PAID` | `ENTRY_ORIGINATOR_FEE_WITHDRAWAL` |

For account definitions and sign conventions, see [ledger_accounts.md](ledger/ledger_accounts.md) and [ledger.md](ledger/ledger.md).

## Data Model

We track the following attributes for loans; these attributes do not have any effects onchain as calculations are done off-chain, they are solely made available for users to consume onchain or off-chain:

**Mutable State (LoanData)** — updated during loan lifecycle:

- Loan Status (Created, FullyFunded, Active, FullyPaid, Cancelled, ChargedOff, Closed)
- Next Payment Due Date
- Maturity Date
- Last update timestamp
- Last payment date (updated when `pay` is called)

**Terms (LoanTerms)** — set at disburse, editable thereafter by the servicer or admin via `updateLoanTerms` (blocked once the loan is in a terminal status):

- Origination Date
- Interest Rate (basis points, 30/360 day-count convention)
- Expected Monthly Payment

`updateLoanTerms(loanId, originationDate, interestRate, expectedMonthlyPayment)` uses `0` as a per-field sentinel meaning "no change" (so `expectedMonthlyPayment` cannot be set to exactly `0`), stamps `updatedAt` with `block.timestamp`, and emits `LoanTermsSet` with the resulting stored values.

Note: Principal, interest, and fee balances are tracked via ledger accounts (see [ledger.md](ledger/ledger.md)).

Note: Grace Period, Delinquency buckets, and Hardship flag are tracked off-chain.

**Investor ownership** is tracked via ERC721 NFT ownership rather than a mapping. Each loan has a corresponding NFT; `loansNFT.ownerOf(loanId)` returns the current investor address. The NFT also supports ERC-5753-compatible locking — see [loan_permissions.md](loan_permissions.md) for lock semantics and [loans_exchange.md](loans_exchange.md) for how the exchange uses locks.

```solidity
enum LoanStatus {
    DoesNotExist,   // 0 - Sentinel value (used as "no change" in updateLoanData)
    Created,        // 1 - Loan created, awaiting funding
    FullyFunded,    // 2 - Fully funded, awaiting disbursement
    Active,         // 3 - Disbursed and performing
    FullyPaid,      // 4 - Borrower paid in full
    Cancelled,      // 5 - Cancelled before disbursement
    ChargedOff,     // 6 - Written off as bad debt
    Closed          // 7 - No further activity expected
}
```

Status transitions are managed by the servicer off-chain. The contract does not enforce a state machine — any status can be set to any other status via `updateLoanData`. The only enforced transitions are `Created → FullyFunded` (automatic when a valid full-commitment `fund()` call succeeds) and `FullyFunded → Active` (automatic during `disburse()`). Active servicing operations (`pay`, `accrue`, `chargeMiscFee`) require the loan to be in `Active` or `ChargedOff`. `applyWaterfall`, `returnFunds`, and `refundBorrower` additionally allow `FullyPaid` so residual payments, post-payoff corrections, and overpayment refunds can be processed after final payoff. Terminal statuses (`Cancelled`, `Closed`) also block `updateBorrower`, `updateServicer`, `updateLoanTerms`, and `fund`, but still allow withdrawals and ledger corrections.

struct LoanData {
LoanStatus status;
uint48 updatedAt;
uint48 lastPaymentDate;
uint48 nextDueDate;
uint48 maturityDate;
}

/// Loan terms, set at disburse and editable via updateLoanTerms
struct LoanTerms {
uint48 originationDate;
uint32 interestRate; // basis points (500 = 5.00%), 30/360
int128 expectedMonthlyPayment; // currency base units
}

mapping (uint64 => LoanData) public data;
mapping (uint64 => LoanTerms) public loanTerms;

// Per-loan role addresses
mapping(uint64 loanId => address borrower) public borrowers;
// Investor role = loansNFT.ownerOf(loanId) via ERC721 — no mapping
mapping(uint64 loanId => address servicer) public servicers;
mapping(uint64 loanId => address originator) public originators;

````

## Actions

### Create Loan

The `create` function creates a new loan with assigned borrower, investor, servicer, and originator addresses.

```solidity
function create(
    address borrower,
    address investor,
    address servicer,
    address originator,
    int128 principalAmount,
    uint48 timestamp
) external returns (uint64 loanId)
````

**Parameters:**

- `borrower`: Borrower address (must be non-zero)
- `investor`: Investor address (must be non-zero)
- `servicer`: Servicer address (must be non-zero)
- `originator`: Originator address (must be non-zero)
- `principalAmount`: Initial principal commitment amount (must be > 0)
- `timestamp`: Caller-provided timestamp for the initial entry and `updatedAt`

**Validation:**

- All role addresses must be non-zero
- Caller must be an admin or approved originator
- All addresses must be registered in the originator's address book with appropriate roles
- `principalAmount` must be strictly positive (reverts with `InvalidAmount` otherwise)

**Ledger Entry:**

Creates an initial ledger entry to track the loan commitment:

- From: `ACC_UNFUNDED_COMMITMENT`
- To: `ACC_BORROWER_PRINCIPAL_RECEIVABLE`
- Entry type: `ENTRY_LOAN_COMMITMENT`

**Updates:**

```solidity
data[loanId].status = LoanStatus.Created;
borrowers[loanId] = borrower;
loansNFT.mint(investor, loanId);  // Investor tracked via NFT ownership
servicers[loanId] = servicer;
originators[loanId] = originator;
data[loanId].updatedAt = timestamp;
```

**Events:**

- Emits `LoanCreated(loanId)` with the new loan identifier

### Update Borrower

The `updateBorrower` function allows updating the borrower address for a loan.

```solidity
function updateBorrower(uint64 loanId, address borrower) external onlyServicerOrAdmin
```

**Validation:**

- Loan must exist and not be Cancelled or Closed
- Borrower address must be non-zero
- Borrower must be registered in the servicer's address book
- Caller must be the loan's servicer or an admin

**Events:**

- Emits `LoanBorrowerUpdated(loanId, borrower)`

### Update Servicer

The `updateServicer` function allows updating the servicer address for a loan.

```solidity
function updateServicer(uint64 loanId, address servicer) external onlyRole(GUARDIAN_ROLE)
```

**Validation:**

- Loan must exist and not be Cancelled or Closed
- Servicer address must be non-zero
- Servicer must be an approved servicer (registered for `Roles.Servicer` in the protocol address book)
- Caller must be a guardian

**Events:**

- Emits `LoanServicerUpdated(loanId, servicer)`

### Update Loan Data

The `updateLoanData` function allows the servicer (or admin) to update loan metadata. Each parameter is optional - pass `LoanStatus.DoesNotExist` for status or `0` for dates to leave them unchanged.

```solidity
function updateLoanData(
    uint64 loanId,
    LoanStatus newStatus,
    uint48 nextDueDate,
    uint48 maturityDate,
    uint48 timestamp
) external onlyServicerOrAdmin
```

**Validation:**

- `maturityDate` must be greater than zero when provided

**Events:**

- Emits `LoanStatusUpdated(loanId, oldStatus, newStatus)` if status changed
- Emits `LoanNextDueDateUpdated(loanId, nextDueDate)` if nextDueDate changed
- Emits `LoanMaturityDateUpdated(loanId, maturityDate)` if maturityDate changed

### Accrue

The `accrue` function records the total borrower obligation (interest + fees combined) as a single ledger entry. The split into servicer fees vs investor interest happens later during `applyWaterfall`.

```solidity
function accrue(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external
```

**Validation:**

- Loan must exist and not be Cancelled or Closed
- Caller must be the loan's servicer or an admin

**Ledger Entry:**

Creates a single entry to record the accrual:

- From: `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE`
- To: `ACC_BORROWER_INTEREST_RECEIVABLE`
- Entry type: `ENTRY_INTEREST_ACCRUAL`

### Charge Misc Fee

The `chargeMiscFee` function allows the servicer to charge miscellaneous fees to the borrower (e.g. late fees, NSF fees). Unlike regular interest/fee accruals which go through the unallocated interest pool, misc fees are recorded directly as a borrower receivable and servicer payable.

```solidity
function chargeMiscFee(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external onlyServicerOrAdmin
```

**Validation:**

- Loan must exist and not be Cancelled or Closed
- Amount must be positive
- Caller must be the loan's servicer or an admin

**Ledger Entry:**

- From: `ACC_SERVICER_MISC_FEE_PAYABLE`, To: `ACC_BORROWER_MISC_FEE_RECEIVABLE`
- Entry type: `ENTRY_MISC_FEE_CHARGE`

### Fund

The `fund` function pulls investor capital to provide funding for the loan. Tokens are transferred from the loan's investor address. Funding is single-shot and must equal the full commitment.

```solidity
function fund(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external returns (uint128 entryIndex)
```

**Validation:**

- Loan status must be `Created`
- Amount must be positive
- Caller must be the current investor of the loan (`ownerOf(loanId)`) or an admin/guardian
- Locking has no effect on `fund()`
- Existing funded amount must be zero
- Amount must equal `BorrowerPrincipalReceivable` balance (exact commitment)

Admin access to `fund()` is low risk because the investor has already opted in: they granted USDC approval to the Loans contract, were registered in the originator's address book, and accepted the loan NFT. The amount is bounded by the loan commitment, so admin cannot pull more than what the investor agreed to fund. The investor can revoke their USDC approval at any time to opt out.

**Status Transition:**

On successful funding, the loan status automatically transitions from `Created` to `FullyFunded`.

**Ledger Entry:**

- From: `ACC_INVESTOR_PRINCIPAL_PAYABLE`
- To: `ACC_CASH`
- Entry type: `ENTRY_INVESTOR_CAPITAL_RECEIVED`

### Disburse

The `disburse` function transfers funded capital to the borrower, settling the unfunded commitment. Must disburse the full commitment amount. Transitions loan to `Active` and stores write-once loan terms.

```solidity
function disburse(
    uint64 loanId,
    int128 netDisbursedAmount,
    int128 originationFee,
    uint48 originationDate,
    uint48 nextDueDate,
    uint48 maturityDate,
    uint32 interestRate,
    int128 expectedMonthlyPayment,
    uint48 timestamp,
    bytes32 ref
) external returns (uint128 entryIndex)
```

**Parameters:**

- `netDisbursedAmount`: The amount sent to borrower (net of origination fee)
- `originationFee`: The fee withheld for the originator (can be 0)
- `originationDate`, `nextDueDate`, `maturityDate`: Optional loan dates (0 = not set)
- `interestRate`: Annual interest rate in basis points (500 = 5.00%), 30/360 day-count convention
- `expectedMonthlyPayment`: Expected monthly payment amount in currency base units (set once, never updated)

**Validation:**

- Loan must exist with status `FullyFunded`
- `netDisbursedAmount` must be positive, `originationFee` must be non-negative
- `netDisbursedAmount + originationFee` must equal the `UnfundedCommitment` balance
- Total investor-funded principal must equal the commitment (`InvestorPrincipalPayable == UnfundedCommitment` magnitude)
- Sufficient cash balance must exist
- Caller must be the originator or an admin

**Ledger Entries:**

1. Withhold origination fee (if > 0):
   - From: `ACC_ORIGINATOR_FEE_PAYABLE`, To: `ACC_UNFUNDED_COMMITMENT`
   - Entry type: `ENTRY_ORIGINATOR_FEE_WITHHOLDING`

2. Disburse to borrower:
   - From: `ACC_CASH`, To: `ACC_UNFUNDED_COMMITMENT`
   - Entry type: `ENTRY_DISBURSEMENT_TO_BORROWER`
   - Transfers `netDisbursedAmount` USDC to the borrower address

**Loan Terms:**

Stores `originationDate`, `interestRate`, and `expectedMonthlyPayment` in `loanTerms[loanId]`. Emits `LoanTermsSet(loanId, originationDate, interestRate, expectedMonthlyPayment)`.

### Pay

The `pay` function deposits USDC from the borrower address into the contract. The caller must be the loan's registered borrower (`borrowers[loanId]`) or an admin. Tokens are pulled from `borrowers[loanId]` regardless of caller.

```solidity
function pay(
    uint64 loanId,
    int128 amount,
    uint48 timestamp,
    bytes32 ref
) external onlyBorrowerOrAdmin returns (uint128 entryIndex)
```

**Parameters:**

- `amount`: The payment amount

**Validation:**

- Loan must exist
- Status must be `Active` or `ChargedOff` (reverts `InvalidStatus` otherwise)
- Caller must be the loan's registered borrower or an admin

**Updates:**

- Sets `lastPaymentDate` to `timestamp` and emits `LoanLastPaymentDateUpdated`

**Ledger Entry:**

- From: `ACC_BORROWER_PAYMENT_CLEARING`, To: `ACC_CASH`
- Entry type: `ENTRY_BORROWER_PAYMENT`

### Apply Waterfall

The `applyWaterfall` function allocates payment from the unallocated pool to specific payables, and clears borrower debts from the payment clearing account. It is also where the servicer rolls the next payment due date forward, since the due date update is a bookkeeping decision tied to how a payment was applied rather than to the raw cash deposit.

```solidity
function applyWaterfall(
    uint64 loanId,
    int128 miscFees,
    int128 servicingFees,
    int128 investorInterest,
    int128 principal,
    uint48 nextDueDate,
    uint48 timestamp,
    bytes32 ref
) external onlyServicerOrAdmin
```

**Parameters:**

- `miscFees`: The portion allocated to misc fees (late/NSF) — highest priority
- `servicingFees`: The portion allocated to servicer fees
- `investorInterest`: The portion allocated to investor interest
- `principal`: The portion allocated to principal repayment
- `nextDueDate`: Updated next payment due date (0 = no change)

**Updates:**

- Updates `nextDueDate` if provided (non-zero) and emits `LoanNextDueDateUpdated`

**Validation:**

- Status must not be `Created` or `FullyFunded` (reverts `InvalidStatus`)
- All amounts must be non-negative
- Total (`miscFees + servicingFees + investorInterest + principal`) must not exceed the payment clearing balance
- Total interest+fees cleared (`servicingFees + investorInterest`) must not exceed outstanding interest receivable minus already-paid interest
- `miscFees` must not exceed outstanding misc fee receivable minus already-paid misc fees (`BorrowerMiscFeeReceivable + BorrowerMiscFeePaid`)
- `principal` must not exceed outstanding principal receivable minus already-repaid principal (`BorrowerPrincipalReceivable + BorrowerPrincipalRepaid`). Any excess borrower payment stays unallocated in `ACC_BORROWER_PAYMENT_CLEARING` and can be returned via `refundBorrower`.

**Ledger Entries (up to 5, all conditional on amount > 0):**

1. Clear misc fee debt:
   - From: `ACC_BORROWER_MISC_FEE_PAID`, To: `ACC_BORROWER_PAYMENT_CLEARING`
   - Entry type: `ENTRY_MISC_FEE_DEBT_CLEARANCE`

2. Allocate servicer fee:
   - From: `ACC_SERVICER_FEE_PAYABLE`, To: `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE`
   - Entry type: `ENTRY_SERVICER_FEE_ALLOCATION`

3. Allocate investor interest:
   - From: `ACC_INVESTOR_INTEREST_PAYABLE`, To: `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE`
   - Entry type: `ENTRY_INVESTOR_INTEREST_ALLOCATION`

4. Clear borrower debt obligation:
   - From: `ACC_BORROWER_INTEREST_PAID`, To: `ACC_BORROWER_PAYMENT_CLEARING`
   - Entry type: `ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE`

5. Clear principal debt:
   - From: `ACC_BORROWER_PRINCIPAL_REPAID`, To: `ACC_BORROWER_PAYMENT_CLEARING`
   - Entry type: `ENTRY_BORROWER_PRINCIPAL_PAYMENT`

### Investor Withdraw

The `investorWithdraw` function withdraws accumulated cashflows from one or more loans in a single transaction. The same function serves both the investor (for unlocked loans) and the unlocker (for locked loans); the route is determined per call by the lock state of the loans in the batch.

```solidity
struct InvestorWithdrawalResult {
    uint64 loanId;
    int128 principal;
    int128 interest;
}

function investorWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
) external nonReentrant returns (InvestorWithdrawalResult[] memory)
```

**Behavior:**

- Automatically calculates and withdraws all available interest and principal per loan
- Returns an array of `InvestorWithdrawalResult` structs containing the actual amounts of principal vs. interest withdrawn per loan (for tax reporting purposes)
- Loans with zero payable amounts still appear in results with zero values (no entries created, no gas wasted)
- Single shared `timestamp` and `ref` for all entries
- Recipient and authorization depend on the lock state of the first loan in the batch; every other loan in the batch must match that lock state and investor

**Validation:**

- All loans must have the same investor address (NFT owner from `ownerOf(loanId)`)
- All loans in the batch must share the same lock state (all unlocked, or all locked to the same unlocker); mixing reverts with `Unauthorized`
- **Unlocked batch** (first loan's `getLocked` is `address(0)`):
  - Caller must be the investor or an admin
  - Funds are sent to the investor (NFT owner), regardless of whether the caller is the investor or an admin
- **Locked batch** (first loan's `getLocked` is non-zero):
  - Caller must be that unlocker (admin cannot call directly; admin should `unlock` first if intervention is needed)
  - Funds are sent to the unlocker (`msg.sender`)

### Investor Withdraw Ledger Entries

**Ledger Entries (up to 2 per loan, conditional on amount > 0):**

1. Interest withdrawal:
   - From: `ACC_CASH`, To: `ACC_INVESTOR_INTEREST_PAID`
   - Entry type: `ENTRY_INVESTOR_INTEREST_WITHDRAWAL`

2. Principal withdrawal:
   - From: `ACC_CASH`, To: `ACC_INVESTOR_PRINCIPAL_REPAID`
   - Entry type: `ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL`

All entries are created before the single consolidated ERC20 transfer to the recipient (investor for an unlocked batch, unlocker for a locked batch).

### Servicer Withdraw

The `servicerWithdraw` function allows the servicer to withdraw servicing fees and/or misc fees owed to them across one or more loans in a single transaction. It automatically withdraws the full outstanding amount per fee type per loan and consolidates ERC20 transfers for gas efficiency.

```solidity
struct ServicerWithdrawalResult {
    uint64 loanId;
    int128 miscFee;
    int128 servicingFee;
}

function servicerWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
) external nonReentrant returns (ServicerWithdrawalResult[] memory)
```

**Behavior:**

- All loans must have the same servicer address
- Caller must be the servicer or admin for all loans in the batch
- Automatically withdraws all available servicing fees and misc fees per loan
- Returns an array of `ServicerWithdrawalResult` structs with amounts per loan
- Loans with zero amounts (both `miscFee == 0` and `servicingFee == 0`) are skipped silently (no entries created, still appear in results)
- Single shared `timestamp` and `ref` for all entries

**Ledger Entries (up to 2 per loan, conditional on amount > 0):**

1. Servicing fee withdrawal:
   - From: `ACC_CASH`, To: `ACC_SERVICER_FEE_PAID`
   - Entry type: `ENTRY_SERVICER_FEE_WITHDRAWAL`

2. Misc fee withdrawal:
   - From: `ACC_CASH`, To: `ACC_SERVICER_MISC_FEE_PAID`
   - Entry type: `ENTRY_MISC_FEE_WITHDRAWAL`

All entries are created before the single consolidated ERC20 transfer to the servicer.

### Return Funds

The `returnFunds` function allows the servicer to return previously withdrawn funds back into a loan's cash account. This is the inverse of `servicerWithdraw` and is used for error corrections such as waterfall misallocations, late fee waivers after distribution, or over-accrual refunds.

```solidity
function returnFunds(
    uint64 loanId,
    uint8 from,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
) external nonReentrant loanExists(loanId) returns (uint128 entryIndex)
```

**Behavior:**

- Pulls ERC20 tokens from msg.sender (the servicer or admin) into the contract
- Creates a deposit entry crediting the loan's Cash account
- Only servicer-paid accounts are allowed as `from`: `ACC_SERVICER_FEE_PAID`, `ACC_SERVICER_MISC_FEE_PAID` or `ACC_SERVICER_ADJUSTMENT`
- For `ACC_SERVICER_FEE_PAID` and `ACC_SERVICER_MISC_FEE_PAID`, `amount` is bounded by the current account balance (reverts `InvalidAccount` if `amount > balance`)
- `ACC_SERVICER_ADJUSTMENT` is unbounded by design (discretionary servicer credit)
- Caller provides `entryType` to distinguish the reason (e.g., `ENTRY_SERVICER_FUND_RETURN`)
- Single-loan operation (not batched) since error corrections are infrequent

**Access Control:** Servicer (for the given loan) or admin.

**Ledger Entry:**

- From: `from` (caller-specified servicer-paid account), To: `ACC_CASH`
- Entry type: caller-provided (e.g., `ENTRY_SERVICER_FUND_RETURN`)

### Refund Borrower

The `refundBorrower` function allows the servicer to send cash from the loan back to the borrower. This is used when the borrower has overpaid — either against already-settled interest/misc fees, or as unallocated surplus left in `ACC_BORROWER_PAYMENT_CLEARING` after the waterfall caps allocations against outstanding debt. It is typically preceded by a `returnFunds` call (if the servicer needs to inject cash) or uses existing loan cash.

**Behavior:**

- Transfers ERC20 tokens from the contract to the borrower address (`borrowers[loanId]`)
- Creates a withdrawal entry debiting the loan's Cash account
- Allowed `toAccount` values: `ACC_BORROWER_INTEREST_PAID`, `ACC_BORROWER_MISC_FEE_PAID`, or `ACC_BORROWER_PAYMENT_CLEARING`
- Refund amount is capped by the net over-payment held in the chosen account, so the borrower can never be refunded more than they have genuinely overpaid:
  - For `ACC_BORROWER_INTEREST_PAID`: `−PAID − RECEIVABLE` — paid amount minus any still-outstanding interest receivable. A subsequent over-accrual reversal (e.g. `ENTRY_INTEREST_REVERSAL`) is required to create a refundable delta when the borrower paid exactly what was accrued.
  - For `ACC_BORROWER_MISC_FEE_PAID`: `−PAID − RECEIVABLE` (same shape, against misc-fee accounts).
  - For `ACC_BORROWER_PAYMENT_CLEARING`: `−CLEARING` — the unallocated surplus left after the waterfall.
- Per-loan cash balance check prevents spending cash belonging to other loans

**Overpayment lifecycle:**

1. `receiveBorrowerPayment` — borrower's funds land in `ACC_BORROWER_PAYMENT_CLEARING`.
2. `applyWaterfall` — distributes against valid debts. Principal, interest+fees, and misc-fee allocations are each capped against the corresponding outstanding receivable. Any unallocated remainder stays in `ACC_BORROWER_PAYMENT_CLEARING` as a (negative) liability to the borrower.
3. `refundBorrower(loanId, ACC_BORROWER_PAYMENT_CLEARING, surplus, ...)` — returns the surplus to the borrower in cash. Clearing settles back to zero.

**Access Control:** Servicer (for the given loan) or admin.

**Ledger Entry:**

- From: `ACC_CASH`, To: `toAccount` (caller-specified borrower-paid or clearing account)
- Entry type: caller-provided (e.g., `ENTRY_BORROWER_REFUND`)

### Originator Withdraw

The `originatorWithdraw` function allows the originator to withdraw origination fees across one or more loans in a single transaction. It automatically withdraws the full outstanding amount per loan and consolidates ERC20 transfers.

```solidity
struct OriginatorWithdrawalResult {
    uint64 loanId;
    int128 amount;
}

function originatorWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
) external nonReentrant returns (OriginatorWithdrawalResult[] memory)
```

**Behavior:**

- Automatically calculates and withdraws all available origination fees to withdraw per loan
- Returns an array of `OriginatorWithdrawalResult` structs containing the actual amount withdrawn per loan
- Loans with zero payable amounts still appear in results with zero values (no entries created)
- Single shared `timestamp` and `ref` for all entries

**Validation:**

- All loans must have the same originator address
- Caller must be the originator or admin for all loans in the batch
- Net payable per loan: `OriginatorFeePayable - OriginatorFeePaid` (only withdraws if > 0)

**Ledger Entries (1 per loan, conditional on amount > 0):**

1. Originator fee withdrawal:
   - From: `ACC_CASH`, To: `ACC_ORIGINATOR_FEE_PAID`
   - Entry type: `ENTRY_ORIGINATOR_FEE_WITHDRAWAL`

All entries are created before a single consolidated USDC transfer to the originator address.

## Events Emitted

All functions that create ledger entries emit `EntryCreated` events. This enables comprehensive off-chain tracking of all loan operations.

### Event Structure

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

The `updatedFromBalance` and `updatedToBalance` fields provide the resulting balances after the entry is applied, enabling off-chain systems to track account states without additional RPC calls.

### Event Emissions by Function

- **`accrue()`** emits `EntryCreated` with `ENTRY_INTEREST_ACCRUAL`
- **`chargeMiscFee()`** emits `EntryCreated` with `ENTRY_MISC_FEE_CHARGE`
- **`pay()`** emits `EntryCreated` with `ENTRY_BORROWER_PAYMENT`, and `LoanLastPaymentDateUpdated`
- **`applyWaterfall()`** emits up to 5 `EntryCreated` events:
  - `ENTRY_MISC_FEE_DEBT_CLEARANCE` (if miscFees > 0)
  - `ENTRY_SERVICER_FEE_ALLOCATION` (if servicingFees > 0)
  - `ENTRY_INVESTOR_INTEREST_ALLOCATION` (if investorInterest > 0)
  - `ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE` (if totalInterestAndFees > 0)
  - `ENTRY_BORROWER_PRINCIPAL_PAYMENT` (if principal > 0)
- **`investorWithdraw()`** emits up to 2 `EntryCreated` events:
  - `ENTRY_INVESTOR_INTEREST_WITHDRAWAL` (if interest > 0)
  - `ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL` (if principal > 0)
- **`originatorWithdraw()`** emits 1 `EntryCreated` event per loan:
  - `ENTRY_ORIGINATOR_FEE_WITHDRAWAL` (if amount > 0)
- **`servicerWithdraw()`** emits up to 2 `EntryCreated` events per loan:
  - `ENTRY_SERVICER_FEE_WITHDRAWAL` (if servicingFee > 0)
  - `ENTRY_MISC_FEE_WITHDRAWAL` (if miscFee > 0)
- **`returnFunds()`** emits 1 `EntryCreated` event with caller-provided entry type
- **`disburse()`** emits `LoanTermsSet` with `originationDate`, `interestRate`, `expectedMonthlyPayment`

**Note:** Entry types are `uint16` constants, allowing flexibility to add new types without contract changes.
