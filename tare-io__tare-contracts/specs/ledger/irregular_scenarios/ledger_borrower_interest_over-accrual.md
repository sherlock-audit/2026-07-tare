# Interest Over-Accrual Correction

This document covers correction scenarios for interest over-accrual errors. All accounts referenced must be pre-defined in the [ledger chart of accounts](../ledger_accounts.md).

---

## Scenario 1: Correction Before Payment ($10,000 loan)

This scenario covers the case where interest over-accrual is discovered and corrected **before** the borrower has made a payment.

### Phase 1: Origination

#### Ledger Entries

| #   | Transaction                       | Debit                         | Credit                     | Amount  |
| :-- | :-------------------------------- | :---------------------------- | :------------------------- | :------ |
| 1   | Create loan commitment            | Borrower Principal Receivable | Unfunded Commitment        | $10,000 |
| 2   | Withhold origination fee          | Unfunded Commitment           | Originator Fee Payable     | $100    |
| 3   | Receive investor funds            | Cash                          | Investor Principal Payable | $10,000 |
| 4   | Disburse to borrower (net of fee) | Unfunded Commitment           | Cash                       | $9,900  |
| 5   | Pay originator                    | Originator Fee Paid           | Cash                       | $100    |

<details>
<summary>Balance Sheet</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY           | Amount      |
| :------------------------------ | :---------- | :----------------------------- | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable     | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid  | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**     | **$10,000** |
| **Total Assets**                | **$10,000** | **Total Liabilities + Equity** | **$10,000** |

</details>

---

### Phase 2: Erroneous Accrual ($150 total when $100 was owed)

**Error:** $150 of borrower obligation was incorrectly accrued when only $100 was actually owed ($90 interest + $10 servicer fee).

#### Ledger Entries

| #   | Transaction                            | Debit                        | Credit                                | Amount |
| :-- | :------------------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 6   | Accrue borrower obligation (INCORRECT) | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $150   |

<details>
<summary>Balance Sheet (After Erroneous Accrual)</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $150        | Unallocated Borrower Interest Payable | $150        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$150**    |                                       |             |
| **Total Assets**                | **$10,150** | **Total Liabilities + Equity**        | **$10,150** |

</details>

---

### Phase 3: Correction (Reverse $50 Over-Accrual)

**Correction:** Reverse $50 of the incorrectly accrued obligation to bring the balance to the correct $100.

#### Correction Ledger Entries

| #   | Transaction          | Debit                                 | Credit                       | Amount |
| :-- | :------------------- | :------------------------------------ | :--------------------------- | :----- |
| 7   | Reverse over-accrual | Unallocated Borrower Interest Payable | Borrower Interest Receivable | $50    |

<details>
<summary>Balance Sheet (After Correction)</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $100        | Unallocated Borrower Interest Payable | $100        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$100**    |                                       |             |
| **Total Assets**                | **$10,100** | **Total Liabilities + Equity**        | **$10,100** |

</details>

---

## Scenario 2: Correction After Payment & Distribution ($10,000 loan)

This scenario covers the case where the borrower has already paid the incorrect (over-accrued) interest amount, and those funds have been distributed to the investor. The borrower is offered two correction options:

- **Option A: Refund** — The servicer deposits funds to cover the refund (absorbing the loss as an error correction). The borrower receives a cash refund.
- **Option B: Principal Reduction** — The overpayment is applied as a reduction to the borrower's outstanding principal. No cash movement.

In both options, the investor's $50 excess is reclassified from interest income to principal return on the books (no cash clawed back from the investor). This may have tax implications for the investor, as principal returns are generally not taxable income whereas interest income is.

### Phase 1: Origination

#### Ledger Entries

| #   | Transaction                       | Debit                         | Credit                     | Amount  |
| :-- | :-------------------------------- | :---------------------------- | :------------------------- | :------ |
| 1   | Create loan commitment            | Borrower Principal Receivable | Unfunded Commitment        | $10,000 |
| 2   | Withhold origination fee          | Unfunded Commitment           | Originator Fee Payable     | $100    |
| 3   | Receive investor funds            | Cash                          | Investor Principal Payable | $10,000 |
| 4   | Disburse to borrower (net of fee) | Unfunded Commitment           | Cash                       | $9,900  |
| 5   | Pay originator                    | Originator Fee Paid           | Cash                       | $100    |

<details>
<summary>Balance Sheet</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY           | Amount      |
| :------------------------------ | :---------- | :----------------------------- | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable     | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid  | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**     | **$10,000** |
| **Total Assets**                | **$10,000** | **Total Liabilities + Equity** | **$10,000** |

</details>

---

### Phase 2: Erroneous Accrual ($150 total when $100 was owed)

**Error:** $150 of borrower obligation was incorrectly accrued when only $100 was actually owed ($90 interest + $10 servicer fee).

#### Ledger Entries

| #   | Transaction                            | Debit                        | Credit                                | Amount |
| :-- | :------------------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 6   | Accrue borrower obligation (INCORRECT) | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $150   |

<details>
<summary>Balance Sheet (After Erroneous Accrual)</summary>

| ASSETS                          | Amount      | LIABILITIES & EQUITY                  | Amount      |
| :------------------------------ | :---------- | :------------------------------------ | :---------- |
| Borrower Principal Receivable   | $10,000     | Investor Principal Payable            | $10,000     |
| Less: Borrower Principal Repaid | $0          | Less: Investor Principal Paid         | $0          |
| **Net Loans Receivable**        | **$10,000** | **Net Investor Principal**            | **$10,000** |
| Borrower Interest Receivable    | $150        | Unallocated Borrower Interest Payable | $150        |
| Less: Borrower Interest Paid    | $0          |                                       |             |
| **Net Interest Receivable**     | **$150**    |                                       |             |
| **Total Assets**                | **$10,150** | **Total Liabilities + Equity**        | **$10,150** |

</details>

---

### Phase 3: Borrower Payment & Payout (Erroneous Amount)

The borrower pays $650 ($500 principal + $150 interest/fees based on incorrect accrual). Funds are allocated and distributed to the investor and servicer.

#### Phase 3.a: Receive Payment

| #   | Transaction     | Debit | Credit                    | Amount |
| :-- | :-------------- | :---- | :------------------------ | :----- |
| 7   | Receive payment | Cash  | Borrower Payment Clearing | $650   |

#### Phase 3.b: Allocate & Clear Debts

Assuming the incorrect allocation was $140 to investor interest and $10 to servicer fee:

| #   | Transaction           | Debit                                 | Credit                    | Amount |
| :-- | :-------------------- | :------------------------------------ | :------------------------ | :----- |
| 8   | Allocate servicer fee | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $10    |
| 9   | Allocate to investor  | Unallocated Borrower Interest Payable | Investor Interest Payable | $140   |
| 10  | Clear interest debt   | Borrower Payment Clearing             | Borrower Interest Paid    | $150   |
| 11  | Clear principal debt  | Borrower Payment Clearing             | Borrower Principal Repaid | $500   |

#### Phase 3.c: Pay Out Parties

| #   | Transaction                      | Debit                   | Credit | Amount |
| :-- | :------------------------------- | :---------------------- | :----- | :----- |
| 12  | Pay servicer                     | Servicer Fee Paid       | Cash   | $10    |
| 13  | Distribute interest to investor  | Investor Interest Paid  | Cash   | $140   |
| 14  | Distribute principal to investor | Investor Principal Paid | Cash   | $500   |

<details>
<summary>Balance Sheet (After Payment & Payout)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $140       |
| Borrower Interest Receivable    | $150       | Less: Investor Interest Paid          | ($140)     |
| Less: Borrower Interest Paid    | ($150)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

---

### Phase 4 (Option A): Refund Borrower

**Correction:** The over-accrual is discovered after payment and distribution. The servicer deposits $50 to fund the borrower refund (absorbing the loss). The investor's excess is reclassified from interest to principal on the books — no cash is clawed back from the investor.

The correct allocation should have been: $90 to investor interest, $10 to servicer fee. The investor received $140 instead of $90 — an excess of $50.

#### Correction Ledger Entries

| #   | Transaction                        | Debit                                 | Credit                                | Amount | Entry Type                        |
| :-- | :--------------------------------- | :------------------------------------ | :------------------------------------ | :----- | :-------------------------------- |
| 15  | Reverse over-accrual               | Unallocated Borrower Interest Payable | Borrower Interest Receivable          | $50    | `ENTRY_INTEREST_REVERSAL`         |
| 16  | Reverse investor allocation excess | Investor Interest Payable             | Unallocated Borrower Interest Payable | $50    | `ENTRY_INTEREST_REVERSAL`         |
| 17  | Reclassify investor payout         | Investor Principal Paid               | Investor Interest Paid                | $50    | `ENTRY_INTEREST_RECLASSIFICATION` |
| 18  | Servicer deposits for correction   | Cash                                  | Servicer Adjustment                   | $50    | `ENTRY_ADJUSTMENT`                |
| 19  | Refund borrower                    | Borrower Interest Paid                | Cash                                  | $50    | `ENTRY_BORROWER_REFUND`           |

<details>
<summary>Balance Sheet (After Correction - Option A)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($550)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,450** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $100       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
|                                 |            | Servicer Adjustment                   | $50        |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

> **Note:** The borrower is fully refunded. The `Servicer Adjustment` account ($50) is a permanent record of the servicer absorbing the loss for the accrual error. The investor's payout is reclassified from interest to principal on the books (no cash movement from investor).

---

### Phase 4 (Option B): Apply Overpayment as Principal Reduction

**Correction:** The over-accrual is discovered after payment and distribution. The $50 excess the borrower paid is applied as a reduction to their outstanding principal. No cash movement required.

The correct allocation should have been: $90 to investor interest, $10 to servicer fee. The investor received $140 instead of $90 — an excess of $50.

#### Correction Ledger Entries

| #   | Transaction                             | Debit                                 | Credit                                | Amount | Entry Type                        |
| :-- | :-------------------------------------- | :------------------------------------ | :------------------------------------ | :----- | :-------------------------------- |
| 15  | Reverse over-accrual                    | Unallocated Borrower Interest Payable | Borrower Interest Receivable          | $50    | `ENTRY_INTEREST_REVERSAL`         |
| 16  | Apply overpayment to borrower principal | Borrower Interest Paid                | Borrower Principal Repaid             | $50    | `ENTRY_INTEREST_RECLASSIFICATION` |
| 17  | Reverse investor allocation excess      | Investor Interest Payable             | Unallocated Borrower Interest Payable | $50    | `ENTRY_INTEREST_REVERSAL`         |
| 18  | Reclassify investor payout to principal | Investor Principal Paid               | Investor Interest Paid                | $50    | `ENTRY_INTEREST_RECLASSIFICATION` |

**Explanation of entries:**

- **Entry 15:** Reverses the $50 over-accrual, reducing Borrower Interest Receivable from $150 to $100 and Unallocated from $0 to ($50).
- **Entry 16:** Reclassifies $50 of already-paid borrower interest to principal, reducing Borrower Interest Paid from ($150) to ($100) and increasing Borrower Principal Repaid from ($500) to ($550).
- **Entry 17:** Reverses the $50 excess allocated to investor interest, reducing Investor Interest Payable from $140 to $90 and restoring Unallocated to $0.
- **Entry 18:** Reclassifies $50 already paid to investor from interest to principal (no cash movement).

<details>
<summary>Balance Sheet (After Correction - Option B)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($550)     |
| Less: Borrower Principal Repaid | ($550)     | **Net Investor Principal**            | **$9,450** |
| **Net Principal Receivable**    | **$9,450** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $100       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,450** | **Total Liabilities + Equity**        | **$9,450** |

</details>

**Result:** The borrower's outstanding principal is reduced from $9,500 to $9,450, reflecting that their $50 overpayment has been credited toward their loan balance. Net Interest Receivable is $0 because the $50 excess interest payment has been reclassified to principal.
