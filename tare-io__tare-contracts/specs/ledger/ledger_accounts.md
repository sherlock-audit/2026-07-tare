### Chart of Accounts

Accounts are defined as `uint8` constants in `contracts/interfaces/Accounts.sol`. The values are grouped by sign behavior:

- **100-199**: Normally positive (Assets, Contra-Liabilities, Expenses)
- **200-255**: Normally negative (Liabilities, Contra-Assets, Revenue)

> Note: Account values are stored as `uint8`, limiting the max value to 255.

Use `account >= 200` to check if an account is normally negative.

### 1. Assets (100-149)

| Constant                            | Value | Description                                                              |
| :---------------------------------- | :---- | :----------------------------------------------------------------------- |
| `ACC_CASH`                          | 100   | Currency held in the contract available for disbursement or distribution |
| `ACC_BORROWER_PRINCIPAL_RECEIVABLE` | 101   | The gross amount lent to the borrower that is expected to be repaid      |
| `ACC_BORROWER_INTEREST_RECEIVABLE`  | 102   | Interest accrued on the loan but not yet collected from the borrower     |
| `ACC_BORROWER_MISC_FEE_RECEIVABLE`  | 103   | Misc fees (late/NSF) charged to borrower but not yet collected           |

### 2. Contra-Liabilities (150-199)

| Constant                        | Value | Description                                |
| :------------------------------ | :---- | :----------------------------------------- |
| `ACC_INVESTOR_PRINCIPAL_REPAID` | 150   | Cumulative principal returned to investors |
| `ACC_INVESTOR_INTEREST_PAID`    | 151   | Cumulative funding costs paid to investors |
| `ACC_SERVICER_FEE_PAID`         | 152   | Cumulative servicing fees paid out         |
| `ACC_ORIGINATOR_FEE_PAID`       | 153   | Cumulative originator fees paid out        |
| `ACC_SERVICER_MISC_FEE_PAID`    | 154   | Cumulative misc fees paid to servicer      |

### 3. Liabilities (200-249)

| Constant                                    | Value | Description                                                                                                  |
| :------------------------------------------ | :---- | :----------------------------------------------------------------------------------------------------------- |
| `ACC_UNFUNDED_COMMITMENT`                   | 200   | Obligation to disburse loan proceeds to the borrower after loan is approved                                  |
| `ACC_BORROWER_PAYMENT_CLEARING`             | 201   | Temporary staging account that accumulates borrower payments before distribution                             |
| `ACC_INVESTOR_PRINCIPAL_PAYABLE`            | 202   | Gross investor capital that must ultimately be returned to investors                                         |
| `ACC_INVESTOR_INTEREST_PAYABLE`             | 203   | Interest/returns owed to investors for their capital                                                         |
| `ACC_SERVICER_FEE_PAYABLE`                  | 204   | Obligation to pay the servicer                                                                               |
| `ACC_ORIGINATOR_FEE_PAYABLE`                | 205   | Obligation to pay the originator their origination fee                                                       |
| `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE` | 206   | Staging account for accrued borrower obligations before waterfall allocation                                 |
| `ACC_SERVICER_MISC_FEE_PAYABLE`             | 207   | Obligation to pay the servicer for misc fees (late/NSF)                                                      |
| `ACC_SERVICER_ADJUSTMENT`                   | 208   | Permanent record of servicer-funded adjustments (e.g., borrower refunds when excess was already distributed) |

### 4. Contra-Assets (250-255)

| Constant                        | Value | Description                                                                   |
| :------------------------------ | :---- | :---------------------------------------------------------------------------- |
| `ACC_BORROWER_PRINCIPAL_REPAID` | 250   | Cumulative principal payments received, reducing the net principal receivable |
| `ACC_BORROWER_INTEREST_PAID`    | 251   | Cumulative interest and fee payments cleared from borrower obligations        |
| `ACC_BORROWER_MISC_FEE_PAID`    | 252   | Cumulative misc fee payments cleared from borrower obligations                |
