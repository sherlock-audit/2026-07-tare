// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";

/**
 * @notice Per-loan role identifiers used by the address-book authorization layer.
 * @dev Each role's bit position is determined by enum order and the address-book
 *      bitmask stored in `ILoansAuth.addressBook`.
 */
enum Roles {
  Borrower,
  Originator,
  Investor,
  Servicer
}

/**
 * @notice Loan lifecycle status.
 */
enum LoanStatus {
  DoesNotExist, // 0 - Sentinel value (used as "no change" in updateLoanData)
  Created, // 1 - Loan created, awaiting funding
  FullyFunded, // 2 - Fully funded, awaiting disbursement
  Active, // 3 - Disbursed and performing
  FullyPaid, // 4 - Borrower paid in full
  Cancelled, // 5 - Cancelled before disbursement
  ChargedOff, // 6 - Written off as bad debt
  Closed // 7 - No further activity expected
}

/**
 * @notice Immutable ledger record of a single account-to-account transfer.
 * @dev Every state-changing financial operation in `Loans` produces at least one `Entry`.
 *      `from` and `to` are `Account` enum values cast to `uint8`.
 *      `entryType` is one of the constants in `LedgerEntries.sol`.
 */
struct Entry {
  int128 amount;
  uint48 timestamp;
  uint8 from;
  uint8 to;
  uint16 entryType;
  bytes32 ref;
}

/**
 * @notice Mutable per-loan status and date fields, updated through the loan lifecycle.
 */
struct LoanData {
  LoanStatus status;
  uint48 updatedAt;
  uint48 lastPaymentDate;
  uint48 nextDueDate;
  uint48 maturityDate;
}

/**
 * @notice Loan terms, set at `disburse`.
 * Can be edited thereafter via `updateLoanTerms` for edge cases.
 */
struct LoanTerms {
  /// @notice Loan origination date
  uint48 originationDate;
  /// @notice Annual interest rate in basis points (500 = 5.00%), 30/360 day-count convention.
  uint32 interestRate;
  /// @notice Expected monthly payment amount (currency base units).
  int128 expectedMonthlyPayment;
}

/**
 * @notice Per-loan breakdown returned by `investorWithdraw` for
 *         each loan cashflows withdrawal processed.
 */
struct InvestorWithdrawalResult {
  uint64 loanId;
  int128 principal;
  int128 interest;
}

/**
 * @notice Per-loan amount returned by `originatorWithdraw` for each loan processed.
 */
struct OriginatorWithdrawalResult {
  uint64 loanId;
  int128 amount;
}

/**
 * @notice Per-loan breakdown returned by `servicerWithdraw` for each loan processed.
 */
struct ServicerWithdrawalResult {
  uint64 loanId;
  int128 miscFee;
  int128 servicingFee;
}

/**
 * @notice Aggregated valuation snapshot returned by `getLoanValues`.
 */
struct LoanValue {
  /**
   * @notice Investor capital deployed and not yet returned:
   *         `-ACC_INVESTOR_PRINCIPAL_PAYABLE - ACC_INVESTOR_PRINCIPAL_REPAID`.
   * @dev Includes both the portion still out with the borrower and the portion already sitting
   *      as withdrawable cash in `Loans.sol`.
   */
  int128 outstandingInvestorPrincipal;
  /// @notice Principal cash held in Loans.sol for the investor, awaiting withdrawal.
  int128 investorPrincipalWithdrawable;
  /// @notice Waterfall-allocated interest cash held in Loans.sol for the investor, awaiting withdrawal.
  int128 investorInterestWithdrawable;
  LoanStatus status;
  uint48 nextDueDate;
}

/**
 * @notice Input describing a single ledger entry passed to `createLedgerEntries`.
 */
struct LedgerEntryInput {
  uint8 from;
  uint8 to;
  int128 amount;
  uint16 entryType;
  bytes32 ref;
}

/**
 * @title ILoans
 * @notice Core Tare lending protocol interface: loan lifecycle, double-entry ledger entries,
 *         per-role authorization, and cash custody for each loan.
 */
interface ILoans {
  /** @notice Thrown when a loan id does not correspond to a created loan. */
  error DoesNotExist();
  /** @notice Thrown when an account id is outside the supported `Account` range. */
  error InvalidAccount();
  /** @notice Thrown when an amount is zero, negative, or otherwise outside the allowed bounds. */
  error InvalidAmount();
  /** @notice Thrown when a supplied date is invalid (e.g. zero where required). */
  error InvalidDate();
  /** @notice Thrown when the loan's cash account balance is insufficient for a transfer. */
  error InsufficientCashBalance();
  /** @notice Thrown when `msg.sender` is not authorized for the attempted operation. */
  error Unauthorized();
  /** @notice Thrown when a zero address is supplied where one is not permitted. */
  error ZeroAddress();
  /** @notice Thrown when the supplied role is invalid for the requested operation. */
  error InvalidRole();
  /** @notice Thrown when the loan's current status disallows the requested operation. */
  error InvalidStatus();
  /** @notice Thrown when `netDisbursedAmount + originationFee` does not equal the loan commitment. */
  error InvalidAmountDisbursed();
  /** @notice Thrown when `disburse` is attempted before the loan has been fully funded. */
  error NotFullyFunded();
  /** @notice Thrown when a deposit would exceed the loan's outstanding commitment. */
  error ExceedsCommitment();
  /** @notice Thrown when an allocation would exceed a payable account's outstanding balance. */
  error ExceedsPayable();
  /** @notice Thrown when attempting to initialize a singleton-style pointer that is already set. */
  error AlreadyInitialized();
  /** @notice Thrown when an action is attempted on a loan whose NFT is currently locked. */
  error LoanLocked();

  /** @notice Emitted when a new loan is created. */
  event LoanCreated(uint64 indexed loanId);

  /**
   * @notice Emitted for every ledger entry written by the contract.
   * @param entryIndex Packed entry id: `uint128(loanId) << 64 | entryNumber`.
   * @param from The source account id.
   * @param to The destination account id.
   * @param amount The signed amount transferred from `from` to `to`.
   * @param updatedFromBalance Balance of `from` after the transfer.
   * @param updatedToBalance Balance of `to` after the transfer.
   * @param entryType Entry type constant (see `interfaces/LedgerEntries.sol`).
   * @param ref Caller-supplied external reference.
   */
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

  event LoanBorrowerUpdated(uint64 indexed loanId, address indexed borrower);
  event LoanServicerUpdated(uint64 indexed loanId, address indexed servicer);

  /** @notice Emitted when the loan status changes via `updateLoanData` or an automatic transition. */
  event LoanStatusUpdated(uint64 indexed loanId, LoanStatus oldStatus, LoanStatus newStatus);
  event LoanNextDueDateUpdated(uint64 indexed loanId, uint48 nextDueDate);
  event LoanMaturityDateUpdated(uint64 indexed loanId, uint48 maturityDate);

  /** @notice Emitted when loan terms are set during `disburse` or subsequently changed via `updateLoanTerms`. */
  event LoanTermsSet(uint64 indexed loanId, uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment);

  /** @notice Emitted when `pay` records a borrower payment. */
  event LoanLastPaymentDateUpdated(uint64 indexed loanId, uint48 lastPaymentDate);

  /** @notice Total number of loans ever created. Equals the highest loan id, since ids start at 1. */
  function loanCount() external view returns (uint64);

  /**
   * @notice Returns the mutable loan data for `loanId`.
   * @param loanId The loan identifier.
   */
  function data(
    uint64 loanId
  )
    external
    view
    returns (LoanStatus status, uint48 updatedAt, uint48 lastPaymentDate, uint48 nextDueDate, uint48 maturityDate);

  /**
   * @notice Returns the loan terms for `loanId`. Zeroed until `disburse` runs; mutable thereafter
   *         via `updateLoanTerms`.
   * @param loanId The loan identifier.
   */
  function loanTerms(
    uint64 loanId
  ) external view returns (uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment);

  /** @notice Returns the registered borrower address for `loanId`. */
  function borrowers(uint64 loanId) external view returns (address);

  /** @notice Returns the registered originator address for `loanId`. */
  function originators(uint64 loanId) external view returns (address);

  /** @notice Returns the registered servicer address for `loanId`. */
  function servicers(uint64 loanId) external view returns (address);

  /** @notice Returns the ERC20 token used for all financial operations. */
  function currency() external view returns (IERC20);

  /**
   * @notice Returns the signed balance for a packed `(loanId, account)` key.
   * @dev `key = uint72(loanId) << 8 | uint8(account)`. Prefer `getLoanAccountBalance`.
   */
  function accountBalances(uint72 key) external view returns (int128);

  /**
   * @notice Returns the immutable entry stored at the packed `entryIndex`.
   * @param entryIndex Packed entry id: `uint128(loanId) << 64 | entryNumber`.
   */
  function entries(
    uint128 entryIndex
  ) external view returns (int128 amount, uint48 timestamp, uint8 from, uint8 to, uint16 entryType, bytes32 ref);

  /** @notice Returns the number of entries recorded for `loanId`. */
  function entryCount(uint64 loanId) external view returns (uint64);

  /** @notice Returns the linked `LoansNFT` contract used to track investor ownership. */
  function loansNFT() external view returns (ILoansNFT);

  /**
   * @notice One-shot initializer that links the `LoansNFT` contract. Admin or guardian only.
   * @dev Reverts if already initialized.
   * @param _loansNFT The `LoansNFT` contract address.
   */
  function setLoansNFT(address _loansNFT) external;

  /**
   * @notice Create a new loan in `Created` status and mint its investor a loan NFT.
   * @dev Caller must be the named `originator` (and an approved originator) or admin/guardian.
   *      All four addresses must be registered in `originator`'s address book for their roles.
   *      Records `ENTRY_LOAN_COMMITMENT` transferring `principalAmount`
   *      from `ACC_UNFUNDED_COMMITMENT` to `ACC_BORROWER_PRINCIPAL_RECEIVABLE`.
   * @param borrower The borrower address.
   * @param investor The investor address (receives the loan NFT).
   * @param servicer The servicer address.
   * @param originator The originator address.
   * @param principalAmount The loan principal commitment.
   * @param timestamp The off-chain origination timestamp recorded on the entry.
   * @return loanId The new loan identifier.
   */
  function create(
    address borrower,
    address investor,
    address servicer,
    address originator,
    int128 principalAmount,
    uint48 timestamp
  ) external returns (uint64 loanId);

  /**
   * @notice Fund a loan in `Created` status by pulling currency from the investor.
   * @dev Caller must be the current NFT owner (investor) or admin/guardian.
   *      The deposit must equal the full outstanding commitment in a single call;
   *      on success the loan transitions to `FullyFunded`.
   * @param loanId The loan identifier.
   * @param amount The principal amount to fund (must equal commitment).
   * @param timestamp The off-chain funding timestamp recorded on the entry.
   * @param ref Caller-supplied external reference.
   * @return entryIndex The packed entry id of the recorded deposit.
   */
  function fund(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external returns (uint128 entryIndex);

  /**
   * @notice Disburse funded capital to the borrower and lock in the loan's write-once terms.
   * @dev Caller must be the loan's originator or admin/guardian. Loan must be `FullyFunded`.
   *      `netDisbursedAmount + originationFee` must equal the outstanding commitment.
   *      Withholds `originationFee` to `ACC_ORIGINATOR_FEE_PAYABLE`, transfers `netDisbursedAmount`
   *      to the borrower, and transitions the loan to `Active`.
   * @param loanId The loan identifier.
   * @param netDisbursedAmount Amount sent to the borrower (net of origination fee).
   * @param originationFee Fee withheld for the originator (may be zero).
   * @param originationDate Loan origination date stored in `LoanTerms`.
   * @param nextDueDate Initial next payment due date (0 leaves unchanged).
   * @param maturityDate Loan maturity date (0 leaves unchanged).
   * @param interestRate Annual interest rate in basis points.
   * @param expectedMonthlyPayment Expected monthly payment (currency base units).
   * @param timestamp The off-chain disbursement timestamp recorded on the entries.
   * @param ref Caller-supplied external reference.
   * @return entryIndex The packed entry id of the borrower disbursement entry.
   */
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
  ) external returns (uint128 entryIndex);

  /**
   * @notice Record an interest/fee accrual against the borrower. Servicer or admin only.
   * @dev Records `ENTRY_INTEREST_ACCRUAL` transferring `amount` from
   *      `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE` to `ACC_BORROWER_INTEREST_RECEIVABLE`.
   *      The split between servicer fees and investor interest happens later in `applyWaterfall`.
   * @param loanId The loan identifier.
   * @param amount The total obligation to accrue (interest + fees combined).
   * @param timestamp The off-chain accrual timestamp recorded on the entry.
   * @param ref Caller-supplied external reference.
   */
  function accrue(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external;

  /**
   * @notice Record a borrower payment by pulling currency from the registered borrower address.
   * @dev Caller must be the registered borrower or admin. Loan must be `Active` or `ChargedOff`.
   * @param loanId The loan identifier.
   * @param amount The payment amount.
   * @param timestamp The off-chain payment timestamp recorded on the entry.
   * @param ref Caller-supplied external reference.
   * @return entryIndex The packed entry id of the payment.
   */
  function pay(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external returns (uint128 entryIndex);

  /**
   * @notice Charge a miscellaneous fee against the borrower. Servicer or admin only.
   * @dev Records `ENTRY_MISC_FEE_CHARGE` transferring `amount` from
   *      `ACC_SERVICER_MISC_FEE_PAYABLE` to `ACC_BORROWER_MISC_FEE_RECEIVABLE`.
   * @param loanId The loan identifier.
   * @param amount The fee amount (must be positive).
   * @param timestamp The off-chain charge timestamp recorded on the entry.
   * @param ref Caller-supplied external reference.
   */
  function chargeMiscFee(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external;

  /**
   * @notice Allocate a borrower payment across misc fees, servicer fees, investor interest, and principal.
   * @dev Servicer or admin only. Loan must be `Active`, `ChargedOff`, or `FullyPaid`.
   *      Generates a sequence of clearance entries from `ACC_BORROWER_PAYMENT_CLEARING` proportional to
   *      each positive allocation.
   * @param loanId The loan identifier.
   * @param miscFees Amount allocated to outstanding misc fees.
   * @param servicingFees Amount allocated to servicing fees.
   * @param investorInterest Amount allocated to investor interest.
   * @param principal Amount allocated to principal.
   * @param nextDueDate Optional new next payment due date (0 leaves unchanged).
   * @param timestamp The off-chain allocation timestamp recorded on each entry.
   * @param ref Caller-supplied external reference.
   */
  function applyWaterfall(
    uint64 loanId,
    int128 miscFees,
    int128 servicingFees,
    int128 investorInterest,
    int128 principal,
    uint48 nextDueDate,
    uint48 timestamp,
    bytes32 ref
  ) external;

  /**
   * @notice Withdraw all available principal and interest cash for a batch of loans.
   * @dev All loans in the batch must share the same investor (NFT owner) and the same
   *      lock state. If the NFTs are unlocked, caller must be the investor or admin/guardian
   *      and funds are sent to the investor. If the NFTs are locked, caller must be the
   *      shared unlocker and funds are sent to the caller.
   * @param loanIds The loan ids to withdraw from.
   * @param timestamp The off-chain timestamp recorded on each withdrawal entry.
   * @param ref Caller-supplied external reference.
   * @return Per-loan breakdown of the principal and interest amounts withdrawn.
   */
  function investorWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
  ) external returns (InvestorWithdrawalResult[] memory);

  /**
   * @notice Withdraw all servicer-owed cash (servicing fees and misc fees) for a batch of loans.
   * @dev For each loan: caller must be the registered servicer or admin.
   * @param loanIds The loan ids to withdraw from.
   * @param timestamp The off-chain timestamp recorded on each withdrawal entry.
   * @param ref Caller-supplied external reference.
   * @return Per-loan breakdown of the amounts withdrawn.
   */
  function servicerWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
  ) external returns (ServicerWithdrawalResult[] memory);

  /**
   * @notice Return funds previously paid out to a servicer-paid account back to `ACC_CASH`.
   * @dev Servicer or admin only. Loan must be `Active`, `ChargedOff`, or `FullyPaid`.
   *      Pulls currency from the registered servicer and credits the supplied `from` account.
   * @param loanId The loan identifier.
   * @param from The servicer-paid account being reversed.
   * @param amount The amount being returned (must be positive).
   * @param timestamp The off-chain timestamp recorded on the entry.
   * @param entryType Caller-supplied entry type tag for the correction.
   * @param ref Caller-supplied external reference.
   * @return entryIndex The packed entry id of the return.
   */
  function returnFunds(
    uint64 loanId,
    uint8 from,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  ) external returns (uint128 entryIndex);

  /**
   * @notice Withdraw all originator-owed cash for a batch of loans.
   * @dev For each loan: caller must be the registered originator or admin.
   * @param loanIds The loan ids to withdraw from.
   * @param timestamp The off-chain timestamp recorded on each withdrawal entry.
   * @param ref Caller-supplied external reference.
   * @return Per-loan breakdown of the amounts withdrawn.
   */
  function originatorWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
  ) external returns (OriginatorWithdrawalResult[] memory);

  /**
   * @notice Update the registered borrower address for `loanId`.
   * @dev Servicer or admin only. The new borrower must be registered in the servicer's address book.
   *      Loan must not be in a terminal status.
   * @param loanId The loan identifier.
   * @param borrower The new borrower address.
   */
  function updateBorrower(uint64 loanId, address borrower) external;

  /**
   * @notice Update the registered servicer address for `loanId`. Guardian only.
   * @dev The new servicer must be an approved Tare servicer. Loan must not be in a terminal status.
   * @param loanId The loan identifier.
   * @param servicer The new servicer address.
   */
  function updateServicer(uint64 loanId, address servicer) external;

  /**
   * @notice Update mutable loan data fields. Servicer or admin only.
   * @dev `DoesNotExist` for `status` and `0` for date fields are sentinels meaning "no change".
   * @param loanId The loan identifier.
   * @param status The new loan status (`DoesNotExist` = no change).
   * @param nextDueDate The next payment due date (0 = no change).
   * @param maturityDate The maturity date (0 = no change).
   * @param timestamp The off-chain timestamp recorded on the update.
   */
  function updateLoanData(
    uint64 loanId,
    LoanStatus status,
    uint48 nextDueDate,
    uint48 maturityDate,
    uint48 timestamp
  ) external;

  /**
   * @notice Update the loan terms set during `disburse`. Servicer or admin only.
   * @dev Loan must not be in a terminal status. `0` for any field is a sentinel meaning "no change",
   *      so `expectedMonthlyPayment` cannot be set to exactly `0` through this function.
   *      Emits `LoanTermsSet` with the resulting stored values.
   * @param loanId The loan identifier.
   * @param originationDate The origination date (0 = no change).
   * @param interestRate Annual interest rate in basis points (0 = no change).
   * @param expectedMonthlyPayment Expected monthly payment in currency base units (0 = no change).
   */
  function updateLoanTerms(
    uint64 loanId,
    uint48 originationDate,
    uint32 interestRate,
    int128 expectedMonthlyPayment
  ) external;

  /**
   * @notice Record one or more raw ledger entries against `loanId`. Servicer or Admin/Guardian only.
   * @dev Escape hatch for manual corrections. Each entry is validated against the standard
   *      account rules but bypasses higher-level lifecycle constraints.
   * @param loanId The loan identifier.
   * @param timestamp The off-chain timestamp recorded on every entry in the batch.
   * @param ledgerEntries The raw entries to write.
   * @return entryIndices The packed entry ids in batch order.
   */
  function createLedgerEntries(
    uint64 loanId,
    uint48 timestamp,
    LedgerEntryInput[] calldata ledgerEntries
  ) external returns (uint128[] memory entryIndices);

  /**
   * @notice Refund the borrower from cash held by the loan and credit a borrower-paid account.
   * @dev Servicer or admin only. Loan must be `Active`, `ChargedOff`, or `FullyPaid`.
   *      Transfers `amount` of currency to the registered borrower.
   * @param loanId The loan identifier.
   * @param toAccount The borrower-paid ledger account being reversed.
   * @param amount The refund amount (must be positive).
   * @param timestamp The off-chain timestamp recorded on the entry.
   * @param entryType Caller-supplied entry type tag for the correction.
   * @param ref Caller-supplied external reference.
   * @return entryIndex The packed entry id of the refund.
   */
  function refundBorrower(
    uint64 loanId,
    uint8 toAccount,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  ) external returns (uint128 entryIndex);

  /**
   * @notice Returns the raw signed balance of `account` for `loanId`.
   * @param loanId The loan identifier.
   * @param account The `Account` enum value cast to `uint8`.
   */
  function getLoanAccountBalance(uint64 loanId, uint8 account) external view returns (int128);

  /**
   * @notice Returns the balance of `account` for `loanId` normalized so all balances are non-negative.
   * @dev Liability/Revenue accounts are sign-flipped relative to `getLoanAccountBalance`.
   * @param loanId The loan identifier.
   * @param account The `Account` enum value cast to `uint8`.
   */
  function getLoanAccountBalanceNormalized(uint64 loanId, uint8 account) external view returns (int128);

  /**
   * @notice Returns the entry stored at position `entryNumber` for `loanId`.
   * @param loanId The loan identifier.
   * @param entryNumber The per-loan entry index (0-based).
   */
  function getLoanEntry(uint64 loanId, uint64 entryNumber) external view returns (Entry memory);

  /**
   * @notice Returns a range of entries for `loanId`.
   * @param loanId The loan identifier.
   * @param startIndex Inclusive start of the per-loan entry index range.
   * @param endIndex Exclusive end of the per-loan entry index range.
   */
  function getLoanEntries(uint64 loanId, uint64 startIndex, uint64 endIndex) external view returns (Entry[] memory);

  /**
   * @notice Returns aggregated valuation data for a batch of loans.
   * @param loanIds The loan ids to look up. Entries for non-existent loans are returned zeroed.
   */
  function getLoanValues(uint64[] calldata loanIds) external view returns (LoanValue[] memory);
}
