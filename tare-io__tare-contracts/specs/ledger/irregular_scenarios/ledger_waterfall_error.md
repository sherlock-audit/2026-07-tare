# Waterfall Error Correction

This document covers correction scenarios for allocation errors in the waterfall. All accounts referenced must be pre-defined in the [ledger chart of accounts](../ledger_accounts.md).

## Overview

Three correction scenarios are covered:

| Scenario                       | Situation                                                                                     | Correction Approach                                                        |
| :----------------------------- | :-------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------- |
| **1. Before Payment**          | Error discovered before borrower pays                                                         | Simple reversal entry                                                      |
| **2. Borrower Overcharged**    | Borrower paid too much total; servicer received excess                                        | Option A: Credit against future fees / Option B: Servicer refunds borrower |
| **3. Incorrect Split**         | Borrower paid correct total, but split was wrong (servicer got too much, investor too little) | Servicer returns funds via `returnFunds()`, redistributed to investor      |
| **4. Reverse Incorrect Split** | Borrower paid correct total, but split was wrong (investor got too much, servicer too little) | Accounting reclassification only — no cash movement, no investor clawback  |

---

## Common Setup: Origination

All scenarios share the same origination phase. Scenarios 1 and 2 share the erroneous accrual phase; Scenario 3 has correct accrual but wrong allocation.

### Phase 1: Origination ($10,000 loan)

#### Ledger Entries

| #   | Transaction                       | Debit                         | Credit                     | Amount  |
| :-- | :-------------------------------- | :---------------------------- | :------------------------- | :------ |
| 1   | Create loan commitment            | Borrower Principal Receivable | Unfunded Commitment        | $10,000 |
| 2   | Withhold origination fee          | Unfunded Commitment           | Originator Fee Payable     | $100    |
| 3   | Receive investor funds            | Cash                          | Investor Principal Payable | $10,000 |
| 4   | Disburse to borrower (net of fee) | Unfunded Commitment           | Cash                       | $9,900  |
| 5   | Pay originator                    | Originator Fee Paid           | Cash                       | $100    |

<details open>
<summary>Balance Sheet (After Origination)</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY           | Amount      |
| :------------------------------ | :---------- | :----------------------------- | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable     | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid  | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**     | **$10,000** |
| **Total Assets**                | **$10,000** | **Total Liabilities + Equity** | **$10,000** |

</details>

---

### Phase 2 (Scenarios 1 & 2): Erroneous Accrual ($120 total when $110 was owed)

**Error:** $120 was accrued when only $110 was actually owed ($90 interest + $20 servicer fee). The extra $10 will be incorrectly allocated to the servicer.

#### Ledger Entries

| #   | Transaction                            | Debit                        | Credit                                | Amount |
| :-- | :------------------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 6   | Accrue borrower obligation (INCORRECT) | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $120   |

<details open>
<summary>Balance Sheet (After Erroneous Accrual)</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $120        | Unallocated Borrower Interest Payable | $120        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$120**    |                                       |             |
| **Total Assets**                | **$10,120** | **Total Liabilities + Equity**        | **$10,120** |

</details>

---

## Scenario 1: Correction Before Payment

Error is discovered before the borrower makes any payment. No funds have been distributed.

### Phase 3: Correction (Reverse $10 Over-Accrual)

**Correction:** Reverse $10 of the incorrectly accrued amount to bring the balance to the correct $110.

#### Correction Ledger Entries

| #   | Transaction          | Debit                                 | Credit                       | Amount | Entry Type                |
| :-- | :------------------- | :------------------------------------ | :--------------------------- | :----- | :------------------------ |
| 7   | Reverse over-accrual | Unallocated Borrower Interest Payable | Borrower Interest Receivable | $10    | `ENTRY_INTEREST_REVERSAL` |

<details open>
<summary>Balance Sheet (After Correction)</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $110        | Unallocated Borrower Interest Payable | $110        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$110**    |                                       |             |
| **Total Assets**                | **$10,110** | **Total Liabilities + Equity**        | **$10,110** |

</details>

---

## Scenario 2: Borrower Overcharged (Credit Against Future Fees)

The borrower paid based on the incorrect accrual and was overcharged by $10. The correct payment should have been $610 ($500 principal + $90 interest + $20 servicer fee), but the borrower paid $620 ($500 principal + $90 interest + $30 servicer fee). The servicer receives a $10 excess that must be credited against future fees.

### Phase 3: Borrower Payment (Based on Incorrect Accrual)

Borrower pays $620 total. Funds are allocated and distributed immediately, with $30 going to servicer instead of $20.

#### Phase 3.a: Receive Payment

| #   | Transaction     | Debit | Credit                    | Amount |
| :-- | :-------------- | :---- | :------------------------ | :----- |
| 7   | Receive payment | Cash  | Borrower Payment Clearing | $620   |

#### Phase 3.b: Allocate & Clear Debts (with error)

| #   | Transaction                   | Debit                                 | Credit                    | Amount |
| :-- | :---------------------------- | :------------------------------------ | :------------------------ | :----- |
| 8   | Allocate servicer fee (wrong) | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $30    |
| 9   | Allocate to investor          | Unallocated Borrower Interest Payable | Investor Interest Payable | $90    |
| 10  | Clear interest debt           | Borrower Payment Clearing             | Borrower Interest Paid    | $120   |
| 11  | Clear principal debt          | Borrower Payment Clearing             | Borrower Principal Repaid | $500   |

#### Phase 3.c: Pay Out Parties

| #   | Transaction                      | Debit                   | Credit | Amount |
| :-- | :------------------------------- | :---------------------- | :----- | :----- |
| 12  | Pay servicer                     | Servicer Fee Paid       | Cash   | $30    |
| 13  | Distribute interest to investor  | Investor Interest Paid  | Cash   | $90    |
| 14  | Distribute principal to investor | Investor Principal Paid | Cash   | $500   |

<details open>
<summary>Balance Sheet (After Payment & Distribution)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $120       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($120)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $30        |
|                                 |            | Less: Servicer Fee Paid               | ($30)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

---

### Phase 4 (Option A): Credit Against Future Fees

**Correction:** The over-allocation is discovered. We need to:

1. Reverse the over-accrual (reducing borrower's receivable)
2. Reverse the over-allocation to servicer (reducing their payable, but they've already been paid)

This creates a negative `Net Servicer Fees` which represents a credit the servicer owes back, applied against future fees.

#### Correction Ledger Entries

| #   | Transaction                      | Debit                                 | Credit                                | Amount | Entry Type                    |
| :-- | :------------------------------- | :------------------------------------ | :------------------------------------ | :----- | :---------------------------- |
| 15  | Reverse over-accrual             | Unallocated Borrower Interest Payable | Borrower Interest Receivable          | $10    | `ENTRY_INTEREST_REVERSAL`     |
| 16  | Reverse servicer over-allocation | Servicer Fee Payable                  | Unallocated Borrower Interest Payable | $10    | `ENTRY_SERVICER_FEE_REVERSAL` |

<details open>
<summary>Balance Sheet (After Correction - Option A)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($120)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **($10)**  | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $20        |
|                                 |            | Less: Servicer Fee Paid               | ($30)      |
|                                 |            | **Net Servicer Fees**                 | **($10)**  |
| **Total Assets**                | **$9,490** | **Total Liabilities + Equity**        | **$9,490** |

</details>

> **Note:** The negative `Net Servicer Fees` (-$10) represents a credit that will automatically offset the next servicer fee allocation. For example, if $20 is allocated next period, only $10 net flows to the servicer. This mechanism allows the servicer to effectively "repay" the overcharge through reduced future payments without requiring an immediate fund return.

---

### Phase 4 (Option B): Servicer Returns Funds to Borrower

**Alternative Correction:** Instead of applying a credit against future fees, the servicer immediately returns the $10 excess, which is then refunded to the borrower.

**Correction Steps:**

1. Reverse the over-accrual (reducing borrower's receivable)
2. Reverse the over-allocation to servicer
3. Servicer returns $10 to the contract via `returnFunds()`
4. Refund $10 to borrower

#### Correction Ledger Entries

| #   | Transaction                      | Debit                                 | Credit                                | Amount | Entry Type                    |
| :-- | :------------------------------- | :------------------------------------ | :------------------------------------ | :----- | :---------------------------- |
| 15  | Reverse over-accrual             | Unallocated Borrower Interest Payable | Borrower Interest Receivable          | $10    | `ENTRY_INTEREST_REVERSAL`     |
| 16  | Reverse servicer over-allocation | Servicer Fee Payable                  | Unallocated Borrower Interest Payable | $10    | `ENTRY_SERVICER_FEE_REVERSAL` |
| 17  | Servicer returns funds           | Cash                                  | Servicer Fee Paid                     | $10    | `ENTRY_SERVICER_FUND_RETURN`  |
| 18  | Refund to borrower               | Borrower Interest Paid                | Cash                                  | $10    | `ENTRY_BORROWER_REFUND`       |

<details open>
<summary>Balance Sheet (After Correction - Option B)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($110)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $20        |
|                                 |            | Less: Servicer Fee Paid               | ($20)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** In Option B, all accounts are fully corrected:
>
> - `Borrower Interest Receivable` reduced to correct $110
> - `Borrower Interest Paid` reduced from $120 to $110 (borrower refunded)
> - `Servicer Fee Paid` reduced from $30 to $20 (servicer returned excess)
> - The balance sheet balances at $9,500 with no negative accounts

---

## Scenario 3: Incorrect Split (Servicer Returns Funds to Investor)

The borrower paid the correct total amount ($610), but the allocation between interest and servicer fee was wrong. The payment was allocated as $500 principal + $80 interest + $30 servicer fee, when it should have been $500 principal + $90 interest + $20 servicer fee. The servicer received $10 too much, and the investor received $10 too little in interest. The servicer must return $10, which is then distributed to the investor.

### Phase 2 (Scenario 3): Correct Accrual ($110 total)

Unlike Scenarios 1 and 2, the accrual amount is correct here. The error occurs during allocation, not accrual.

#### Ledger Entries

| #   | Transaction                | Debit                        | Credit                                | Amount |
| :-- | :------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 6   | Accrue borrower obligation | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $110   |

<details open>
<summary>Balance Sheet (After Correct Accrual)</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $110        | Unallocated Borrower Interest Payable | $110        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$110**    |                                       |             |
| **Total Assets**                | **$10,110** | **Total Liabilities + Equity**        | **$10,110** |

</details>

---

### Phase 3: Borrower Payment (Correct Total, Wrong Split)

Payment is $610 total with wrong allocation.

#### Phase 3.a: Receive Payment

| #   | Transaction     | Debit | Credit                    | Amount |
| :-- | :-------------- | :---- | :------------------------ | :----- |
| 7   | Receive payment | Cash  | Borrower Payment Clearing | $610   |

#### Phase 3.b: Allocate & Clear (with wrong split)

| #   | Transaction                   | Debit                                 | Credit                    | Amount |
| :-- | :---------------------------- | :------------------------------------ | :------------------------ | :----- |
| 8   | Allocate servicer fee (wrong) | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $30    |
| 9   | Allocate to investor (wrong)  | Unallocated Borrower Interest Payable | Investor Interest Payable | $80    |
| 10  | Clear interest debt           | Borrower Payment Clearing             | Borrower Interest Paid    | $110   |
| 11  | Clear principal debt          | Borrower Payment Clearing             | Borrower Principal Repaid | $500   |

#### Phase 3.c: Pay Out Parties

| #   | Transaction                      | Debit                   | Credit | Amount |
| :-- | :------------------------------- | :---------------------- | :----- | :----- |
| 12  | Pay servicer                     | Servicer Fee Paid       | Cash   | $30    |
| 13  | Distribute interest to investor  | Investor Interest Paid  | Cash   | $80    |
| 14  | Distribute principal to investor | Investor Principal Paid | Cash   | $500   |

<details open>
<summary>Balance Sheet (After Payment & Distribution)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $80        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($80)      |
| Less: Borrower Interest Paid    | ($110)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $30        |
|                                 |            | Less: Servicer Fee Paid               | ($30)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

---

### Phase 4: Correction (Servicer Returns Funds to Investor)

**Correction Steps:**

1. Reverse the servicer over-allocation ($10)
2. Allocate the additional interest to investor ($10)
3. Servicer calls `returnFunds()` to return $10 to the contract
4. Distribute $10 to investor

#### Correction Ledger Entries

| #   | Transaction                      | Debit                                 | Credit                                | Amount | Entry Type                           |
| :-- | :------------------------------- | :------------------------------------ | :------------------------------------ | :----- | :----------------------------------- |
| 15  | Reverse servicer over-allocation | Servicer Fee Payable                  | Unallocated Borrower Interest Payable | $10    | `ENTRY_SERVICER_FEE_REVERSAL`        |
| 16  | Allocate to investor             | Unallocated Borrower Interest Payable | Investor Interest Payable             | $10    | `ENTRY_INVESTOR_INTEREST_ALLOCATION` |
| 17  | Servicer returns excess funds    | Cash                                  | Servicer Fee Paid                     | $10    | `ENTRY_SERVICER_FUND_RETURN`         |
| 18  | Distribute interest to investor  | Investor Interest Paid                | Cash                                  | $10    | `ENTRY_INVESTOR_INTEREST_WITHDRAWAL` |

<details open>
<summary>Balance Sheet (After Correction)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($110)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $20        |
|                                 |            | Less: Servicer Fee Paid               | ($20)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** In Scenario 3, actual token transfers occur:
>
> - Servicer transfers $10 back to the contract via `returnFunds()`
> - Contract transfers $10 to investor via `investorWithdraw()`
>
> This differs from Scenario 2 Option A, where no fund movement is required because the credit is settled against future fee allocations. Scenario 2 Option B also involves actual fund transfers (servicer to contract to borrower).

---

## Scenario 4: Reverse Incorrect Split (Investor Got Too Much, Servicer Too Little)

The borrower paid the correct total amount ($610), but allocation was wrong in the opposite direction: the investor got too much and the servicer too little. Cash is never clawed back from the investor. The servicer deficit is settled from the next payment cycle.

Correct split: $20 servicer / $90 investor interest / $500 principal = $610 total ($110 accrual).

Three sub-cases are covered depending on where the excess landed in the waterfall.

### Phase 2 (Scenario 4): Correct Accrual ($110 total)

Accrual is correct. The error occurs during allocation.

#### Ledger Entries

| #   | Transaction                | Debit                        | Credit                                | Amount |
| :-- | :------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 6   | Accrue borrower obligation | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $110   |

---

### Sub-case 4A: Investor Interest Too High

**Actual allocation:** $10 servicer / $100 investor interest / $500 principal. The investor received $10 excess interest.

#### Phase 3: Borrower Payment (Wrong Split)

| #   | Transaction                      | Debit                                 | Credit                    | Amount |
| :-- | :------------------------------- | :------------------------------------ | :------------------------ | :----- |
| 7   | Receive payment                  | Cash                                  | Borrower Payment Clearing | $610   |
| 8   | Allocate servicer fee (wrong)    | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $10    |
| 9   | Allocate to investor (wrong)     | Unallocated Borrower Interest Payable | Investor Interest Payable | $100   |
| 10  | Clear interest debt              | Borrower Payment Clearing             | Borrower Interest Paid    | $110   |
| 11  | Clear principal debt             | Borrower Payment Clearing             | Borrower Principal Repaid | $500   |
| 12  | Pay servicer                     | Servicer Fee Paid                     | Cash                      | $10    |
| 13  | Distribute interest to investor  | Investor Interest Paid                | Cash                      | $100   |
| 14  | Distribute principal to investor | Investor Principal Paid               | Cash                      | $500   |

#### Phase 4: Correction

| #   | Transaction                      | Debit                                 | Credit                                | Amount | Entry Type                        |
| :-- | :------------------------------- | :------------------------------------ | :------------------------------------ | :----- | :-------------------------------- |
| 15  | Reverse investor over-allocation | Investor Interest Payable             | Unallocated Borrower Interest Payable | $10    | `ENTRY_INTEREST_REVERSAL`         |
| 16  | Allocate to servicer             | Unallocated Borrower Interest Payable | Servicer Fee Payable                  | $10    | `ENTRY_SERVICER_FEE_ALLOCATION`   |
| 17  | Reclassify investor payout       | Investor Principal Paid               | Investor Interest Paid                | $10    | `ENTRY_INTEREST_RECLASSIFICATION` |

<details>
<summary>Balance Sheet (After Correction - Sub-case 4A)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($510)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,490** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($110)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $20        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$10**    |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** `Net Servicer Fees` = +$10 means the servicer is owed $10, settled from the next payment cycle. The investor's $10 excess interest is reclassified to principal return on the books — no cash clawback.

---

### Sub-case 4B: Principal Too High

**Actual allocation:** $10 servicer / $90 investor interest / $510 principal. The investor received $10 excess principal return which should have been servicing fees.

#### Phase 3: Borrower Payment (Wrong Split)

| #   | Transaction                      | Debit                                 | Credit                    | Amount |
| :-- | :------------------------------- | :------------------------------------ | :------------------------ | :----- |
| 7   | Receive payment                  | Cash                                  | Borrower Payment Clearing | $610   |
| 8   | Allocate servicer fee (wrong)    | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $10    |
| 9   | Allocate to investor             | Unallocated Borrower Interest Payable | Investor Interest Payable | $90    |
| 10  | Clear interest debt              | Borrower Payment Clearing             | Borrower Interest Paid    | $100   |
| 11  | Clear principal debt             | Borrower Payment Clearing             | Borrower Principal Repaid | $510   |
| 12  | Pay servicer                     | Servicer Fee Paid                     | Cash                      | $10    |
| 13  | Distribute interest to investor  | Investor Interest Paid                | Cash                      | $90    |
| 14  | Distribute principal to investor | Investor Principal Paid               | Cash                      | $510   |

<details open>
<summary>Balance Sheet (After Payment & Distribution)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($510)     |
| Less: Borrower Principal Repaid | ($510)     | **Net Investor Principal**            | **$9,490** |
| **Net Principal Receivable**    | **$9,490** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$10**    | Unallocated Borrower Interest Payable | $10        |
|                                 |            | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** The error here is in the clearing amounts, not the allocation amounts:
>
> - $110 was accrued to `Unallocated Borrower Interest Payable`
> - Only $100 was allocated from Unallocated (svc $10 + interest $90), leaving $10 still in Unallocated
> - Entry #10 cleared only $100 of interest debt (matching what was allocated), when it should have cleared $110
> - Entry #11 cleared $510 of principal (absorbing the $10 that should have gone to servicer fees)
>
> The correction (Phase 4) will: (1) reclassify $10 from principal to interest on the borrower side and (2) allocate the remaining $10 from Unallocated to servicer.

#### Phase 4: Correction

| #   | Transaction                 | Debit                                 | Credit                 | Amount | Entry Type                        |
| :-- | :-------------------------- | :------------------------------------ | :--------------------- | :----- | :-------------------------------- |
| 15  | Reclassify borrower payment | Borrower Principal Repaid             | Borrower Interest Paid | $10    | `ENTRY_INTEREST_RECLASSIFICATION` |
| 16  | Allocate to servicer        | Unallocated Borrower Interest Payable | Servicer Fee Payable   | $10    | `ENTRY_SERVICER_FEE_ALLOCATION`   |

<details>
<summary>Balance Sheet (After Correction - Sub-case 4B)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($510)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,490** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($110)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $20        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$10**    |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** The investor received extra principal (not interest), so there is no tax reclassification impact. The borrower's principal balance is corrected via entry 15. Servicer deficit settled from next cycle.

---

### Sub-case 4C: Both Interest and Principal Too High

**Actual allocation:** $10 servicer / $95 investor interest / $505 principal. The investor received $5 excess interest and $5 excess principal return.

#### Phase 3: Borrower Payment (Wrong Split)

| #   | Transaction                      | Debit                                 | Credit                    | Amount |
| :-- | :------------------------------- | :------------------------------------ | :------------------------ | :----- |
| 7   | Receive payment                  | Cash                                  | Borrower Payment Clearing | $610   |
| 8   | Allocate servicer fee (wrong)    | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $10    |
| 9   | Allocate to investor (wrong)     | Unallocated Borrower Interest Payable | Investor Interest Payable | $95    |
| 10  | Clear interest debt              | Borrower Payment Clearing             | Borrower Interest Paid    | $105   |
| 11  | Clear principal debt             | Borrower Payment Clearing             | Borrower Principal Repaid | $505   |
| 12  | Pay servicer                     | Servicer Fee Paid                     | Cash                      | $10    |
| 13  | Distribute interest to investor  | Investor Interest Paid                | Cash                      | $95    |
| 14  | Distribute principal to investor | Investor Principal Paid               | Cash                      | $505   |

<details open>
<summary>Balance Sheet (After Payment & Distribution)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($505)     |
| Less: Borrower Principal Repaid | ($505)     | **Net Investor Principal**            | **$9,495** |
| **Net Principal Receivable**    | **$9,495** | Investor Interest Payable             | $95        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($95)      |
| Less: Borrower Interest Paid    | ($105)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$5**     | Unallocated Borrower Interest Payable | $5         |
|                                 |            | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** $5 remains in `Unallocated Borrower Interest Payable` ($110 - $10 svc - $95 interest = $5).

#### Phase 4: Correction

| #   | Transaction                      | Debit                                 | Credit                                | Amount | Entry Type                        |
| :-- | :------------------------------- | :------------------------------------ | :------------------------------------ | :----- | :-------------------------------- |
| 15  | Reclassify borrower payment      | Borrower Principal Repaid             | Borrower Interest Paid                | $5     | `ENTRY_INTEREST_RECLASSIFICATION` |
| 16  | Reverse investor over-allocation | Investor Interest Payable             | Unallocated Borrower Interest Payable | $5     | `ENTRY_INTEREST_REVERSAL`         |
| 17  | Allocate to servicer             | Unallocated Borrower Interest Payable | Servicer Fee Payable                  | $10    | `ENTRY_SERVICER_FEE_ALLOCATION`   |
| 18  | Reclassify investor payout       | Investor Principal Paid               | Investor Interest Paid                | $5     | `ENTRY_INTEREST_RECLASSIFICATION` |

<details>
<summary>Balance Sheet (After Correction - Sub-case 4C)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($510)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,490** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $110       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($110)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $20        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$10**    |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** Combination of sub-cases 4A and 4B. The $5 interest excess is reclassified, the $5 principal excess requires borrower-side correction. All three sub-cases produce the same final balance sheet.

---

## Notes

### Entry Types Used

| Entry Type                           | Purpose                                                              |
| :----------------------------------- | :------------------------------------------------------------------- |
| `ENTRY_SERVICER_FEE_REVERSAL`        | Reversing incorrect servicer fee allocation                          |
| `ENTRY_SERVICER_FEE_ALLOCATION`      | Allocating from Unallocated to servicer (correction)                 |
| `ENTRY_SERVICER_FUND_RETURN`         | Servicer returning funds via `returnFunds()`                         |
| `ENTRY_INVESTOR_INTEREST_ALLOCATION` | Allocating from Unallocated to investor                              |
| `ENTRY_INVESTOR_INTEREST_WITHDRAWAL` | Distributing interest to investor via `investorWithdraw()`           |
| `ENTRY_INTEREST_REVERSAL`            | Reversing incorrect interest accrual or investor interest allocation |
| `ENTRY_INTEREST_RECLASSIFICATION`    | Reclassifying investor payout from interest to principal             |
| `ENTRY_BORROWER_REFUND`              | Refunding overpayment to borrower (Scenario 2B)                      |

### Credit Mechanism (Scenario 2 Option A)

When servicer fees are over-allocated, the negative `Net Servicer Fees` will offset future allocations:

```
Next period allocation: $20
Current Net Servicer Fees: -$10
After allocation: $20 + (-$10) = $10 net payment to servicer
```

The servicer effectively "repays" the $10 overcharge by receiving $10 less on the next payment cycle.
