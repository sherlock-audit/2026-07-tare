// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, ILoans, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {
  ENTRY_SERVICER_FEE_ALLOCATION,
  ENTRY_INVESTOR_INTEREST_ALLOCATION,
  ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE,
  ENTRY_BORROWER_PRINCIPAL_PAYMENT,
  ENTRY_MISC_FEE_CHARGE,
  ENTRY_MISC_FEE_DEBT_CLEARANCE
} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_BORROWER_INTEREST_PAID,
  ACC_BORROWER_MISC_FEE_PAID,
  ACC_BORROWER_MISC_FEE_RECEIVABLE,
  ACC_BORROWER_PAYMENT_CLEARING,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_SERVICER_FEE_PAYABLE,
  ACC_SERVICER_MISC_FEE_PAYABLE,
  ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";
import {MIN_USDC_AMOUNT, MAX_USDC_AMOUNT} from "test/lib/Constants.sol";

contract Loans_ApplyWaterfallTest is LoansTestBase {
  int128 constant PRINCIPAL = 10_000e6;
  int128 constant ACCRUAL_AMOUNT = 100e6;
  int128 constant PAYMENT_AMOUNT = 600e6;
  int128 constant SERVICER_FEE = 10e6;
  int128 constant INVESTOR_INTEREST = 90e6;
  int128 constant PRINCIPAL_REPAYMENT = 500e6;
  bytes32 constant REF = bytes32("test_ref");

  function setUp() public override {
    super.setUp();
    _setupWaterfallState(PRINCIPAL, ACCRUAL_AMOUNT, PAYMENT_AMOUNT);
  }

  function _setupWaterfallState(int128 principal, int128 accrualAmount, int128 paymentAmount) internal {
    // Ensure investor has enough to fund the loan
    usdc.mint(investor, asUint(principal));

    loanId = _createActiveLoan(principal);

    vm.prank(servicer);
    loans.accrue(loanId, accrualAmount, timeNow, REF);

    usdc.mint(borrower, asUint(paymentAmount));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(borrower);
    loans.pay(loanId, paymentAmount, timeNow, REF);
  }

  function test_applyWaterfall() public accountingEquationHolds {
    uint64 entryCountBefore = loans.entryCount(loanId);

    // Apply waterfall: 10 fees + 90 interest + 500 principal = 600
    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);

    // 4 entries: fee alloc, interest alloc, interest debt clearance, principal payment
    assertEq(loans.entryCount(loanId), entryCountBefore + 4);

    // Entry 1: Servicer fee allocation
    Entry memory e1 = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(uint8(e1.from), ACC_SERVICER_FEE_PAYABLE);
    assertEq(uint8(e1.to), ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE);
    assertEq(e1.amount, SERVICER_FEE);
    assertEq(e1.entryType, ENTRY_SERVICER_FEE_ALLOCATION);

    // Entry 2: Investor interest allocation
    Entry memory e2 = loans.getLoanEntry(loanId, entryCountBefore + 2);
    assertEq(uint8(e2.from), ACC_INVESTOR_INTEREST_PAYABLE);
    assertEq(uint8(e2.to), ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE);
    assertEq(e2.amount, INVESTOR_INTEREST);
    assertEq(e2.entryType, ENTRY_INVESTOR_INTEREST_ALLOCATION);

    // Entry 3: Borrower interest debt clearance (total interest + fees)
    Entry memory e3 = loans.getLoanEntry(loanId, entryCountBefore + 3);
    assertEq(uint8(e3.from), ACC_BORROWER_INTEREST_PAID);
    assertEq(uint8(e3.to), ACC_BORROWER_PAYMENT_CLEARING);
    assertEq(e3.amount, SERVICER_FEE + INVESTOR_INTEREST);
    assertEq(e3.entryType, ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE);

    // Entry 4: Principal payment
    Entry memory e4 = loans.getLoanEntry(loanId, entryCountBefore + 4);
    assertEq(uint8(e4.from), ACC_BORROWER_PRINCIPAL_REPAID);
    assertEq(uint8(e4.to), ACC_BORROWER_PAYMENT_CLEARING);
    assertEq(e4.amount, PRINCIPAL_REPAYMENT);
    assertEq(e4.entryType, ENTRY_BORROWER_PRINCIPAL_PAYMENT);

    // Verify key account balances
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -SERVICER_FEE);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -INVESTOR_INTEREST);
    assertEq(
      loans.getLoanAccountBalance(loanId, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE),
      0 // fully allocated
    );
    assertEq(
      loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING),
      0 // fully cleared
    );
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), -(SERVICER_FEE + INVESTOR_INTEREST));
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), -PRINCIPAL_REPAYMENT);
  }

  // ========== Auth Tests ==========

  function test_ApplyWaterfall_RevertsWhenUnauthorized() public {
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWhenCalledByBorrower() public {
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWhenCalledByInvestor() public {
    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_Reverts_WhenStatusCreated() public {
    uint64 newLoanId = _createTestLoan(PRINCIPAL);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.applyWaterfall(newLoanId, 0, 0, 0, 0, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_Reverts_WhenStatusFullyFunded() public {
    uint64 newLoanId = _createFullyFundedLoan(PRINCIPAL);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.applyWaterfall(newLoanId, 0, 0, 0, 0, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_Succeeds_WhenStatusFullyPaid() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.FullyPaid, 0, 0, timeNow);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, 0, 0, 0, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_Succeeds_WhenStatusChargedOff() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.ChargedOff, 0, 0, timeNow);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, 0, 0, 0, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_Reverts_WhenLoanDoesNotExist() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.applyWaterfall(999, 0, 0, 0, 0, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWhenStatusCancelled() public {
    // Set loan status to Cancelled
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Cancelled, 0, 0, timeNow);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWhenStatusClosed() public {
    // Set loan status to Closed
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Closed, 0, 0, timeNow);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  // ========== Negative Amount Tests ==========

  function test_ApplyWaterfall_RevertsWithNegativeMiscFees() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, -1, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWithNegativeServicingFees() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 0, -1, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWithNegativeInvestorInterest() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, -1, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWithNegativePrincipal() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, -1, 0, timeNow, REF);
  }

  // ========== Over-Allocation Tests ==========

  function test_ApplyWaterfall_RevertsWhenTotalExceedsPaymentClearing() public {
    // Payment clearing balance is PAYMENT_AMOUNT (600e6)
    // Try to allocate more than that
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PAYMENT_AMOUNT + 1, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWhenInterestExceedsOutstanding() public {
    // Accrual was 100e6, try to allocate more than that as interest+fees
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 0, 0, ACCRUAL_AMOUNT + 1, 0, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWhenMiscFeeExceedsReceivable() public {
    // First charge a misc fee
    vm.prank(servicer);
    loans.chargeMiscFee(loanId, 25e6, timeNow, REF);

    // Try to clear more misc fees than were charged
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 26e6, 0, 0, 0, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_RevertsWhenPrincipalExceedsOutstanding() public {
    // Setup: small loan with a borrower overpayment so payment_clearing > outstanding principal.
    // Outstanding principal = smallPrincipal (no prior repayments) = 100e6.
    // Payment clearing = 200e6 (overpayment).
    int128 smallPrincipal = 100e6;
    int128 smallAccrual = 10e6;
    int128 overpayment = 200e6;
    _setupWaterfallState(smallPrincipal, smallAccrual, overpayment);

    // 101e6 principal allocation is within payment clearing (200e6) but exceeds outstanding (100e6).
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 0, 0, 0, smallPrincipal + 1, 0, timeNow, REF);
  }

  function test_ApplyWaterfall_AllowsExactPrincipal() public accountingEquationHolds {
    int128 smallPrincipal = 100e6;
    int128 smallAccrual = 10e6;
    int128 overpayment = 200e6;
    _setupWaterfallState(smallPrincipal, smallAccrual, overpayment);

    // Exact outstanding principal succeeds (boundary case).
    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, 0, 0, smallPrincipal, 0, timeNow, REF);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), -smallPrincipal);
  }

  function test_ApplyWaterfall_PrincipalCapShrinksAfterPartialRepayment() public {
    // Setup: small loan with enough overpayment to repay principal fully twice over.
    int128 smallPrincipal = 100e6;
    int128 smallAccrual = 10e6;
    int128 overpayment = 200e6;
    _setupWaterfallState(smallPrincipal, smallAccrual, overpayment);

    // First waterfall: clear interest + repay 40 of 100 principal. Outstanding becomes 60.
    int128 firstPrincipalRepayment = 40e6;
    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, 0, smallAccrual, firstPrincipalRepayment, 0, timeNow, REF);

    // Second waterfall: 61 exceeds the now-shrunken outstanding (60) even though clearing has surplus.
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.applyWaterfall(loanId, 0, 0, 0, smallPrincipal - firstPrincipalRepayment + 1, 0, timeNow, REF);

    // The exact remaining outstanding succeeds.
    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, 0, 0, smallPrincipal - firstPrincipalRepayment, 0, timeNow, REF);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), -smallPrincipal);
  }

  // ========== Zero Amount Sub-Allocations ==========

  function test_ApplyWaterfall_PrincipalOnly(
    uint256 principalRaw,
    uint256 accrualRaw,
    uint256 paymentRaw,
    uint256 principalRepayRaw
  ) public accountingEquationHolds {
    int128 principal = int128(int256(bound(principalRaw, MIN_USDC_AMOUNT, MAX_USDC_AMOUNT)));
    int128 accrualAmount = int128(int256(bound(accrualRaw, MIN_USDC_AMOUNT, uint256(int256(principal)))));
    int128 paymentAmount = int128(int256(bound(paymentRaw, MIN_USDC_AMOUNT, uint256(int256(principal)))));
    _setupWaterfallState(principal, accrualAmount, paymentAmount);

    int128 principalRepay = int128(int256(bound(principalRepayRaw, 1, uint256(int256(paymentAmount)))));
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, 0, 0, principalRepay, 0, timeNow, REF);

    // Only 1 entry: principal payment (no fee/interest entries)
    assertEq(loans.entryCount(loanId), entryCountBefore + 1);

    Entry memory e = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(uint8(e.from), ACC_BORROWER_PRINCIPAL_REPAID);
    assertEq(uint8(e.to), ACC_BORROWER_PAYMENT_CLEARING);
    assertEq(e.amount, principalRepay);
  }

  function test_ApplyWaterfall_InterestOnly() public accountingEquationHolds {
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, 0, 0, timeNow, REF);

    // 3 entries: servicer fee alloc, investor interest alloc, interest debt clearance
    assertEq(loans.entryCount(loanId), entryCountBefore + 3);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -SERVICER_FEE);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -INVESTOR_INTEREST);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE), 0);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), -(SERVICER_FEE + INVESTOR_INTEREST));
    // Payment clearing only partially used (interest portion consumed, principal remains)
    assertEq(
      loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING),
      -(PAYMENT_AMOUNT - SERVICER_FEE - INVESTOR_INTEREST)
    );
    // No principal repayment
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), 0);
  }

  // ========== Sequential Waterfall Calls ==========

  function test_ApplyWaterfall_SequentialPartialAllocations(
    uint256 principalRaw,
    uint256 accrualRaw,
    uint256 paymentRaw,
    uint256 splitRaw
  ) public accountingEquationHolds {
    // principal must be large enough to cover accrual + at least MIN_USDC for principal repayment
    int128 principal = int128(int256(bound(principalRaw, 2 * MIN_USDC_AMOUNT, MAX_USDC_AMOUNT)));
    int128 accrualAmount = int128(
      int256(bound(accrualRaw, MIN_USDC_AMOUNT, uint256(int256(principal)) - MIN_USDC_AMOUNT))
    );
    // Payment must cover at least accrual + something for principal
    int128 paymentAmount = int128(
      int256(bound(paymentRaw, uint256(int256(accrualAmount)) + MIN_USDC_AMOUNT, uint256(int256(principal))))
    );
    _setupWaterfallState(principal, accrualAmount, paymentAmount);

    // Derive valid allocations from fuzzed state
    int128 svcFee = accrualAmount / 10;
    int128 invInterest = accrualAmount - svcFee;
    int128 principalRepay = paymentAmount - accrualAmount;

    // Fuzz how much principal goes in first call vs second call
    int128 firstPrincipal = int128(int256(bound(splitRaw, 0, uint256(int256(principalRepay)))));
    int128 secondPrincipal = principalRepay - firstPrincipal;

    // First call: allocate interest + first portion of principal
    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, svcFee, invInterest, firstPrincipal, 0, timeNow, REF);

    // Second call: allocate remaining principal (skip if zero)
    if (secondPrincipal > 0) {
      vm.prank(servicer);
      loans.applyWaterfall(loanId, 0, 0, 0, secondPrincipal, 0, timeNow, REF);
    }

    // Verify final state
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -svcFee);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -invInterest);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), -principalRepay);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING), 0);
  }

  // ========== With Misc Fees ==========

  function test_ApplyWaterfall_WithMiscFees(
    uint256 principalRaw,
    uint256 accrualRaw,
    uint256 paymentRaw,
    uint256 miscFeeRaw
  ) public accountingEquationHolds {
    // principal must be large enough to cover accrual + at least MIN_USDC for misc fee
    int128 principal = int128(int256(bound(principalRaw, 2 * MIN_USDC_AMOUNT, MAX_USDC_AMOUNT)));
    int128 accrualAmount = int128(
      int256(bound(accrualRaw, MIN_USDC_AMOUNT, uint256(int256(principal)) - MIN_USDC_AMOUNT))
    );
    // Need room for: accrual + at least 1 misc fee
    int128 paymentAmount = int128(
      int256(bound(paymentRaw, uint256(int256(accrualAmount)) + MIN_USDC_AMOUNT, uint256(int256(principal))))
    );
    _setupWaterfallState(principal, accrualAmount, paymentAmount);

    int128 svcFee = accrualAmount / 10;
    int128 invInterest = accrualAmount - svcFee;
    int128 remainingAfterInterest = paymentAmount - accrualAmount;
    int128 miscFeeAmount = int128(int256(bound(miscFeeRaw, MIN_USDC_AMOUNT, uint256(int256(remainingAfterInterest)))));

    // Charge misc fee
    vm.prank(servicer);
    loans.chargeMiscFee(loanId, miscFeeAmount, timeNow, REF);

    // Apply waterfall including misc fees
    int128 adjustedPrincipal = remainingAfterInterest - miscFeeAmount;
    vm.prank(servicer);
    loans.applyWaterfall(loanId, miscFeeAmount, svcFee, invInterest, adjustedPrincipal, 0, timeNow, REF);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING), 0);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_MISC_FEE_RECEIVABLE), miscFeeAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_MISC_FEE_PAID), -miscFeeAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_MISC_FEE_PAYABLE), -miscFeeAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -svcFee);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -invInterest);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE), 0);
  }

  function test_ApplyWaterfall_RevertsForNonExistentLoan() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.applyWaterfall(999, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);
  }

  // ========== Fuzz: Arbitrary Valid Split ==========

  function test_ApplyWaterfall_ArbitraryValidSplit(
    uint256 principalRaw,
    uint256 accrualRaw,
    uint256 paymentRaw,
    uint256 feeRaw,
    uint256 interestRaw,
    uint256 principalRepayRaw
  ) public accountingEquationHolds {
    int128 principal = int128(int256(bound(principalRaw, MIN_USDC_AMOUNT, MAX_USDC_AMOUNT)));
    int128 accrualAmount = int128(int256(bound(accrualRaw, MIN_USDC_AMOUNT, uint256(int256(principal)))));
    int128 paymentAmount = int128(int256(bound(paymentRaw, MIN_USDC_AMOUNT, uint256(int256(principal)))));
    _setupWaterfallState(principal, accrualAmount, paymentAmount);

    // Interest allocations are limited by both the accrual and the payment available
    int128 maxInterest = accrualAmount < paymentAmount ? accrualAmount : paymentAmount;
    int128 servicerFee = int128(int256(bound(feeRaw, 0, uint256(int256(maxInterest)))));
    int128 investorInterest = int128(int256(bound(interestRaw, 0, uint256(int256(maxInterest - servicerFee)))));
    // Cap principal repayment to remaining payment after interest allocations
    int128 maxPrincipal = paymentAmount - servicerFee - investorInterest;
    int128 principalRepay = maxPrincipal > 0
      ? int128(int256(bound(principalRepayRaw, 0, uint256(int256(maxPrincipal)))))
      : int128(0);
    int128 totalAllocated = servicerFee + investorInterest + principalRepay;
    vm.assume(totalAllocated > 0);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, servicerFee, investorInterest, principalRepay, 0, timeNow, REF);

    // Payment clearing decreased by total allocated
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING), -(paymentAmount - totalAllocated));
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -servicerFee);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -investorInterest);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), -principalRepay);
  }

  function test_applyWaterfall_UpdatesNextDueDate() public {
    uint48 newDueDate = timeNow + 30 days;

    vm.expectEmit(true, false, false, true, address(loans));
    emit ILoans.LoanNextDueDateUpdated(loanId, newDueDate);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, newDueDate, timeNow, REF);

    (, , , uint48 nextDueDate, ) = loans.data(loanId);
    assertEq(nextDueDate, newDueDate);
  }

  function test_applyWaterfall_LeavesNextDueDateWhenZero() public {
    (, , , uint48 dueDateBefore, ) = loans.data(loanId);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, 0, timeNow, REF);

    (, , , uint48 dueDateAfter, ) = loans.data(loanId);
    assertEq(dueDateAfter, dueDateBefore);
  }
}
