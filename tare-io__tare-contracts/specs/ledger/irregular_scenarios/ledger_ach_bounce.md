# ACH Bounce / NSF Fee Accounting

This document covers how to handle a borrower payment that bounces (e.g., NSF - Non-Sufficient Funds) before settlement. Since off-chain payment is not tracked on the ledger, a bounce before on-chain settlement simply means the payment never arrived — no reversal entries are needed. The only action is to assess an NSF fee.

For disputes that occur after on-chain settlement and distribution, see the ACH Return note in the [index](index.md).

---

## Starting Point: After Phase 3 of Happy Path

_This scenario continues from Phase 3 of [ledger_e2e_example.md](../ledger_e2e_example.md). The borrower initiates a second $600 ACH payment but it bounces before funds arrive on-chain._

<details>
<summary>Balance Sheet (Before Bounce - Same as Phase 3)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $100       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
|                                 |            | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
| **Total Assets**                | **$9,500** | **Total Liabilities + Equity**        | **$9,500** |

</details>

---

## Bounce Detected (NSF Fee Assessment)

**Scenario:** The borrower's ACH payment bounces (NSF) before funds are settled on-chain. Since no ledger entries were recorded for the pending payment, there is nothing to reverse. The only action is to assess an NSF fee.

### Ledger Entries

| #   | Transaction    | Debit                        | Credit                    | Amount |
| :-- | :------------- | :--------------------------- | :------------------------ | :----- |
| 1   | Assess NSF fee | Borrower Misc Fee Receivable | Servicer Misc Fee Payable | $15    |

<details>
<summary>Balance Sheet (After NSF Fee Assessment)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $100       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
| Borrower Misc Fee Receivable    | $15        | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
|                                 |            | Servicer Misc Fee Payable             | $15        |
|                                 |            | Less: Servicer Misc Fee Paid          | $0         |
|                                 |            | **Net Servicer Misc Fees**            | **$15**    |
| **Total Assets**                | **$9,515** | **Total Liabilities + Equity**        | **$9,515** |

</details>

The borrower now owes an additional $15 NSF fee, which will be collected in the next payment via the waterfall (Misc Fees have highest priority).

---

## New Accrual After Bounce

Interest and servicer fees continue to accrue. Before the next payment, $100 of new obligation accrues ($90 interest + $10 servicer fee).

### Ledger Entries

| #   | Transaction                | Debit                        | Credit                                | Amount |
| :-- | :------------------------- | :--------------------------- | :------------------------------------ | :----- |
| 2   | Accrue borrower obligation | Borrower Interest Receivable | Unallocated Borrower Interest Payable | $100   |

<details>
<summary>Balance Sheet (After New Accrual)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($500)     |
| Less: Borrower Principal Repaid | ($500)     | **Net Investor Principal**            | **$9,500** |
| **Net Principal Receivable**    | **$9,500** | Investor Interest Payable             | $90        |
| Borrower Interest Receivable    | $200       | Less: Investor Interest Paid          | ($90)      |
| Less: Borrower Interest Paid    | ($100)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$100**   | Unallocated Borrower Interest Payable | $100       |
| Borrower Misc Fee Receivable    | $15        | Servicer Fee Payable                  | $10        |
|                                 |            | Less: Servicer Fee Paid               | ($10)      |
|                                 |            | **Net Servicer Fees**                 | **$0**     |
|                                 |            | Servicer Misc Fee Payable             | $15        |
|                                 |            | Less: Servicer Misc Fee Paid          | $0         |
|                                 |            | **Net Servicer Misc Fees**            | **$15**    |
| **Total Assets**                | **$9,615** | **Total Liabilities + Equity**        | **$9,615** |

</details>

---

## Next Payment ($615) - NSF Fee Collected via Waterfall

**Scenario:** Borrower pays $615. The waterfall allocates:

1. **$15 to NSF fee** (Misc Fee - highest priority)
2. **$10 to servicer fee**
3. **$90 to interest**
4. **$500 to principal** (remainder)

### Phase A: Receive Payment

| #   | Transaction     | Debit | Credit                    | Amount |
| :-- | :-------------- | :---- | :------------------------ | :----- |
| 3   | Receive payment | Cash  | Borrower Payment Clearing | $615   |

### Phase B: Allocate & Clear Debts

| #   | Transaction           | Debit                                 | Credit                    | Amount |
| :-- | :-------------------- | :------------------------------------ | :------------------------ | :----- |
| 4   | Allocate servicer fee | Unallocated Borrower Interest Payable | Servicer Fee Payable      | $10    |
| 5   | Allocate to investor  | Unallocated Borrower Interest Payable | Investor Interest Payable | $90    |
| 6   | Clear misc fee debt   | Borrower Payment Clearing             | Borrower Misc Fee Paid    | $15    |
| 7   | Clear interest debt   | Borrower Payment Clearing             | Borrower Interest Paid    | $100   |
| 8   | Clear principal debt  | Borrower Payment Clearing             | Borrower Principal Repaid | $500   |

### Phase C: Pay Out Parties

| #   | Transaction                      | Debit                   | Credit | Amount |
| :-- | :------------------------------- | :---------------------- | :----- | :----- |
| 9   | Pay servicer (svc fees)          | Servicer Fee Paid       | Cash   | $10    |
| 10  | Pay servicer (misc fees)         | Servicer Misc Fee Paid  | Cash   | $15    |
| 11  | Distribute interest to investor  | Investor Interest Paid  | Cash   | $90    |
| 12  | Distribute principal to investor | Investor Principal Paid | Cash   | $500   |

<details>
<summary>Balance Sheet (After Payment)</summary>

| ASSETS                          | Amount     | LIABILITIES & EQUITY                  | Amount     |
| :------------------------------ | :--------- | :------------------------------------ | :--------- |
| Cash                            | $0         | Investor Principal Payable            | $10,000    |
| Borrower Principal Receivable   | $10,000    | Less: Investor Principal Paid         | ($1,000)   |
| Less: Borrower Principal Repaid | ($1,000)   | **Net Investor Principal**            | **$9,000** |
| **Net Principal Receivable**    | **$9,000** | Investor Interest Payable             | $180       |
| Borrower Interest Receivable    | $200       | Less: Investor Interest Paid          | ($180)     |
| Less: Borrower Interest Paid    | ($200)     | **Net Investor Interest**             | **$0**     |
| **Net Interest Receivable**     | **$0**     | Unallocated Borrower Interest Payable | $0         |
| Borrower Misc Fee Receivable    | $15        | Servicer Fee Payable                  | $20        |
| Less: Borrower Misc Fee Paid    | ($15)      | Less: Servicer Fee Paid               | ($20)      |
| **Net Borrower Misc Fees**      | **$0**     | **Net Servicer Fees**                 | **$0**     |
|                                 |            | Servicer Misc Fee Payable             | $15        |
|                                 |            | Less: Servicer Misc Fee Paid          | ($15)      |
|                                 |            | **Net Servicer Misc Fees**            | **$0**     |
| **Total Assets**                | **$9,000** | **Total Liabilities + Equity**        | **$9,000** |

</details>

The NSF fee has been fully collected. All Misc Fee accounts are cleared.

---

## Notes

### Loan Status Impact

When a payment bounces, the loan remains in its current state since no payment was recorded. If the borrower was expecting this payment to bring them current, they remain delinquent. DPD (Days Past Due) continues to accrue.

### Single NSF Fee Per Bounce

Only one NSF fee can be assessed per bounced payment attempt. Tare's backend must track which payment attempts have been assessed to prevent double-charging.
