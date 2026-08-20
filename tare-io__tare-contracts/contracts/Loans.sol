// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {Rescuable} from "contracts/misc/Rescuable.sol";
import {LoansLedger} from "./LoansLedger.sol";
import {
  ILoans,
  LoanData,
  LoanTerms,
  LoanStatus,
  Roles,
  InvestorWithdrawalResult,
  LoanValue,
  OriginatorWithdrawalResult,
  ServicerWithdrawalResult,
  LedgerEntryInput
} from "contracts/interfaces/ILoans.sol";
import {
  ENTRY_LOAN_COMMITMENT,
  ENTRY_INVESTOR_CAPITAL_RECEIVED,
  ENTRY_BORROWER_PAYMENT,
  ENTRY_INTEREST_ACCRUAL,
  ENTRY_BORROWER_PRINCIPAL_PAYMENT,
  ENTRY_DISBURSEMENT_TO_BORROWER,
  ENTRY_ORIGINATOR_FEE_WITHHOLDING,
  ENTRY_SERVICER_FEE_ALLOCATION,
  ENTRY_INVESTOR_INTEREST_ALLOCATION,
  ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE,
  ENTRY_SERVICER_FEE_WITHDRAWAL,
  ENTRY_INVESTOR_INTEREST_WITHDRAWAL,
  ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL,
  ENTRY_MISC_FEE_CHARGE,
  ENTRY_MISC_FEE_DEBT_CLEARANCE,
  ENTRY_MISC_FEE_WITHDRAWAL,
  ENTRY_ORIGINATOR_FEE_WITHDRAWAL
} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_BORROWER_INTEREST_PAID,
  ACC_BORROWER_MISC_FEE_PAID,
  ACC_BORROWER_INTEREST_RECEIVABLE,
  ACC_BORROWER_MISC_FEE_RECEIVABLE,
  ACC_BORROWER_PAYMENT_CLEARING,
  ACC_BORROWER_PRINCIPAL_RECEIVABLE,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_CASH,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_REPAID,
  ACC_ORIGINATOR_FEE_PAID,
  ACC_ORIGINATOR_FEE_PAYABLE,
  ACC_SERVICER_ADJUSTMENT,
  ACC_SERVICER_FEE_PAID,
  ACC_SERVICER_FEE_PAYABLE,
  ACC_SERVICER_MISC_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAYABLE,
  ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
  ACC_UNFUNDED_COMMITMENT
} from "contracts/interfaces/Accounts.sol";

/**
 * @title Loans
 * @notice Per-loan double-entry ledger and role-gated lifecycle: origination,
 *         funding, disbursement, accrual, payments, waterfall, and withdrawals.
 * @dev Custodies all loan-currency cash. Role addresses (borrower, originator,
 *      servicer) are per-loan; the loan investor is the holder of the NFT minted
 *      by `loansNFT`.
 */
contract Loans is LoansLedger, Rescuable, ReentrancyGuardTransient {
  using SafeERC20 for IERC20;

  /// @inheritdoc ILoans
  mapping(uint64 loanId => LoanData loanData) public data;

  /// @inheritdoc ILoans
  mapping(uint64 loanId => LoanTerms terms) public loanTerms;

  /// @inheritdoc ILoans
  mapping(uint64 loanId => address borrower) public borrowers;
  /// @inheritdoc ILoans
  mapping(uint64 loanId => address originator) public originators;
  /// @inheritdoc ILoans
  mapping(uint64 loanId => address servicer) public servicers;

  /// @inheritdoc ILoans
  ILoansNFT public loansNFT;

  modifier onlyServicerOrAdmin(uint64 loanId) {
    _onlyServicerOrAdmin(loanId);
    _;
  }

  modifier onlyBorrowerOrAdmin(uint64 loanId) {
    _onlyBorrowerOrAdmin(loanId);
    _;
  }

  modifier withLoanUpdate(uint64 loanId, uint48 timestamp) {
    _;
    _withLoanUpdate(loanId, timestamp);
  }

  modifier onlyOutstanding(uint64 loanId) {
    _onlyOutstanding(loanId);
    _;
  }

  modifier onlyOutstandingOrFullyPaid(uint64 loanId) {
    _onlyOutstandingOrFullyPaid(loanId);
    _;
  }

  modifier notTerminal(uint64 loanId) {
    _notTerminal(loanId);
    _;
  }

  constructor(
    IERC20 _currency,
    address initialGuardian,
    address initialRecoveryAddress
  ) LoansLedger(_currency, initialGuardian) {
    _initRecoveryAddress(initialRecoveryAddress);
  }

  /// @inheritdoc ILoans
  function setLoansNFT(address _loansNFT) external onlyAdminOrGuardian {
    require(address(loansNFT) == address(0), AlreadyInitialized());
    require(_loansNFT != address(0), ZeroAddress());
    loansNFT = ILoansNFT(_loansNFT);
  }

  function _create(
    address borrower,
    address investor,
    address servicer,
    address originator,
    int128 principalAmount,
    uint48 timestamp
  ) internal returns (uint64 loanId) {
    require(borrower != address(0), ZeroAddress());
    require(investor != address(0), ZeroAddress());
    require(servicer != address(0), ZeroAddress());
    require(originator != address(0), ZeroAddress());
    require(principalAmount > 0, InvalidAmount());

    // Validate addresses against originator's address book
    require(isRegisteredForRole(originator, Roles.Borrower, borrower), UnregisteredAddress(borrower));
    require(isRegisteredForRole(originator, Roles.Investor, investor), UnregisteredAddress(investor));
    require(isRegisteredForRole(originator, Roles.Servicer, servicer), UnregisteredAddress(servicer));

    loanId = ++loanCount;
    data[loanId].status = LoanStatus.Created;
    data[loanId].updatedAt = timestamp;

    borrowers[loanId] = borrower;
    servicers[loanId] = servicer;
    originators[loanId] = originator;

    loansNFT.mint(investor, loanId);

    _createInternalEntry(
      loanId,
      ACC_UNFUNDED_COMMITMENT,
      ACC_BORROWER_PRINCIPAL_RECEIVABLE,
      principalAmount,
      timestamp,
      ENTRY_LOAN_COMMITMENT,
      bytes32("initial_loan_commitment")
    );

    emit LoanCreated(loanId);
  }

  /// @inheritdoc ILoans
  function create(
    address borrower,
    address investor,
    address servicer,
    address originator,
    int128 principalAmount,
    uint48 timestamp
  ) external whenNotPaused returns (uint64 loanId) {
    // Admin/guardian may originate on behalf of any approved originator.
    // Otherwise msg.sender must be the named originator AND an approved one,
    // ensuring an approved originator cannot impersonate another originator.
    require(_isAdminOrGuardian(msg.sender) || msg.sender == originator, Unauthorized());
    require(isRegisteredForRole(address(this), Roles.Originator, originator), UnregisteredAddress(originator));

    return _create(borrower, investor, servicer, originator, principalAmount, timestamp);
  }

  /**
   * @inheritdoc ILoans
   * @dev Uses block.timestamp because the role change IS the onchain event,
   *      unlike ledger functions which record offchain facts at a caller-supplied date.
   */
  function updateBorrower(
    uint64 loanId,
    address borrower
  ) external whenNotPaused onlyServicerOrAdmin(loanId) notTerminal(loanId) {
    require(borrower != address(0), ZeroAddress());
    require(isRegisteredForRole(servicers[loanId], Roles.Borrower, borrower), UnregisteredAddress(borrower));

    borrowers[loanId] = borrower;
    data[loanId].updatedAt = uint48(block.timestamp);

    emit LoanBorrowerUpdated(loanId, borrower);
  }

  /**
   * @inheritdoc ILoans
   * @dev Uses block.timestamp because the role change IS the onchain event,
   *      unlike ledger functions which record offchain facts at a caller-supplied date.
   */
  function updateServicer(
    uint64 loanId,
    address servicer
  ) external whenNotPaused onlyRole(GUARDIAN_ROLE) notTerminal(loanId) {
    require(servicer != address(0), ZeroAddress());
    require(isRegisteredForRole(address(this), Roles.Servicer, servicer), UnregisteredAddress(servicer));

    servicers[loanId] = servicer;
    data[loanId].updatedAt = uint48(block.timestamp);

    emit LoanServicerUpdated(loanId, servicer);
  }

  /// @inheritdoc ILoans
  function updateLoanData(
    uint64 loanId,
    LoanStatus status,
    uint48 nextDueDate,
    uint48 maturityDate,
    uint48 timestamp
  ) external whenNotPaused onlyServicerOrAdmin(loanId) loanExists(loanId) withLoanUpdate(loanId, timestamp) {
    _updateLoanData(loanId, status, nextDueDate, maturityDate);
  }

  /**
   * @dev Updates mutable loan-data fields. Pass `DoesNotExist` as `status` or 0 as a date
   *      to leave that field unchanged. Emits `LoanStatusUpdated`, `LoanNextDueDateUpdated`,
   *      and `LoanMaturityDateUpdated` for each field that actually changed.
   */
  function _updateLoanData(uint64 loanId, LoanStatus status, uint48 nextDueDate, uint48 maturityDate) internal {
    LoanData storage loanData = data[loanId];

    // Only update if a valid status is provided (DoesNotExist is used as a sentinel value to indicate no change)
    if (status != LoanStatus.DoesNotExist) {
      LoanStatus oldStatus = loanData.status;
      loanData.status = status;
      emit LoanStatusUpdated(loanId, oldStatus, status);
    }

    if (nextDueDate > 0) {
      loanData.nextDueDate = nextDueDate;
      emit LoanNextDueDateUpdated(loanId, nextDueDate);
    }

    if (maturityDate > 0) {
      loanData.maturityDate = maturityDate;
      emit LoanMaturityDateUpdated(loanId, maturityDate);
    }
  }

  /**
   * @inheritdoc ILoans
   * @dev Uses block.timestamp to update the loan's `updatedAt` field.
   */
  function updateLoanTerms(
    uint64 loanId,
    uint48 originationDate,
    uint32 interestRate,
    int128 expectedMonthlyPayment
  ) external whenNotPaused onlyServicerOrAdmin(loanId) loanExists(loanId) notTerminal(loanId) {
    LoanTerms storage terms = loanTerms[loanId];

    // 0 is a sentinel meaning "no change" for each field.
    if (originationDate > 0) terms.originationDate = originationDate;
    if (interestRate > 0) terms.interestRate = interestRate;
    if (expectedMonthlyPayment > 0) terms.expectedMonthlyPayment = expectedMonthlyPayment;

    data[loanId].updatedAt = uint48(block.timestamp);

    emit LoanTermsSet(loanId, terms.originationDate, terms.interestRate, terms.expectedMonthlyPayment);
  }

  /**
   * @inheritdoc ILoans
   * @dev Caller must be the loan's registered borrower (`borrowers[loanId]`) or an admin.
   *      Tokens are pulled from the registered borrower address regardless of caller.
   */
  function pay(
    uint64 loanId,
    int128 amount,
    uint48 timestamp,
    bytes32 ref
  )
    external
    whenNotPaused
    onlyBorrowerOrAdmin(loanId)
    onlyOutstanding(loanId)
    nonReentrant
    withLoanUpdate(loanId, timestamp)
    returns (uint128 entryIndex)
  {
    data[loanId].lastPaymentDate = timestamp;
    emit LoanLastPaymentDateUpdated(loanId, timestamp);

    return
      _deposit(
        loanId,
        ACC_BORROWER_PAYMENT_CLEARING,
        amount,
        borrowers[loanId],
        timestamp,
        ENTRY_BORROWER_PAYMENT,
        ref
      );
  }

  /// @inheritdoc ILoans
  function getLoanValues(uint64[] calldata loanIds) external view returns (LoanValue[] memory results) {
    uint256 numLoans = loanIds.length;
    results = new LoanValue[](numLoans);

    for (uint256 i = 0; i < numLoans; ++i) {
      uint64 loanId = loanIds[i];
      if (loanId == 0 || loanId > loanCount) continue;

      LoanData storage loanData = data[loanId];
      results[i] = LoanValue({
        outstandingInvestorPrincipal: -_getAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE) -
          _getAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_REPAID),
        investorPrincipalWithdrawable: _getNetPrincipalPayableToInvestor(loanId),
        investorInterestWithdrawable: _getNetInterestPayableToInvestor(loanId),
        status: loanData.status,
        nextDueDate: loanData.nextDueDate
      });
    }
  }

  /**
   * @dev Creates a single entry from Unallocated Borrower Interest Payable to
   *      Borrower Interest Receivable. The split into servicer fees vs investor
   *      interest happens later during `applyWaterfall`.
   */
  function _accrue(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) internal {
    if (amount != 0) {
      _createInternalEntry(
        loanId,
        ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
        ACC_BORROWER_INTEREST_RECEIVABLE,
        amount,
        timestamp,
        ENTRY_INTEREST_ACCRUAL,
        ref
      );
    }
  }

  /// @inheritdoc ILoans
  function accrue(
    uint64 loanId,
    int128 amount,
    uint48 timestamp,
    bytes32 ref
  ) external whenNotPaused onlyServicerOrAdmin(loanId) onlyOutstanding(loanId) withLoanUpdate(loanId, timestamp) {
    _accrue(loanId, amount, timestamp, ref);
  }

  /// @inheritdoc ILoans
  function chargeMiscFee(
    uint64 loanId,
    int128 amount,
    uint48 timestamp,
    bytes32 ref
  ) external whenNotPaused onlyServicerOrAdmin(loanId) onlyOutstanding(loanId) withLoanUpdate(loanId, timestamp) {
    require(amount > 0, InvalidAmount());

    _createInternalEntry(
      loanId,
      ACC_SERVICER_MISC_FEE_PAYABLE,
      ACC_BORROWER_MISC_FEE_RECEIVABLE,
      amount,
      timestamp,
      ENTRY_MISC_FEE_CHARGE,
      ref
    );
  }

  /**
   * @inheritdoc ILoans
   * @dev Tokens are transferred from the loan's investor address (the current NFT holder).
   */
  function fund(
    uint64 loanId,
    int128 amount,
    uint48 timestamp,
    bytes32 ref
  ) external whenNotPaused nonReentrant withLoanUpdate(loanId, timestamp) returns (uint128 entryIndex) {
    address investorAddress = loansNFT.ownerOf(loanId);

    _requireCallerOrAdmin(investorAddress);
    require(amount > 0, InvalidAmount());
    require(data[loanId].status == LoanStatus.Created, InvalidStatus());

    // Funding must be a single full-commitment deposit.
    // BorrowerPrincipalReceivable = commitment (positive)
    // InvestorPrincipalPayable = funded amount (negative, as liability)
    int128 commitment = _getAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_RECEIVABLE);
    int128 alreadyFunded = -_getAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE);

    require(alreadyFunded == 0, InvalidAmount());
    require(amount == commitment, InvalidAmount());

    _updateLoanData(loanId, LoanStatus.FullyFunded, 0, 0);

    return
      _deposit(
        loanId,
        ACC_INVESTOR_PRINCIPAL_PAYABLE,
        amount,
        investorAddress,
        timestamp,
        ENTRY_INVESTOR_CAPITAL_RECEIVED,
        ref
      );
  }

  function _disburse(
    uint64 loanId,
    int128 netDisbursedAmount,
    int128 originationFee,
    uint48 timestamp,
    bytes32 ref
  ) internal returns (uint128 entryIndex) {
    // Entry 1: Withhold origination fee (OriginatorFeePayable -> UnfundedCommitment)
    // Creates originator fee liability, settles part of commitment
    if (originationFee > 0) {
      _createInternalEntry(
        loanId,
        ACC_ORIGINATOR_FEE_PAYABLE,
        ACC_UNFUNDED_COMMITMENT,
        originationFee,
        timestamp,
        ENTRY_ORIGINATOR_FEE_WITHHOLDING,
        ref
      );
    }

    // Entry 2: Disburse to borrower (Cash -> UnfundedCommitment)
    // Settles remaining commitment liability, decreases Cash
    entryIndex = _createInternalEntry(
      loanId,
      ACC_CASH,
      ACC_UNFUNDED_COMMITMENT,
      netDisbursedAmount,
      timestamp,
      ENTRY_DISBURSEMENT_TO_BORROWER,
      ref
    );

    // Transfer netDisbursedAmount to borrower
    currency.safeTransfer(borrowers[loanId], uint256(int256(netDisbursedAmount)));
  }

  /**
   * @inheritdoc ILoans
   * @dev Settles the unfunded commitment liability. Must disburse the full commitment
   *      amount (`netDisbursedAmount + originationFee`). Origination fee is withheld
   *      from the commitment before the borrower transfer.
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
  )
    external
    whenNotPaused
    nonReentrant
    loanExists(loanId)
    withLoanUpdate(loanId, timestamp)
    returns (uint128 entryIndex)
  {
    _requireCallerOrAdmin(originators[loanId]);
    require(netDisbursedAmount > 0, InvalidAmount());
    require(originationFee >= 0, InvalidAmount());

    LoanData storage loanData = data[loanId];
    require(loanData.status == LoanStatus.FullyFunded, InvalidStatus());

    // full amount committed = netDisbursedAmount + originationFee
    int128 commitment = -_getAccountBalance(loanId, ACC_UNFUNDED_COMMITMENT);
    require(netDisbursedAmount + originationFee == commitment, InvalidAmountDisbursed());

    // Verify investor funding actually reached the commitment.
    // Status alone is not authoritative because updateLoanData can set it directly.
    int128 funded = -_getAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE);
    require(funded == commitment, NotFullyFunded());

    _updateLoanData(loanId, LoanStatus.Active, nextDueDate, maturityDate);

    loanTerms[loanId] = LoanTerms({
      originationDate: originationDate,
      interestRate: interestRate,
      expectedMonthlyPayment: expectedMonthlyPayment
    });
    emit LoanTermsSet(loanId, originationDate, interestRate, expectedMonthlyPayment);

    return _disburse(loanId, netDisbursedAmount, originationFee, timestamp, ref);
  }

  /**
   * @dev Records partial repayment of a borrower receivable. Credits `paidAcc`
   *      and debits the payment clearing account. `amount` must not exceed the
   *      net outstanding receivable (receivable + any already-applied payment).
   */
  function _clearReceivableDebt(
    uint64 loanId,
    uint8 paidAcc,
    uint8 receivableAcc,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  ) private {
    if (amount == 0) return;
    int128 paid = _getAccountBalance(loanId, paidAcc);
    int128 outstanding = _getAccountBalance(loanId, receivableAcc) + (paid < 0 ? paid : int128(0));
    require(amount <= outstanding, InvalidAmount());
    _createInternalEntry(loanId, paidAcc, ACC_BORROWER_PAYMENT_CLEARING, amount, timestamp, entryType, ref);
  }

  /**
   * @dev Splits a borrower interest payment into servicer-fee and investor-interest
   *      allocations (moving each from the unallocated pool to the corresponding
   *      payable) and clears the matching interest receivable. Reverts if the
   *      total exceeds the net outstanding interest receivable.
   */
  function _processInterestPortion(
    uint64 loanId,
    int128 servicingFees,
    int128 investorInterest,
    uint48 timestamp,
    bytes32 ref
  ) private {
    int128 totalInterestAndFees = servicingFees + investorInterest;
    if (totalInterestAndFees == 0) return;

    int128 interestPaid = _getAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID);
    int128 outstanding = _getAccountBalance(loanId, ACC_BORROWER_INTEREST_RECEIVABLE) +
      (interestPaid < 0 ? interestPaid : int128(0));
    require(totalInterestAndFees <= outstanding, InvalidAmount());

    if (servicingFees > 0) {
      _createInternalEntry(
        loanId,
        ACC_SERVICER_FEE_PAYABLE,
        ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
        servicingFees,
        timestamp,
        ENTRY_SERVICER_FEE_ALLOCATION,
        ref
      );
    }
    if (investorInterest > 0) {
      _createInternalEntry(
        loanId,
        ACC_INVESTOR_INTEREST_PAYABLE,
        ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
        investorInterest,
        timestamp,
        ENTRY_INVESTOR_INTEREST_ALLOCATION,
        ref
      );
    }
    _createInternalEntry(
      loanId,
      ACC_BORROWER_INTEREST_PAID,
      ACC_BORROWER_PAYMENT_CLEARING,
      totalInterestAndFees,
      timestamp,
      ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE,
      ref
    );
  }

  /// @inheritdoc ILoans
  function applyWaterfall(
    uint64 loanId,
    int128 miscFees,
    int128 servicingFees,
    int128 investorInterest,
    int128 principal,
    uint48 nextDueDate,
    uint48 timestamp,
    bytes32 ref
  )
    external
    whenNotPaused
    onlyServicerOrAdmin(loanId)
    onlyOutstandingOrFullyPaid(loanId)
    withLoanUpdate(loanId, timestamp)
  {
    require(miscFees >= 0 && servicingFees >= 0 && investorInterest >= 0 && principal >= 0, InvalidAmount());

    if (nextDueDate > 0) {
      data[loanId].nextDueDate = nextDueDate;
      emit LoanNextDueDateUpdated(loanId, nextDueDate);
    }

    require(
      miscFees + servicingFees + investorInterest + principal <=
        -_getAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING),
      InvalidAmount()
    );

    _clearReceivableDebt(
      loanId,
      ACC_BORROWER_MISC_FEE_PAID,
      ACC_BORROWER_MISC_FEE_RECEIVABLE,
      miscFees,
      timestamp,
      ENTRY_MISC_FEE_DEBT_CLEARANCE,
      ref
    );

    _processInterestPortion(loanId, servicingFees, investorInterest, timestamp, ref);

    _clearReceivableDebt(
      loanId,
      ACC_BORROWER_PRINCIPAL_REPAID,
      ACC_BORROWER_PRINCIPAL_RECEIVABLE,
      principal,
      timestamp,
      ENTRY_BORROWER_PRINCIPAL_PAYMENT,
      ref
    );
  }

  /**
   * @inheritdoc ILoans
   * @dev All loans must share the same servicer address (caller or admin acting on
   *      their behalf). Per-loan ledger entries are written individually but the
   *      payouts are consolidated into a single ERC20 transfer. Automatically
   *      withdraws all available servicing fees and misc fees per loan.
   */
  function servicerWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
  ) external whenNotPaused nonReentrant returns (ServicerWithdrawalResult[] memory results) {
    uint256 numLoans = loanIds.length;
    results = new ServicerWithdrawalResult[](numLoans);

    int128 totalTransfer = 0;
    address servicerAddress;
    uint64 currentLoanCount = loanCount;

    for (uint256 i = 0; i < numLoans; ++i) {
      uint64 loanId = loanIds[i];

      require(loanId != 0 && loanId <= currentLoanCount, DoesNotExist());

      servicerAddress = _requireBatchCaller(servicers[loanId], i, servicerAddress);

      int128 servicingFee = _getNetPayable(loanId, ACC_SERVICER_FEE_PAYABLE, ACC_SERVICER_FEE_PAID);
      int128 miscFee = _getNetPayable(loanId, ACC_SERVICER_MISC_FEE_PAYABLE, ACC_SERVICER_MISC_FEE_PAID);

      totalTransfer += _withdrawToAccount(
        loanId,
        ACC_SERVICER_FEE_PAID,
        servicingFee,
        timestamp,
        ENTRY_SERVICER_FEE_WITHDRAWAL,
        ref
      );
      totalTransfer += _withdrawToAccount(
        loanId,
        ACC_SERVICER_MISC_FEE_PAID,
        miscFee,
        timestamp,
        ENTRY_MISC_FEE_WITHDRAWAL,
        ref
      );

      results[i] = ServicerWithdrawalResult({loanId: loanId, miscFee: miscFee, servicingFee: servicingFee});

      data[loanId].updatedAt = timestamp;
    }

    currency.safeTransfer(servicerAddress, uint256(int256(totalTransfer)));
  }

  /**
   * @inheritdoc ILoans
   * @dev Inverse of `servicerWithdraw`. Pulls tokens from `msg.sender` into the
   *      loan's cash account. Only servicer-paid accounts (or `SERVICER_ADJUSTMENT`)
   *      are allowed as the `from` account.
   */
  function returnFunds(
    uint64 loanId,
    uint8 from,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  )
    external
    whenNotPaused
    onlyServicerOrAdmin(loanId)
    nonReentrant
    onlyOutstandingOrFullyPaid(loanId)
    withLoanUpdate(loanId, timestamp)
    returns (uint128 entryIndex)
  {
    require(
      from == ACC_SERVICER_ADJUSTMENT ||
        ((from == ACC_SERVICER_FEE_PAID || from == ACC_SERVICER_MISC_FEE_PAID) &&
          amount <= _getAccountBalance(loanId, from)),
      InvalidAccount()
    );

    return _deposit(loanId, from, amount, msg.sender, timestamp, entryType, ref);
  }

  /// @inheritdoc ILoans
  function createLedgerEntries(
    uint64 loanId,
    uint48 timestamp,
    LedgerEntryInput[] calldata ledgerEntries
  )
    external
    whenNotPaused
    onlyServicerOrAdmin(loanId)
    loanExists(loanId)
    withLoanUpdate(loanId, timestamp)
    returns (uint128[] memory entryIndices)
  {
    uint256 length = ledgerEntries.length;
    entryIndices = new uint128[](length);

    for (uint256 i = 0; i < length; ++i) {
      LedgerEntryInput calldata e = ledgerEntries[i];
      require(e.from != ACC_CASH && e.to != ACC_CASH, InvalidAccount());
      entryIndices[i] = _createInternalEntry(loanId, e.from, e.to, e.amount, timestamp, e.entryType, e.ref);
    }
  }

  /// @inheritdoc ILoans
  function refundBorrower(
    uint64 loanId,
    uint8 toAccount,
    int128 amount,
    uint48 timestamp,
    uint16 entryType,
    bytes32 ref
  )
    external
    whenNotPaused
    onlyServicerOrAdmin(loanId)
    nonReentrant
    onlyOutstandingOrFullyPaid(loanId)
    withLoanUpdate(loanId, timestamp)
    returns (uint128 entryIndex)
  {
    require(
      toAccount == ACC_BORROWER_INTEREST_PAID ||
        toAccount == ACC_BORROWER_MISC_FEE_PAID ||
        toAccount == ACC_BORROWER_PAYMENT_CLEARING,
      InvalidAccount()
    );

    int128 refundable = -_getAccountBalance(loanId, toAccount);
    if (toAccount != ACC_BORROWER_PAYMENT_CLEARING) {
      uint8 receivable = toAccount == ACC_BORROWER_INTEREST_PAID
        ? ACC_BORROWER_INTEREST_RECEIVABLE
        : ACC_BORROWER_MISC_FEE_RECEIVABLE;
      refundable -= _getAccountBalance(loanId, receivable);
    }
    require(amount <= refundable, InvalidAmount());

    return _withdraw(loanId, toAccount, amount, borrowers[loanId], timestamp, entryType, ref);
  }

  /**
   * @inheritdoc ILoans
   * @dev All loans must share the same originator (caller or admin acting on their
   *      behalf). Per-loan ledger entries are written individually but payouts are
   *      consolidated into a single ERC20 transfer. Automatically withdraws all
   *      available originator fees per loan.
   */
  function originatorWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
  ) external whenNotPaused nonReentrant returns (OriginatorWithdrawalResult[] memory results) {
    uint256 numLoans = loanIds.length;
    results = new OriginatorWithdrawalResult[](numLoans);

    int128 totalTransfer = 0;
    address originatorAddress;
    uint64 currentLoanCount = loanCount;

    for (uint256 i = 0; i < numLoans; ++i) {
      uint64 loanId = loanIds[i];

      require(loanId != 0 && loanId <= currentLoanCount, DoesNotExist());

      originatorAddress = _requireBatchCaller(originators[loanId], i, originatorAddress);

      int128 amount = _getNetPayable(loanId, ACC_ORIGINATOR_FEE_PAYABLE, ACC_ORIGINATOR_FEE_PAID);

      totalTransfer += _withdrawToAccount(
        loanId,
        ACC_ORIGINATOR_FEE_PAID,
        amount,
        timestamp,
        ENTRY_ORIGINATOR_FEE_WITHDRAWAL,
        ref
      );

      results[i] = OriginatorWithdrawalResult({loanId: loanId, amount: amount});

      data[loanId].updatedAt = timestamp;
    }

    currency.safeTransfer(originatorAddress, uint256(int256(totalTransfer)));
  }

  /**
   * @inheritdoc ILoans
   * @dev All loans must have the same investor (NFT owner) and the same lock state.
   *      If the first loan is unlocked, every loan in the batch must be unlocked and
   *      the caller must be the investor or admin; funds go to the investor.
   *      If the first loan is locked, every loan must be locked to the same address
   *      and the caller must be that unlocker; funds go to `msg.sender`.
   */
  function investorWithdraw(
    uint64[] calldata loanIds,
    uint48 timestamp,
    bytes32 ref
  ) external whenNotPaused nonReentrant returns (InvestorWithdrawalResult[] memory results) {
    uint256 numLoans = loanIds.length;
    results = new InvestorWithdrawalResult[](numLoans);
    if (numLoans == 0) return results;

    ILoansNFT nft = loansNFT;
    uint64 currentLoanCount = loanCount;

    // Handle the first loan outside the loop so the investor/unlocker check
    // and caller authorization only happen once.
    uint64 firstLoanId = loanIds[0];
    require(firstLoanId != 0 && firstLoanId <= currentLoanCount, DoesNotExist());

    (address cachedInvestorAddress, address cachedUnlocker) = nft.ownerAndUnlocker(uint256(firstLoanId));
    address recipient;
    if (cachedUnlocker == address(0)) {
      _requireCallerOrAdmin(cachedInvestorAddress);
      recipient = cachedInvestorAddress;
    } else {
      require(cachedUnlocker == msg.sender, Unauthorized());
      recipient = msg.sender;
    }

    int128 totalTransfer = _processInvestorWithdrawal(firstLoanId, timestamp, ref, results, 0);

    for (uint256 i = 1; i < numLoans; ) {
      uint64 loanId = loanIds[i];
      require(loanId != 0 && loanId <= currentLoanCount, DoesNotExist());
      (address loanInvestor, address loanUnlocker) = nft.ownerAndUnlocker(uint256(loanId));
      require(loanInvestor == cachedInvestorAddress, Unauthorized());
      require(loanUnlocker == cachedUnlocker, Unauthorized());

      int128 transfer = _processInvestorWithdrawal(loanId, timestamp, ref, results, i);
      unchecked {
        totalTransfer += transfer;
        ++i;
      }
    }

    currency.safeTransfer(recipient, uint256(int256(totalTransfer)));
  }

  /**
   * @dev Per-loan helper used by `investorWithdraw`. Writes the per-loan result
   *      directly into the caller's `results` array slot to avoid an extra
   *      memory struct allocation and copy. Returns the amount to add to the
   *      caller's running transfer total.
   */
  function _processInvestorWithdrawal(
    uint64 loanId,
    uint48 timestamp,
    bytes32 ref,
    InvestorWithdrawalResult[] memory results,
    uint256 resultIndex
  ) internal returns (int128 transfer) {
    int128 interest = _getNetInterestPayableToInvestor(loanId);
    int128 principal = _getNetPrincipalPayableToInvestor(loanId);

    transfer =
      _withdrawToAccount(
        loanId,
        ACC_INVESTOR_INTEREST_PAID,
        interest,
        timestamp,
        ENTRY_INVESTOR_INTEREST_WITHDRAWAL,
        ref
      ) +
      _withdrawToAccount(
        loanId,
        ACC_INVESTOR_PRINCIPAL_REPAID,
        principal,
        timestamp,
        ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL,
        ref
      );

    results[resultIndex] = InvestorWithdrawalResult({loanId: loanId, principal: principal, interest: interest});

    data[loanId].updatedAt = timestamp;
  }

  /**
   * @dev Allows only Active and ChargedOff.
   */
  function _onlyOutstanding(uint64 loanId) internal view {
    LoanStatus status = data[loanId].status;
    require(status == LoanStatus.Active || status == LoanStatus.ChargedOff, InvalidStatus());
  }

  /**
   * @dev Allows Active, ChargedOff, and FullyPaid. Used for ledger operations that may
   *      still occur after final payment (e.g. waterfall allocating a residual payment).
   */
  function _onlyOutstandingOrFullyPaid(uint64 loanId) internal view {
    LoanStatus status = data[loanId].status;
    require(
      status == LoanStatus.Active || status == LoanStatus.ChargedOff || status == LoanStatus.FullyPaid,
      InvalidStatus()
    );
  }

  /**
   * @dev Allows any status except DoesNotExist, Cancelled, Closed.
   */
  function _notTerminal(uint64 loanId) internal view {
    LoanStatus status = data[loanId].status;
    require(
      status != LoanStatus.DoesNotExist && status != LoanStatus.Cancelled && status != LoanStatus.Closed,
      InvalidStatus()
    );
  }

  function _onlyServicerOrAdmin(uint64 loanId) internal view {
    _requireCallerOrAdmin(servicers[loanId]);
  }

  function _onlyBorrowerOrAdmin(uint64 loanId) internal view {
    _requireCallerOrAdmin(borrowers[loanId]);
  }

  function _withLoanUpdate(uint64 loanId, uint48 timestamp) internal {
    data[loanId].updatedAt = timestamp;
  }

  function _requireCallerOrAdmin(address addr) private view {
    require(addr == msg.sender || _isAdminOrGuardian(msg.sender), Unauthorized());
  }

  function _requireBatchCaller(address roleAddr, uint256 index, address canonical) private view returns (address) {
    index == 0 ? _requireCallerOrAdmin(roleAddr) : require(roleAddr == canonical, Unauthorized());
    return roleAddr;
  }
}
