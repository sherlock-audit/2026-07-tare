// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {LoanStatus, ILoans} from "contracts/interfaces/ILoans.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Tests for Loans.updateLoanTerms()
contract Loans_UpdateLoanTermsTest is LoansTestBase {
  uint32 constant NEW_INTEREST_RATE = 1500;
  int128 constant NEW_EXPECTED_MONTHLY_PAYMENT = 777e6;
  uint64 constant NON_EXISTENT_LOAN_ID = 999;

  function setUp() public override {
    super.setUp();
    // Active loan has terms set during disburse:
    // originationDate = timeNow, interestRate = DEFAULT_INTEREST_RATE,
    // expectedMonthlyPayment = DEFAULT_EXPECTED_MONTHLY_PAYMENT.
    loanId = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
  }

  // ========== Auth Tests ==========

  function test_UpdateLoanTerms_AsServicer() public {
    vm.prank(servicer);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);

    (, uint32 interestRate, ) = loans.loanTerms(loanId);
    assertEq(interestRate, NEW_INTEREST_RATE);
  }

  function test_UpdateLoanTerms_AsAdmin() public {
    vm.prank(admin);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);

    (, uint32 interestRate, ) = loans.loanTerms(loanId);
    assertEq(interestRate, NEW_INTEREST_RATE);
  }

  function test_UpdateLoanTerms_AsGuardian() public {
    vm.prank(guardian);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);

    (, uint32 interestRate, ) = loans.loanTerms(loanId);
    assertEq(interestRate, NEW_INTEREST_RATE);
  }

  function test_UpdateLoanTerms_RevertsWhenUnauthorized() public {
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);
  }

  function test_UpdateLoanTerms_RevertsWhenCalledByBorrower() public {
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);
  }

  function test_UpdateLoanTerms_RevertsForNonExistentLoan() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.updateLoanTerms(NON_EXISTENT_LOAN_ID, 0, NEW_INTEREST_RATE, 0);
  }

  function test_UpdateLoanTerms_RevertsWhenPaused() public {
    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);
  }

  // ========== Terminal Status ==========

  function test_UpdateLoanTerms_RevertsWhenCancelled() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Cancelled, 0, 0, timeNow);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);
  }

  function test_UpdateLoanTerms_RevertsWhenClosed() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Closed, 0, 0, timeNow);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);
  }

  // ========== Field Updates ==========

  function test_UpdateLoanTerms_UpdatesOriginationDate() public {
    uint48 newDate = timeNow + 10 days;
    vm.prank(servicer);
    loans.updateLoanTerms(loanId, newDate, 0, 0);

    (uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment) = loans.loanTerms(loanId);
    assertEq(originationDate, newDate);
    // Untouched fields remain at their disburse values.
    assertEq(interestRate, DEFAULT_INTEREST_RATE);
    assertEq(expectedMonthlyPayment, DEFAULT_EXPECTED_MONTHLY_PAYMENT);
  }

  function test_UpdateLoanTerms_UpdatesExpectedMonthlyPayment() public {
    vm.prank(servicer);
    loans.updateLoanTerms(loanId, 0, 0, NEW_EXPECTED_MONTHLY_PAYMENT);

    (uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment) = loans.loanTerms(loanId);
    assertEq(expectedMonthlyPayment, NEW_EXPECTED_MONTHLY_PAYMENT);
    assertEq(originationDate, timeNow);
    assertEq(interestRate, DEFAULT_INTEREST_RATE);
  }

  function test_UpdateLoanTerms_UpdatesAllFieldsAtOnce() public {
    uint48 newDate = timeNow + 10 days;

    vm.prank(servicer);
    loans.updateLoanTerms(loanId, newDate, NEW_INTEREST_RATE, NEW_EXPECTED_MONTHLY_PAYMENT);

    (uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment) = loans.loanTerms(loanId);
    assertEq(originationDate, newDate);
    assertEq(interestRate, NEW_INTEREST_RATE);
    assertEq(expectedMonthlyPayment, NEW_EXPECTED_MONTHLY_PAYMENT);
  }

  // ========== Sentinel (0 = no change) ==========

  function test_UpdateLoanTerms_ZeroLeavesFieldsUnchanged() public {
    vm.prank(servicer);
    loans.updateLoanTerms(loanId, 0, 0, 0);

    (uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment) = loans.loanTerms(loanId);
    assertEq(originationDate, timeNow);
    assertEq(interestRate, DEFAULT_INTEREST_RATE);
    assertEq(expectedMonthlyPayment, DEFAULT_EXPECTED_MONTHLY_PAYMENT);
  }

  // ========== Bookkeeping ==========

  function test_UpdateLoanTerms_UpdatesTimestampToBlockTime() public {
    uint48 warpTo = timeNow + 100 days;
    vm.warp(warpTo);

    vm.prank(servicer);
    loans.updateLoanTerms(loanId, 0, NEW_INTEREST_RATE, 0);

    (, uint48 updatedAt, , , ) = loans.data(loanId);
    assertEq(updatedAt, warpTo);
  }

  function test_UpdateLoanTerms_EmitsLoanTermsSetWithStoredValues() public {
    uint48 newDate = timeNow + 10 days;

    vm.prank(servicer);
    vm.expectEmit(true, false, false, true, address(loans));
    // Only originationDate changes; other fields keep their disburse values.
    emit ILoans.LoanTermsSet(loanId, newDate, DEFAULT_INTEREST_RATE, DEFAULT_EXPECTED_MONTHLY_PAYMENT);
    loans.updateLoanTerms(loanId, newDate, 0, 0);
  }
}
