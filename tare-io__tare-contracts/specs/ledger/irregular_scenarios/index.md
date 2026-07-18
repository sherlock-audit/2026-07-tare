# Irregular Scenarios

This index covers non-standard accounting scenarios that require special handling outside the normal loan lifecycle. Each scenario documents the ledger entries, balance sheet impacts, and any required contract functions.

For the standard loan lifecycle (origination → accrual → repayment), see [ledger_e2e_example.md](../ledger_e2e_example.md).

---

## Scenarios

### [Borrower Interest Over-Accrual Correction](ledger_borrower_interest_over-accrual.md)

Covers correction of erroneous interest accruals when too much interest was recorded.

- **Correction before payment** — reversing excess interest via negative accrual entries before borrower pays
- **Correction after payment (Option A: Refund)** — servicer deposits funds to cover refund (absorbs loss); borrower receives cash refund; investor excess reclassified on books
- **Correction after payment (Option B: Principal Reduction)** — overpayment applied as principal reduction; no cash movement

---

### [Servicer Fee Allocation & Waterfall Correction](ledger_waterfall_error.md)

Covers correction of waterfall allocation errors.

- **Correction before payment** — reversing excess servicer fees via negative accrual entries before borrower pays
- **Correction after payment (excess servicer fee only)** — applying a credit towards future servicer fees or returning excess to the borrower
- **Incorrect split (servicer too much, investor too little)** — servicer returns funds via `returnFunds()`, redistributed to investor
- **Reverse incorrect split (investor too much, servicer too little)** — accounting reclassification only, no cash movement, no investor clawback. Covers three sub-cases: investor interest too high, principal too high, or both

---

### [Late Fee Assessment & Waiver](ledger_late_fee.md)

Covers late fee accounting when a borrower misses a payment due date and how this late fee can be waived.

- **Late fee assessment** after grace period expires (Day 16+)
- **Late payment processing** with separate servicer fee and misc fee clearing
- **Alt A: Late fee waiver before payment** — servicer reverses the fee before borrower pays
- **Alt B: Late fee waiver after payment** — servicer issues credit against future servicer fees

---

### [ACH Bounce / Payment Reversal](ledger_ach_bounce.md)

Covers payment reversal when a borrower's ACH payment bounces (NSF) during the 4-day off-chain settlement period, before funds are bridged on-chain.

- NSF bounce detected before on-chain settlement
- Reversal of debt clearance entries
- NSF fee assessment ($15)

---

### ACH Return / Late Dispute (Post-Distribution)

If a borrower disputes and wins an ACH transfer after funds have been settled on-chain and distributed to the investor, no new ledger entries are written due to the complexity of correcting this scenario and because Cash is never clawed back from the investor. The original payment entries remain on the ledger as-is — they accurately recorded what happened on-chain. The financial loss (bank debiting the servicer's account) is absorbed and reconciled offchain, outside the loan ledger.

---
