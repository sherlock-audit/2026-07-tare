# Early Cancellation Specification

This document describes the operational flow when a borrower returns a recently disbursed loan during the **5-day grace period** that follows disbursement. Within this window the borrower may cancel the loan at no cost to themselves: they return only the **net amount they actually received** (i.e. `netDisbursedAmount`, principal minus the origination fee). The originator forfeits the fee, and the investor is made whole for the full principal.

The 5-day window is an off-chain policy: there is no on-chain timestamp check that enforces it, and there is no dedicated cancellation entry point. The flow is composed from existing functions and the eligibility window is verified off-chain by the servicer before authorizing the cancellation.

## Scope

Applies to a loan in status `Active` (post-`disburse`) and within 5 days of disbursement.

End-state requirements:

- **Borrower** is net zero: receives `net = netDisbursedAmount` at disbursement, returns `net` at cancellation. No interest, fees, or misc charges collected.
- **Investor** is net zero: contributed `P = principal` at funding, receives `P` back at cancellation.
- **Originator** forfeits the withheld origination fee for cancelled loans. Receives nothing.
- **Servicer** receives nothing (no servicing fees due).

## Preconditions

- `data[loanId].status == LoanStatus.Active`
- `block.timestamp <= loanTerms[loanId].originationDate + 5 days` (enforced off-chain by the servicer)
- `ACC_BORROWER_PRINCIPAL_RECEIVABLE` equals `+P` (no partial principal repayments)
- `ACC_INVESTOR_PRINCIPAL_PAYABLE` equals `-P`
- `ACC_ORIGINATOR_FEE_PAYABLE` equals `-fee` (originator fee not yet withdrawn). If the originator already called `originatorWithdraw`, see [Out of Scope](#out-of-scope--future-work).
- Borrower has approved the contract for `net` units of `currency`

## Ledger Reversal Convention

Reversals in this protocol are posted as new ledger entries with `from`/`to` swapped from the original entry. `_createInternalEntry` requires `amount > 0`, so negative-amount reversals are not possible. Reversals are authored by the servicer via `createLedgerEntries`.

## Scenario A — Canonical cancellation (no accrual)

The standard case. Servicer never called `accrue` for the loan, and no misc fees were charged.

Where `P = principal`, `fee = originationFee`, `net = netDisbursedAmount = P - fee`.

### Flow

1. **Borrower** calls `pay(loanId, net, timestamp, ref)`. Pulls `net` from the borrower's wallet into the contract. `ACC_CASH` becomes `+P` (was `+fee` from the withheld origination fee at disbursement). `ACC_BORROWER_PAYMENT_CLEARING` becomes `-net`.

2. **Servicer** calls `createLedgerEntries(loanId, timestamp, entries)` to redistribute the held origination fee toward the investor and to remove the fee portion from the borrower's outstanding obligation. `entries`:

   | from                                | to                               | amount | meaning                                                                                                                                                                                             |
   | ----------------------------------- | -------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
   | `ACC_INVESTOR_PRINCIPAL_REPAID`     | `ACC_ORIGINATOR_FEE_PAYABLE`     | `fee`  | Originator forfeits fee toward investor. `ACC_ORIGINATOR_FEE_PAYABLE → 0`; `ACC_INVESTOR_PRINCIPAL_REPAID → -fee` (increases investor's net principal claim).                                       |
   | `ACC_BORROWER_PRINCIPAL_RECEIVABLE` | `ACC_INVESTOR_PRINCIPAL_PAYABLE` | `fee`  | Removes the fee portion from borrower's outstanding receivable; mirrors the reduction on the investor payable side so `principalReceivable` and `investorPrincipalPayable` stay equal in magnitude. |

   Both entries use `entryType = ENTRY_ADJUSTMENT`.

   If `fee == 0` (no origination fee at disbursement), step 2 is omitted entirely.

3. **Servicer** calls `applyWaterfall(loanId, 0, 0, 0, net, 0, timestamp, ref)`. Clears the remaining `net` principal from the payment clearing account into `ACC_BORROWER_PRINCIPAL_REPAID`.

4. **Investor** (or admin / NFT unlocker) calls `investorWithdraw([loanId], timestamp, ref)`. Reads `_getNetPrincipalPayableToInvestor = -ACC_BORROWER_PRINCIPAL_REPAID - ACC_INVESTOR_PRINCIPAL_REPAID = net + fee = P`. Transfers `P` from contract `ACC_CASH` to the investor.

5. **Servicer** calls `updateLoanData(loanId, LoanStatus.Cancelled, 0, 0, timestamp)`. Loan reaches terminal state and contributes `0` to NAV via `ValuationBucket.Cancelled` (default factor `0`).

### Post-state invariants

- ERC20 balance held by the contract for this loan ≈ `0` (all loan-scoped cash transferred to the investor)
- `ACC_CASH == 0`
- `ACC_BORROWER_PAYMENT_CLEARING == 0`
- `ACC_ORIGINATOR_FEE_PAYABLE == 0`
- `_getNetPrincipalPayableToInvestor == 0`
- Borrower's net principal outstanding (`receivable + min(repaid, 0)`) `== 0`
- `ACC_BORROWER_INTEREST_RECEIVABLE == 0`
- `data[loanId].status == LoanStatus.Cancelled`

### What if `fee == 0`?

Step 2 is skipped. Borrower returns `net = P`, waterfall allocates `P` to principal, investor withdraws `P`. Originator-related accounts stay at zero throughout.

## Scenario B — Accrual already recorded

The servicer accrued interest before cancellation, so `ACC_BORROWER_INTEREST_RECEIVABLE > 0` and `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE < 0`.

### Flow

1. **Servicer** reverses the accrual via `createLedgerEntries` with the original entry's `from`/`to` swapped:

   | from                               | to                                          | amount            |
   | ---------------------------------- | ------------------------------------------- | ----------------- |
   | `ACC_BORROWER_INTEREST_RECEIVABLE` | `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE` | `accruedInterest` |

   This reversal uses `entryType = ENTRY_INTEREST_REVERSAL`.

   `accrue(loanId, -accruedInterest, …)` is **not** a valid alternative — `_createInternalEntry` requires `amount > 0`. Multiple partial accruals can be reversed by a single entry whose amount equals the sum, as long as it does not exceed the current `ACC_BORROWER_INTEREST_RECEIVABLE` balance.

2. Continue with Scenario A, steps 1–5.

### What happens if the reversal is skipped

`pay`, `applyWaterfall` (with `investorInterest = servicingFees = 0`), and `investorWithdraw` all still succeed, and the loan can be moved to `Cancelled`. However:

- `ACC_BORROWER_INTEREST_RECEIVABLE` remains positive (asset on the borrower) with no offsetting payment ever cleared, leaving the per-loan ledger inconsistent with the economic outcome.
- `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE` remains negative.
- This does not affect NAV (`getLoanValues` reads only investor-side balances) but is a bookkeeping defect. The reversal is required for clean books.

## Scenario C — Status was set to `Cancelled` before borrower repaid

Servicer set `status = Cancelled` via `updateLoanData` while `ACC_BORROWER_PRINCIPAL_RECEIVABLE` was still non-zero.

### Effect of the premature transition

Once `status == Cancelled`, the following calls revert by status guard:

- `pay`, `accrue`, `chargeMiscFee` — `onlyOutstanding`
- `applyWaterfall`, `refundBorrower`, `returnFunds` — `onlyOutstandingOrFullyPaid`
- `updateBorrower`, `updateServicer` — `notTerminal`

`createLedgerEntries`, `updateLoanData`, `originatorWithdraw`, `investorWithdraw`, and `servicerWithdraw` are not status-gated and remain callable.

No funds are lost: cash balances and investor-side payables are untouched by a status flip, and the investor cannot withdraw what was never waterfalled.

### Recovery flow

`updateLoanData` is not guarded by `notTerminal`, so the servicer (or admin) can flip the status back out of `Cancelled`:

1. **Servicer** calls `updateLoanData(loanId, LoanStatus.Active, 0, 0, timestamp)`.
2. Proceed with Scenario A (or Scenario B if interest was accrued).
3. The final `updateLoanData(loanId, LoanStatus.Cancelled, …)` in step 5 returns the loan to terminal state.

The intermediate `Cancelled → Active → Cancelled` transitions are visible in `LoanStatusUpdated` events. Off-chain consumers must tolerate this re-opening pattern.

## Role Authorization Summary

| Step                                 | Who can call                                   | Function              |
| ------------------------------------ | ---------------------------------------------- | --------------------- |
| Re-open from `Cancelled`             | Servicer or admin                              | `updateLoanData`      |
| Reverse accrual                      | Servicer or admin                              | `createLedgerEntries` |
| Pay net amount                       | Borrower or admin (never servicer)             | `pay`                 |
| Redistribute fee + adjust receivable | Servicer or admin                              | `createLedgerEntries` |
| Apply waterfall (principal)          | Servicer or admin                              | `applyWaterfall`      |
| Withdraw to investor                 | Investor (NFT owner) or admin; or NFT unlocker | `investorWithdraw`    |
| Move to terminal status              | Servicer or admin                              | `updateLoanData`      |

## NAV Impact

While the loan is `Active` with the principal still outstanding, the NAV calculator values it via `ValuationBucket.Current` (or a DPD bucket if `nextDueDate` has passed). Once moved to `Cancelled`, the loan is valued by `discountFactors[ValuationBucket.Cancelled]`, which is initialized to `0` by convention; the cancelled loan therefore contributes nothing to NAV. See [nav-calculator.md](nav-calculator.md).

## Out of Scope / Future Work

- **No on-chain enforcement of the 5-day grace period.** Eligibility is validated off-chain. A future `cancelWithinGracePeriod(loanId, …)` could atomically perform the fee-redistribution entries, the `pay`-equivalent pull, the waterfall, the investor payout, and the status transition, gated by `block.timestamp <= loanTerms[loanId].originationDate + 5 days`.
- **Originator already withdrew the fee.** If `originatorWithdraw` ran before cancellation, `ACC_ORIGINATOR_FEE_PAYABLE` is no longer `-fee` and the contract no longer holds the `fee` cash. Restoring the borrower-whole invariant requires the originator to return funds to the contract first, but `returnFunds` only allows servicer-paid accounts, so this currently has no clean on-chain path and must be handled via an out-of-band repayment plus admin ledger entries.
- **No dedicated entry types** for cancellation. The `pay` and `applyWaterfall` steps post their usual `ENTRY_BORROWER_PAYMENT` and `ENTRY_BORROWER_PRINCIPAL_PAYMENT` entries. The manual `createLedgerEntries` steps reuse existing constants: the fee-redistribution entries use `ENTRY_ADJUSTMENT` and the accrual reversal uses `ENTRY_INTEREST_REVERSAL`. No cancellation-specific `entryType` constants are defined in `LedgerEntries.sol`.
