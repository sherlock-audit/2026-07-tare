# Loan Late Fee Accounting Example

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
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable     | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid  | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**     | **$10,000** |
| **Total Assets**                | **$10,000** | **Total Liabilities + Equity** | **$10,000** |

---

## Phase 2: Accrual ($100 total)

Interest and fees accrue daily throughout the loan period. This phase shows the cumulative accrual of $100 in borrower obligation before the first payment ($90 interest + $10 servicer fee).

### Ledger Entries

| #   | Transaction                | Debit                        | Credit                                | Amount |
| :-- | :------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 6   | Accrue borrower obligation | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $100   |

#### Balance Sheet

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $100        | Unallocated Borrower Interest Payable | $100        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$100**    |                                       |             |
| **Total Assets**                | **$10,100** | **Total Liabilities + Equity**        | **$10,100** |

---

## Phase 3: Payment Due Date Passes (No Payment Received)

**Scenario:** Payment due date passes. The expected monthly payment amoun is $890 but the borrower misses the payment.

**Days 1-15 (Grace Period):** No late fee assessed yet. Loan remains current in DPD calculation.

**Day 16 (After Grace Period):**

It's now 1 day past due. The loan status should be changed from Current to Delinquent.

Servicer assesses late fee:

- Late Fee = 5% × $890 = $44.50, but capped at $25.00 based on jurisdiction
- Late fees are tracked separately from regular servicing fees via Misc Fee accounts

### Ledger Entries

| #   | Transaction     | Debit                        | Credit                    | Amount |
| :-- | :-------------- | :--------------------------- | :------------------------ | :----- |
| 7   | Assess late fee | Borrower Misc Fee Receivable | Servicer Misc Fee Payable | $25    |

#### Balance Sheet

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $100        | Unallocated Borrower Interest Payable | $100        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$100**    |                                       |             |
| Borrower Misc Fee Receivable    | $25         | Servicer Misc Fee Payable             | $25         |
| Less: Borrower Misc Fee Paid    | $0          | Less: Servicer Misc Fee Paid          | $0          |
| **Net Borrower Misc Fees**      | **$25**     | **Net Servicer Misc Fees**            | **$25**     |
| **Total Assets**                | **$10,125** | **Total Liabilities + Equity**        | **$10,125** |

---

## Phase 4: Late Payment ($925 Payment - Day 20)

**Scenario:** Borrower pays $925 on day 20 (5 days after grace period ended). Payment covers:

- $25 for late fee (Misc. fee) — highest priority
- $10 for regular servicer fee
- $90 for accrued interest
- $800 towards principal

LoanStatus is back to `Current`.

> **Note:** The waterfall priority is: Misc. Fees (Late/NSF) → Servicer Fee → Interest Due → Principal (remainder).

### Phase 4.a: Receive & Settle Payment

Borrower payment arrives in the Loans contract.

| #   | Transaction     | Debit | Credit                    | Amount |
| :-- | :-------------- | :---- | :------------------------ | :----- |
| 8   | Receive payment | Cash  | Borrower Payment Clearing | $925   |

### Phase 4.b: Allocate & Clear Debts

Allocate from the unallocated pool to servicer and investor. Then clear debts via waterfall.

| #   | Transaction           | Debit                                 | Credit                    | Amount |
| :-- | :-------------------- | :------------------------------------ | :------------------------ | :----- |
| 9   | Allocate servicer fee | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $10    |
| 10  | Allocate to investor  | Unallocated Borrower Interest Payable | Investor Interest Payable | $90    |
| 11  | Clear misc fee debt   | Borrower Payment Clearing             | Borrower Misc Fee Paid    | $25    |
| 12  | Clear interest debt   | Borrower Payment Clearing             | Borrower Interest Paid    | $100   |
| 13  | Clear principal debt  | Borrower Payment Clearing             | Borrower Principal Repaid | $800   |

### Phase 4.c: Pay Out Parties

Withdraw from Cash to pay the servicer and investor.

| #   | Transaction                      | Debit                   | Credit | Amount |
| :-- | :------------------------------- | :---------------------- | :----- | :----- |
| 14  | Pay servicer (svc fees)          | Servicer Fee Paid       | Cash   | $10    |
| 15  | Pay servicer (misc fees)         | Servicer Misc Fee Paid  | Cash   | $25    |
| 16  | Distribute interest to investor  | Investor Interest Paid  | Cash   | $90    |
| 17  | Distribute principal to investor | Investor Principal Paid | Cash   | $800   |

#### Balance Sheet (After Phase 4)

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($800)     |
| Less: Borrower Principal Repaid | ($800)     | **Net Investor Principal**            | **$9,200** |
| **Net Principal Receivable**    | **$9,200** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $100       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
| Borrower Misc Fee Receivable    | $25        | Servicer Fee Payable                  | $10        |
| Less: Borrower Misc Fee Paid    | ($25)      | Less: Servicer Fee Paid               | ($10)      |
| **Net Borrower Misc Fees**      | **$0**     | **Net Servicer Fees**                 | **$0**     |
|                                 |            | Servicer Misc Fee Payable             | $25        |
|                                 |            | Less: Servicer Misc Fee Paid          | ($25)      |
|                                 |            | **Net Servicer Misc Fees**            | **$0**     |
| **Total Assets**                | **$9,200** | **Total Liabilities + Equity**        | **$9,200** |

---

## Notes

**Single Assessment**: Late fees are only assessed once when a loan transitions from Current to Delinquent. The backend system tracks this to prevent double-charging.

---

# Alternative Scenario A: Late Fee Waiver Before Payment

_This scenario continues from Phase 3 above, but with a different outcome._

---

## Phase 4 (Alt A): Late Fee Waiver - Day 18

**Scenario:** Borrower reaches out to the servicer on day 18. After review of the borrower's situation and payment history, the servicer agrees to waive the $25 late fee as a gesture of goodwill.

### Ledger Entries

| #   | Transaction                         | Debit                     | Credit                       | Amount |
| :-- | :---------------------------------- | :------------------------ | :--------------------------- | :----- |
| 8   | Waive late fee (reverse receivable) | Servicer Misc Fee Payable | Borrower Misc Fee Receivable | $25    |

#### Balance Sheet

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $100        | Unallocated Borrower Interest Payable | $100        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$100**    |                                       |             |
| Borrower Misc Fee Receivable    | $0          | Servicer Misc Fee Payable             | $0          |
| **Total Assets**                | **$10,100** | **Total Liabilities + Equity**        | **$10,100** |

> **Note:** Subsequent payment follows the standard flow in [ledger_e2e_example.md](../ledger_e2e_example.md), without any late fee component.

---

## Notes on Alternative Scenario A

**DPD Impact**: The waiver of the late fee does not affect DPD calculation. The borrower was still late and DPD was still counted. The waiver only affects the financial obligation, not the delinquency status or history.

---

# Alternative Scenario B: Late Fee Waiver After Distribution

_This scenario continues from Phase 4 (main flow) above. The late fee has already been paid by the borrower and distributed to the servicer._

---

## Phase 5 (Alt B): Late Fee Waiver & Refund - Day 25

**Scenario:** After reviewing the borrower's complaint, the servicer agrees to waive the $25 late fee even though it was already collected. The servicer must return the funds, and the borrower receives a refund.

**Correction Steps:**

1. Reverse the late fee assessment (borrower no longer owes)
2. Servicer returns funds to the contract via `returnFunds()`
3. Refund the borrower

### Ledger Entries

| #   | Transaction                 | Debit                     | Credit                       | Amount | Entry Type                 |
| :-- | :-------------------------- | :------------------------ | :--------------------------- | :----- | :------------------------- |
| 18  | Reverse late fee assessment | Servicer Misc Fee Payable | Borrower Misc Fee Receivable | $25    | `ENTRY_ADJUSTMENT`         |
| 19  | Servicer returns funds      | Cash                      | Servicer Misc Fee Paid       | $25    | `ENTRY_SERVICER_FUND_RETURN` |
| 20  | Refund to borrower          | Borrower Misc Fee Paid    | Cash                         | $25    | `ENTRY_BORROWER_REFUND`    |

#### Balance Sheet (After Refund)

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($800)     |
| Less: Borrower Principal Repaid | ($800)     | **Net Investor Principal**            | **$9,200** |
| **Net Principal Receivable**    | **$9,200** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $100       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
| Borrower Misc Fee Receivable    | $0         | Servicer Fee Payable                  | $10        |
| Less: Borrower Misc Fee Paid    | $0         | Less: Servicer Fee Paid               | ($10)      |
| **Net Borrower Misc Fees**      | **$0**     | **Net Servicer Fees**                 | **$0**     |
|                                 |            | Servicer Misc Fee Payable             | $25        |
|                                 |            | Less: Servicer Misc Fee Paid          | ($25)      |
|                                 |            | **Net Servicer Misc Fees**            | **$0**     |
| **Total Assets**                | **$9,200** | **Total Liabilities + Equity**        | **$9,200** |

> **Note:** All Misc Fee accounts are zeroed out. The late fee is effectively erased as if it never happened. The borrower's `Borrower Misc Fee Paid` contra-account returns to $0 because the refund reverses their original payment.

---

## Notes on Alternative Scenario B

**Fund Flow:**

- Servicer transfers $25 back to the contract via `returnFunds()`
- Contract transfers $25 to borrower (off-chain ACH or on-chain transfer)

**Smart Contract Functions:**

| Function          | Caller   | Purpose                              |
| :---------------- | :------- | :----------------------------------- |
| `returnFunds()`   | Servicer | Return withdrawn funds to contract   |
| `refundBorrower()` | Admin   | Transfer refund from contract to borrower |
