// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {ILoans, Entry, LedgerEntryInput, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {
  ENTRY_ADJUSTMENT,
  ENTRY_BORROWER_REFUND,
  ENTRY_INTEREST_RECLASSIFICATION,
  ENTRY_INTEREST_REVERSAL,
  ENTRY_MISC_FEE_CHARGE
} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_BORROWER_INTEREST_PAID,
  ACC_BORROWER_INTEREST_RECEIVABLE,
  ACC_BORROWER_MISC_FEE_PAID,
  ACC_BORROWER_MISC_FEE_RECEIVABLE,
  ACC_BORROWER_PAYMENT_CLEARING,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_CASH,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_REPAID,
  ACC_SERVICER_ADJUSTMENT,
  ACC_SERVICER_MISC_FEE_PAYABLE,
  ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_RefundBorrowerTest is LoansTestBase {
  bytes32 constant REF = bytes32("test_ref");

  // Overpayment scenario constants
  int128 constant OVERPAY_PRINCIPAL = 100e6;
  int128 constant OVERPAY_ACCRUAL = 10e6;
  int128 constant OVERPAY_AMOUNT = 200e6;

  // Sentinels and shared scenario amounts
  int128 constant ONE_UNIT = 1; // smallest positive amount; used to probe "any positive refund" paths
  int128 constant ONE_USDC = 1e6;
  int128 constant SMALL_CASH = 10e6;
  int128 constant MISC_FEE_AMOUNT = 25e6;
  int128 constant PARTIAL_OVER_ACCRUAL = 30e6; // partial reversal of DEFAULT_ACCRUAL_AMOUNT (100e6)
  uint64 constant NONEXISTENT_LOAN_ID = 999;

  function setUp() public override {
    super.setUp();
    loanId = _createLoanWithInvestorCashflow(DEFAULT_PRINCIPAL_AMOUNT, REF);
  }

  /// @dev Reverses `amount` of borrower interest over-accrual
  ///      Decrease the receivable into the unallocated pool, then reverse the investor allocation. Leaves
  ///      BORROWER_INTEREST_PAID intact while shrinking BORROWER_INTEREST_RECEIVABLE,
  ///      creating a refundable over-payment delta of `amount`.
  ///      Requires `amount` ≤ outstanding INVESTOR_INTEREST_PAYABLE.
  function _reverseInterestOverAccrual(uint64 loanId_, int128 amount) internal {
    LedgerEntryInput[] memory entries = new LedgerEntryInput[](2);
    entries[0] = LedgerEntryInput({
      from: ACC_BORROWER_INTEREST_RECEIVABLE,
      to: ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      amount: amount,
      entryType: ENTRY_INTEREST_REVERSAL,
      ref: REF
    });
    entries[1] = LedgerEntryInput({
      from: ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      to: ACC_INVESTOR_INTEREST_PAYABLE,
      amount: amount,
      entryType: ENTRY_INTEREST_REVERSAL,
      ref: REF
    });
    vm.prank(servicer);
    loans.createLedgerEntries(loanId_, timeNow, entries);
  }

  function test_RefundBorrower_ExactAmount() public accountingEquationHolds {
    int128 refundAmount = DEFAULT_INVESTOR_INTEREST; // 90e6, full reversible investor allocation
    _reverseInterestOverAccrual(loanId, refundAmount);

    usdc.mint(servicer, asUint(refundAmount));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    loans.returnFunds(loanId, ACC_SERVICER_ADJUSTMENT, refundAmount, timeNow, ENTRY_ADJUSTMENT, REF);

    int128 cashBefore = loans.getLoanAccountBalance(loanId, ACC_CASH);
    int128 borrowerIntPaidBefore = loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID);
    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(servicer);
    uint128 entryIndex = loans.refundBorrower(
      loanId,
      ACC_BORROWER_INTEREST_PAID,
      refundAmount,
      timeNow,
      ENTRY_BORROWER_REFUND,
      REF
    );

    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore + asUint(refundAmount));
    assertEq(_loansContractBalance(), contractBalanceBefore - asUint(refundAmount));
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), cashBefore - refundAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), borrowerIntPaidBefore + refundAmount);

    assertEq(loans.entryCount(loanId), entryCountBefore + 1);
    assertEq(entryIndex, (uint128(loanId) << 64) | uint128(entryCountBefore + 1));

    Entry memory e = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(e.from, ACC_CASH);
    assertEq(e.to, ACC_BORROWER_INTEREST_PAID);
    assertEq(e.amount, refundAmount);
    assertEq(e.entryType, ENTRY_BORROWER_REFUND);
  }

  function test_refundBorrower_partialAmount() public accountingEquationHolds {
    int128 overAccrual = DEFAULT_INVESTOR_INTEREST; // 90e6
    int128 refundAmount = overAccrual / 2; // refund only half of the reversed amount
    _reverseInterestOverAccrual(loanId, overAccrual);

    usdc.mint(servicer, asUint(refundAmount));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    loans.returnFunds(loanId, ACC_SERVICER_ADJUSTMENT, refundAmount, timeNow, ENTRY_ADJUSTMENT, REF);

    int128 borrowerIntPaidBefore = loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID);
    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);

    vm.prank(servicer);
    loans.refundBorrower(loanId, ACC_BORROWER_INTEREST_PAID, refundAmount, timeNow, ENTRY_BORROWER_REFUND, REF);

    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore + asUint(refundAmount));
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), borrowerIntPaidBefore + refundAmount);
    // Account still has remaining paid balance
    assertLt(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), 0);
  }

  function test_refundBorrower_revertsWhenAmountExceedsPaid() public {
    int128 overAccrual = DEFAULT_INVESTOR_INTEREST;
    _reverseInterestOverAccrual(loanId, overAccrual);

    int128 excessAmount = overAccrual + ONE_USDC;

    // Fund cash so the revert comes from our validation, not insufficient cash
    usdc.mint(servicer, asUint(excessAmount));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    loans.returnFunds(loanId, ACC_SERVICER_ADJUSTMENT, excessAmount, timeNow, ENTRY_ADJUSTMENT, REF);

    vm.expectRevert(ILoans.InvalidAmount.selector);
    vm.prank(servicer);
    loans.refundBorrower(loanId, ACC_BORROWER_INTEREST_PAID, excessAmount, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  /// @notice borrower paid exactly what was accrued (no over-payment).
  ///         Even though BORROWER_INTEREST_PAID has a negative balance, refundable is zero
  ///         because BORROWER_INTEREST_RECEIVABLE matches it.
  function test_refundBorrower_revertsWhenInterestPaidEqualsReceivable() public {
    // Sanity: helper leaves PAID and RECEIVABLE equal in absolute value.
    assertEq(
      -loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID),
      loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_RECEIVABLE)
    );

    usdc.mint(servicer, asUint(ONE_USDC));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    loans.returnFunds(loanId, ACC_SERVICER_ADJUSTMENT, ONE_USDC, timeNow, ENTRY_ADJUSTMENT, REF);

    vm.expectRevert(ILoans.InvalidAmount.selector);
    vm.prank(servicer);
    loans.refundBorrower(loanId, ACC_BORROWER_INTEREST_PAID, ONE_UNIT, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  /// @notice after a partial over-accrual reversal, refund amount must not
  ///         exceed the (PAID - RECEIVABLE) delta even if PAID alone would cover it.
  function test_refundBorrower_revertsWhenAmountExceedsOverAccrualDelta() public {
    int128 overAccrual = PARTIAL_OVER_ACCRUAL;
    _reverseInterestOverAccrual(loanId, overAccrual);

    // Refundable delta = -PAID(-DEFAULT_ACCRUAL_AMOUNT) - RECEIVABLE(DEFAULT_ACCRUAL_AMOUNT - overAccrual) = overAccrual
    int128 excess = overAccrual + ONE_UNIT;

    usdc.mint(servicer, asUint(excess));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    loans.returnFunds(loanId, ACC_SERVICER_ADJUSTMENT, excess, timeNow, ENTRY_ADJUSTMENT, REF);

    vm.expectRevert(ILoans.InvalidAmount.selector);
    vm.prank(servicer);
    loans.refundBorrower(loanId, ACC_BORROWER_INTEREST_PAID, excess, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  /// @dev Creates an active loan and walks it through: charge $X misc fee, borrower pays $X,
  ///      apply waterfall (miscFees=$X). Post-state: MISC_FEE_RECEIVABLE=+X, MISC_FEE_PAID=-X
  ///      (refundable=0 unless caller reverses the accrual).
  function _setupMiscFeePaidInFull(int128 amount) internal returns (uint64 freshLoanId) {
    freshLoanId = _createActiveLoan(DEFAULT_PRINCIPAL_AMOUNT);

    vm.prank(servicer);
    loans.chargeMiscFee(freshLoanId, amount, timeNow, REF);

    usdc.mint(borrower, asUint(amount));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);
    vm.prank(borrower);
    loans.pay(freshLoanId, amount, timeNow, REF);

    vm.prank(servicer);
    loans.applyWaterfall(freshLoanId, amount, 0, 0, 0, 0, timeNow, REF);
  }

  /// @notice Happy path: borrower paid a misc fee that was later (partially) reversed.
  ///         The reversed amount is refundable from BORROWER_MISC_FEE_PAID.
  function test_refundBorrower_miscFeeOverpayment() public accountingEquationHolds {
    int128 miscFee = MISC_FEE_AMOUNT;
    uint64 freshLoanId = _setupMiscFeePaidInFull(miscFee);

    // Reverse the misc fee accrual: shrink RECEIVABLE back to 0, undo the payable.
    // Spec convention: Debit SERVICER_MISC_FEE_PAYABLE, Credit BORROWER_MISC_FEE_RECEIVABLE.
    // Code mapping: from=RECEIVABLE (credit side), to=SERVICER_MISC_FEE_PAYABLE (debit side).
    LedgerEntryInput[] memory entries = new LedgerEntryInput[](1);
    entries[0] = LedgerEntryInput({
      from: ACC_BORROWER_MISC_FEE_RECEIVABLE,
      to: ACC_SERVICER_MISC_FEE_PAYABLE,
      amount: miscFee,
      entryType: ENTRY_ADJUSTMENT,
      ref: REF
    });
    vm.prank(servicer);
    loans.createLedgerEntries(freshLoanId, timeNow, entries);

    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_MISC_FEE_RECEIVABLE), 0);
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_MISC_FEE_PAID), -miscFee);

    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);

    vm.prank(servicer);
    loans.refundBorrower(freshLoanId, ACC_BORROWER_MISC_FEE_PAID, miscFee, timeNow, ENTRY_BORROWER_REFUND, REF);

    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore + asUint(miscFee));
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_MISC_FEE_PAID), 0);
  }

  /// @notice when MISC_FEE_PAID equals the outstanding MISC_FEE_RECEIVABLE, refundable must be zero.
  function test_refundBorrower_revertsWhenMiscFeePaidEqualsReceivable() public {
    int128 miscFee = MISC_FEE_AMOUNT;
    uint64 freshLoanId = _setupMiscFeePaidInFull(miscFee);

    // Sanity: PAID magnitude matches RECEIVABLE.
    assertEq(
      -loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_MISC_FEE_PAID),
      loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_MISC_FEE_RECEIVABLE)
    );

    vm.expectRevert(ILoans.InvalidAmount.selector);
    vm.prank(servicer);
    loans.refundBorrower(freshLoanId, ACC_BORROWER_MISC_FEE_PAID, ONE_UNIT, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  function test_refundBorrower_revertsWhenNoPaidBalance() public {
    uint64 freshLoanId = _createActiveLoan(DEFAULT_PRINCIPAL_AMOUNT);

    // Fund cash so the revert comes from our validation, not insufficient cash
    usdc.mint(servicer, asUint(SMALL_CASH));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    loans.returnFunds(freshLoanId, ACC_SERVICER_ADJUSTMENT, SMALL_CASH, timeNow, ENTRY_ADJUSTMENT, REF);

    vm.expectRevert(ILoans.InvalidAmount.selector);
    vm.prank(servicer);
    loans.refundBorrower(freshLoanId, ACC_BORROWER_INTEREST_PAID, ONE_USDC, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  function test_refundBorrower_revertsWhenAccountNotInAllowlist() public {
    // ACC_CASH is not in the refund allowlist (only INTEREST_PAID, MISC_FEE_PAID,
    // and PAYMENT_CLEARING are). The call must revert before any balance checks.
    vm.expectRevert(ILoans.InvalidAccount.selector);
    vm.prank(servicer);
    loans.refundBorrower(loanId, ACC_CASH, ONE_UNIT, timeNow, ENTRY_BORROWER_REFUND, REF);

    // ACC_BORROWER_PRINCIPAL_REPAID is a borrower-side account but also not in the allowlist.
    vm.expectRevert(ILoans.InvalidAccount.selector);
    vm.prank(servicer);
    loans.refundBorrower(loanId, ACC_BORROWER_PRINCIPAL_REPAID, ONE_UNIT, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  function test_RefundBorrower_Succeeds_WhenStatusFullyPaid() public accountingEquationHolds {
    _assertRefundBorrowerSucceedsAtStatus(LoanStatus.FullyPaid);
  }

  function test_RefundBorrower_Succeeds_WhenStatusChargedOff() public accountingEquationHolds {
    _assertRefundBorrowerSucceedsAtStatus(LoanStatus.ChargedOff);
  }

  function _assertRefundBorrowerSucceedsAtStatus(LoanStatus targetStatus) internal {
    int128 refundAmount = DEFAULT_INVESTOR_INTEREST;
    _reverseInterestOverAccrual(loanId, refundAmount);

    usdc.mint(servicer, asUint(refundAmount));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    loans.returnFunds(loanId, ACC_SERVICER_ADJUSTMENT, refundAmount, timeNow, ENTRY_ADJUSTMENT, REF);

    vm.prank(servicer);
    loans.updateLoanData(loanId, targetStatus, 0, 0, timeNow);

    int128 cashBefore = loans.getLoanAccountBalance(loanId, ACC_CASH);
    int128 borrowerIntPaidBefore = loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID);
    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(servicer);
    uint128 entryIndex = loans.refundBorrower(
      loanId,
      ACC_BORROWER_INTEREST_PAID,
      refundAmount,
      timeNow,
      ENTRY_BORROWER_REFUND,
      REF
    );

    assertEq(loans.entryCount(loanId), entryCountBefore + 1);
    assertEq(entryIndex, (uint128(loanId) << 64) | uint128(entryCountBefore + 1));

    Entry memory e = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(e.from, ACC_CASH);
    assertEq(e.to, ACC_BORROWER_INTEREST_PAID);
    assertEq(e.amount, refundAmount);
    assertEq(e.entryType, ENTRY_BORROWER_REFUND);
    assertEq(e.ref, REF);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), cashBefore - refundAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), borrowerIntPaidBefore + refundAmount);

    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore + asUint(refundAmount));
    assertEq(_loansContractBalance(), contractBalanceBefore - asUint(refundAmount));

    (LoanStatus status, , , , ) = loans.data(loanId);
    assertEq(uint8(status), uint8(targetStatus));
  }

  function test_RefundBorrower_Reverts_WhenStatusCreated() public {
    uint64 createdLoanId = _createTestLoan(DEFAULT_PRINCIPAL_AMOUNT);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.refundBorrower(createdLoanId, ACC_BORROWER_INTEREST_PAID, ONE_USDC, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  function test_RefundBorrower_Reverts_WhenStatusFullyFunded() public {
    uint64 fullyFundedLoanId = _createFullyFundedLoan(DEFAULT_PRINCIPAL_AMOUNT);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.refundBorrower(fullyFundedLoanId, ACC_BORROWER_INTEREST_PAID, ONE_USDC, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  function test_RefundBorrower_RevertsOnCancelledLoan() public {
    uint64 cancelledLoanId = _createCancelledLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.refundBorrower(cancelledLoanId, ACC_BORROWER_INTEREST_PAID, ONE_USDC, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  function test_RefundBorrower_RevertsOnClosedLoan() public {
    uint64 closedLoanId = _createClosedLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.refundBorrower(closedLoanId, ACC_BORROWER_INTEREST_PAID, ONE_USDC, timeNow, ENTRY_BORROWER_REFUND, REF);
  }

  function test_RefundBorrower_RevertsOnNonexistentLoan() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.refundBorrower(
      NONEXISTENT_LOAN_ID,
      ACC_BORROWER_INTEREST_PAID,
      ONE_USDC,
      timeNow,
      ENTRY_BORROWER_REFUND,
      REF
    );
  }

  // ========== PAYMENT_CLEARING (overpayment) refunds ==========

  /// @dev Sets up a loan where the borrower has overpaid and the waterfall has allocated
  /// all valid debts, leaving a positive (unallocated) surplus in PAYMENT_CLEARING.
  function _setupOverpaymentSurplus(
    int128 principal,
    int128 accrualAmount,
    int128 overpaymentAmount
  ) internal returns (uint64 freshLoanId, int128 surplus) {
    usdc.mint(investor, asUint(principal));
    freshLoanId = _createActiveLoan(principal);

    vm.prank(servicer);
    loans.accrue(freshLoanId, accrualAmount, timeNow, REF);

    usdc.mint(borrower, asUint(overpaymentAmount));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(borrower);
    loans.pay(freshLoanId, overpaymentAmount, timeNow, REF);

    // Allocate everything legitimately owed: interest (all to investor for simplicity) + full principal.
    vm.prank(servicer);
    loans.applyWaterfall(freshLoanId, 0, 0, accrualAmount, principal, 0, timeNow, REF);

    surplus = overpaymentAmount - accrualAmount - principal;
    // Clearing balance reflects unallocated surplus as a (negative) liability.
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_PAYMENT_CLEARING), -surplus);
  }

  function test_refundBorrower_fromPaymentClearing() public accountingEquationHolds {
    (uint64 freshLoanId, int128 surplus) = _setupOverpaymentSurplus(OVERPAY_PRINCIPAL, OVERPAY_ACCRUAL, OVERPAY_AMOUNT);
    assertGt(surplus, 0);

    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    int128 cashBefore = loans.getLoanAccountBalance(freshLoanId, ACC_CASH);
    uint64 entryCountBefore = loans.entryCount(freshLoanId);

    vm.prank(servicer);
    uint128 entryIndex = loans.refundBorrower(
      freshLoanId,
      ACC_BORROWER_PAYMENT_CLEARING,
      surplus,
      timeNow,
      ENTRY_BORROWER_REFUND,
      REF
    );

    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore + asUint(surplus));
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_CASH), cashBefore - surplus);
    // Clearing reconciles back to zero.
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_PAYMENT_CLEARING), 0);

    assertEq(loans.entryCount(freshLoanId), entryCountBefore + 1);
    Entry memory e = loans.getLoanEntry(freshLoanId, entryCountBefore + 1);
    assertEq(e.from, ACC_CASH);
    assertEq(e.to, ACC_BORROWER_PAYMENT_CLEARING);
    assertEq(e.amount, surplus);
    assertEq(e.entryType, ENTRY_BORROWER_REFUND);
    assertEq(entryIndex, (uint128(freshLoanId) << 64) | uint128(entryCountBefore + 1));
  }

  function test_refundBorrower_revertsWhenClearingRefundExceedsUnallocated() public {
    (uint64 freshLoanId, int128 surplus) = _setupOverpaymentSurplus(OVERPAY_PRINCIPAL, OVERPAY_ACCRUAL, OVERPAY_AMOUNT);

    vm.expectRevert(ILoans.InvalidAmount.selector);
    vm.prank(servicer);
    loans.refundBorrower(
      freshLoanId,
      ACC_BORROWER_PAYMENT_CLEARING,
      surplus + ONE_UNIT,
      timeNow,
      ENTRY_BORROWER_REFUND,
      REF
    );
  }

  /// @notice End-to-end: borrower overpays -> waterfall caps principal -> surplus refunded ->
  ///         investor withdraws exactly funded principal + earned interest. All balances reconcile.
  function test_refundBorrower_overpaymentEndToEnd() public accountingEquationHolds {
    (uint64 freshLoanId, int128 surplus) = _setupOverpaymentSurplus(OVERPAY_PRINCIPAL, OVERPAY_ACCRUAL, OVERPAY_AMOUNT);

    // Refund the surplus to the borrower.
    vm.prank(servicer);
    loans.refundBorrower(freshLoanId, ACC_BORROWER_PAYMENT_CLEARING, surplus, timeNow, ENTRY_BORROWER_REFUND, REF);

    // Investor withdraws everything owed.
    uint256 investorBalanceBefore = usdc.balanceOf(investor);
    uint64[] memory ids = new uint64[](1);
    ids[0] = freshLoanId;
    vm.prank(investor);
    loans.investorWithdraw(ids, timeNow, REF);

    // Investor receives exactly funded principal + accrued interest.
    assertEq(usdc.balanceOf(investor), investorBalanceBefore + asUint(OVERPAY_PRINCIPAL + OVERPAY_ACCRUAL));

    // All cashflow accounts reconcile.
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_BORROWER_PAYMENT_CLEARING), 0);
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_CASH), 0);
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_INVESTOR_INTEREST_PAID), OVERPAY_ACCRUAL);
    assertEq(loans.getLoanAccountBalance(freshLoanId, ACC_INVESTOR_PRINCIPAL_REPAID), OVERPAY_PRINCIPAL);
  }
}
