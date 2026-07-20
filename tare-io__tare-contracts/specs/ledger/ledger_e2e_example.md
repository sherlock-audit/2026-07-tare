# Loan Lifecycle Accounting Example

All accounts referenced in this example must be pre-defined in the [ledger chart of accounts](ledger_accounts.md).

## Phase 1: Origination ($10,000 loan)

### Ledger Entries

| #   | Transaction                       | Debit                         | Credit                     | Amount  |
| :-- | :-------------------------------- | :---------------------------- | :------------------------- | :------ |
| 1   | Create loan commitment            | Borrower Principal Receivable | Unfunded Commitment        | $10,000 |
| 2   | Withhold origination fee          | Unfunded Commitment           | Originator Fee Payable     | $100    |
| 3   | Receive investor funds            | Cash                          | Investor Principal Payable | $10,000 |
| 4   | Disburse to borrower (net of fee) | Unfunded Commitment           | Cash                       | $9,900  |
| 5   | Pay originator                    | Originator Fee Paid           | Cash                       | $100    |

#### Balance Sheet

| ASSETS                          | Amount      | LIABILITIES & EQUITY           | Amount      |
| :------------------------------ | :---------- | :----------------------------- | :---------- |
| Borrower Principal Receivable   | $10,000     | Unfunded Commitment            | $0          |
| Less: Borrower Principal Repaid | $0          | Investor Principal Payable     | $10,000     |
| **Net Loans Receivable**        | **$10,000** | Less: Investor Principal Paid  | $0          |
|                                 |             | **Net Investor Principal**     | **$10,000** |
| **Total Assets**                | **$10,000** | **Total Liabilities + Equity** | **$10,000** |

---

## Phase 2: Accrual ($100 total)

Interest and fees accrue daily throughout the loan period. This phase shows the cumulative accrual of $100 in borrower obligation before the first payment ($90 interest + $10 servicer fee).

### Ledger Entries

| #   | Transaction                | Debit                        | Credit                                | Amount |
| :-- | :------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 6   | Accrue borrower obligation | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $100   |

---

## Phase 3: First Repayment ($600 Payment)

**Scenario:** Borrower pays $600. The backend calculates the waterfall allocation:

- $10 to servicer fees
- $90 to interest
- $500 to principal

> **Note:** The waterfall priority is: Misc. Fees (Late/NSF) → Servicer Fee → Interest Due → Principal (remainder). The backend provides specific allocation amounts.

### Phase 3.a: Receive & Settle Payment

Borrower payment arrives in the Loans contract.

| #   | Transaction     | Debit | Credit                    | Amount |
| :-- | :-------------- | :---- | :------------------------ | :----- |
| 7   | Receive payment | Cash  | Borrower Payment Clearing | $600   |

### Phase 3.b: Allocate & Clear Debts

Allocate from the unallocated pool to servicer and investor. Then clear debts via waterfall.

| #   | Transaction           | Debit                                 | Credit                    | Amount |
| :-- | :-------------------- | :------------------------------------ | :------------------------ | :----- |
| 8   | Allocate servicer fee | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $10    |
| 9   | Allocate to investor  | Unallocated Borrower Interest Payable | Investor Interest Payable | $90    |
| 10  | Clear interest debt   | Borrower Payment Clearing             | Borrower Interest Paid    | $100   |
| 11  | Clear principal debt  | Borrower Payment Clearing             | Borrower Principal Repaid | $500   |

### Phase 3.c: Pay Out Parties

Withdraw from Cash to pay the servicer and investor.

| #   | Transaction                      | Debit                   | Credit | Amount |
| :-- | :------------------------------- | :---------------------- | :----- | :----- |
| 12  | Pay servicer                     | Servicer Fee Paid       | Cash   | $10    |
| 13  | Distribute interest to investor  | Investor Interest Paid  | Cash   | $90    |
| 14  | Distribute principal to investor | Investor Principal Paid | Cash   | $500   |

#### Balance Sheet (After Phase 3)

| ASSETS                          | Amount     | LIABILITIES & EQUITY           | Amount     |
| :------------------------------ | :--------- | :----------------------------- | :--------- |
| Cash                            | $0         | Investor Principal Payable     | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid  | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**     | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable      | $90        |
| Borrower Interest Receivable    | $100       | Less: Investor Interest Paid   | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**      | **$0**     |
| **Net Interest Receivable**     | **$0**     | Originator Fee Payable         | $100       |
|                                 |            | Less: Originator Fee Paid      | ($100)     |
|                                 |            | **Net Originator Fee**         | **$0**     |
|                                 |            | Unallocated Borrower Interest  | $0         |
|                                 |            | Servicer Fee Payable           | $10        |
|                                 |            | Less: Servicer Fee Paid        | ($10)      |
|                                 |            | **Net Servicer Fees**          | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity** | **$9,500** |

---

## Phase 4: Final Repayment ($10,510 Payment)

**Scenario:** Borrower pays $10,510 to fully repay the loan. The backend calculates the waterfall allocation:

- $110 to servicer fees
- $900 to interest
- $9,500 to principal

### Phase 4.a: Accrue Remaining Obligation

Accrue remaining interest and fees before final payment.

| #   | Transaction                | Debit                        | Credit                                | Amount |
| :-- | :------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 15  | Accrue borrower obligation | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $1,010 |

### Phase 4.b: Receive & Settle Payment

Borrower final payment arrives in the Loans contract.

| #   | Transaction     | Debit | Credit                    | Amount  |
| :-- | :-------------- | :---- | :------------------------ | :------ |
| 16  | Receive payment | Cash  | Borrower Payment Clearing | $10,510 |

### Phase 4.c: Allocate & Clear Debts

Allocate from the unallocated pool, then clear all debts via waterfall.

| #   | Transaction           | Debit                                 | Credit                    | Amount |
| :-- | :-------------------- | :------------------------------------ | :------------------------ | :----- |
| 17  | Allocate servicer fee | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $110   |
| 18  | Allocate to investor  | Unallocated Borrower Interest Payable | Investor Interest Payable | $900   |
| 19  | Clear interest debt   | Borrower Payment Clearing             | Borrower Interest Paid    | $1,010 |
| 20  | Clear principal debt  | Borrower Payment Clearing             | Borrower Principal Repaid | $9,500 |

### Phase 4.d: Pay Out Parties

Withdraw from Cash to pay the servicer and investor.

| #   | Transaction                      | Debit                   | Credit | Amount |
| :-- | :------------------------------- | :---------------------- | :----- | :----- |
| 21  | Pay servicer                     | Servicer Fee Paid       | Cash   | $110   |
| 22  | Distribute interest to investor  | Investor Interest Paid  | Cash   | $900   |
| 23  | Distribute principal to investor | Investor Principal Paid | Cash   | $9,500 |

#### Balance Sheet (Final)

| ASSETS                          | Amount    | LIABILITIES & EQUITY           | Amount    |
| :------------------------------ | :-------- | :----------------------------- | :-------- |
| Cash                            | $0        | Investor Principal Payable     | $10,000   |
| Borrower Principal Receivable   | $10,000   | Less: Investor Principal Paid  | ($10,000) |
| Less: Borrower Principal Repaid | ($10,000) | **Net Investor Principal**     | **$0**    |
| **Net Principal Receivable**    | **$0**    | Investor Interest Payable      | $990      |
| Borrower Interest Receivable    | $1,110    | Less: Investor Interest Paid   | ($990)    |
| Less: Borrower Interest Paid    | ($1,110)  | **Net Investor Interest**      | **$0**    |
| **Net Interest Receivable**     | **$0**    | Originator Fee Payable         | $100      |
|                                 |           | Less: Originator Fee Paid      | ($100)    |
|                                 |           | **Net Originator Fee**         | **$0**    |
|                                 |           | Unallocated Borrower Interest  | $0        |
|                                 |           | Servicer Fee Payable           | $120      |
|                                 |           | Less: Servicer Fee Paid        | ($120)    |
|                                 |           | **Net Servicer Fees**          | **$0**    |
| **Total Assets**                | **$0**    | **Total Liabilities + Equity** | **$0**    |

> **Note:** All accounts are fully settled. The loan is complete.
