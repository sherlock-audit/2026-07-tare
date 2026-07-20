// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {LoanStatus, ILoans} from "contracts/interfaces/ILoans.sol";
import {MIN_TIMESTAMP, MAX_TIMESTAMP} from "test/lib/Constants.sol";

/// @notice Tests for Loans.updateLoanData()
contract Loans_UpdateLoanDataTest is LoansTestBase {
  function setUp() public override {
    super.setUp();
    loanId = _createTestLoan();
  }

  // ========== Auth Tests ==========

  function test_UpdateLoanData_AsServicer() public {
    uint48 nextDueDate = timeNow + 30 days;
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, nextDueDate, 0, timeNow);

    (, , , uint48 storedNextDueDate, ) = loans.data(loanId);
    assertEq(storedNextDueDate, nextDueDate);
  }

  function test_UpdateLoanData_AsAdmin() public {
    uint48 nextDueDate = timeNow + 30 days;
    vm.prank(admin);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, nextDueDate, 0, timeNow);

    (, , , uint48 storedNextDueDate, ) = loans.data(loanId);
    assertEq(storedNextDueDate, nextDueDate);
  }

  function test_UpdateLoanData_RevertsWhenUnauthorized() public {
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, timeNow + 30 days, 0, timeNow);
  }

  function test_UpdateLoanData_RevertsWhenCalledByBorrower() public {
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, timeNow + 30 days, 0, timeNow);
  }

  function test_UpdateLoanData_RevertsForNonExistentLoan() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.updateLoanData(999, LoanStatus.DoesNotExist, timeNow + 30 days, 0, timeNow);
  }

  // ========== Status Updates ==========

  function test_UpdateLoanData_UpdatesStatus() public {
    vm.prank(servicer);
    vm.expectEmit(true, false, false, true, address(loans));
    emit ILoans.LoanStatusUpdated(loanId, LoanStatus.Created, LoanStatus.Cancelled);
    loans.updateLoanData(loanId, LoanStatus.Cancelled, 0, 0, timeNow);

    (LoanStatus status, , , , ) = loans.data(loanId);
    assertEq(uint8(status), uint8(LoanStatus.Cancelled));
  }

  function test_UpdateLoanData_DoesNotUpdateStatusWhenZeroIsPassed() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, timeNow + 30 days, 0, timeNow);

    (LoanStatus status, , , , ) = loans.data(loanId);
    // Status unchanged when DoesNotExist sentinel passed
    assertEq(uint8(status), uint8(LoanStatus.Created));
  }

  // ========== Date Updates ==========

  function test_UpdateLoanData_UpdatesNextDueDate(uint48 nextDueDate) public {
    nextDueDate = uint48(bound(nextDueDate, MIN_TIMESTAMP, MAX_TIMESTAMP));

    vm.prank(servicer);
    vm.expectEmit(true, false, false, true, address(loans));
    emit ILoans.LoanNextDueDateUpdated(loanId, nextDueDate);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, nextDueDate, 0, timeNow);

    (, , , uint48 storedNextDueDate, ) = loans.data(loanId);
    assertEq(storedNextDueDate, nextDueDate);
  }

  function test_UpdateLoanData_UpdatesMaturityDate(uint48 maturityDate) public {
    maturityDate = uint48(bound(maturityDate, MIN_TIMESTAMP, MAX_TIMESTAMP));

    vm.prank(servicer);
    vm.expectEmit(true, false, false, true, address(loans));
    emit ILoans.LoanMaturityDateUpdated(loanId, maturityDate);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, 0, maturityDate, timeNow);

    (, , , , uint48 storedMaturityDate) = loans.data(loanId);
    assertEq(storedMaturityDate, maturityDate);
  }

  function test_UpdateLoanData_SkipsDatesWhenZero() public {
    uint48 nextDueDate = timeNow + 30 days;
    uint48 maturityDate = timeNow + 365 days;
    // First set dates
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, nextDueDate, maturityDate, timeNow);

    // Then call with zeros — dates should remain unchanged
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, 0, 0, timeNow);

    (, , , uint48 storedNextDueDate, uint48 storedMaturityDate) = loans.data(loanId);
    assertEq(storedNextDueDate, nextDueDate);
    assertEq(storedMaturityDate, maturityDate);
  }

  function test_UpdateLoanData_UpdatesAllFieldsAtOnce(uint48 nextDueDate, uint48 maturityDate) public {
    nextDueDate = uint48(bound(nextDueDate, MIN_TIMESTAMP, MAX_TIMESTAMP));
    maturityDate = uint48(bound(maturityDate, MIN_TIMESTAMP, MAX_TIMESTAMP));

    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Cancelled, nextDueDate, maturityDate, timeNow);

    (LoanStatus status, , , uint48 storedNextDueDate, uint48 storedMaturityDate) = loans.data(loanId);
    assertEq(uint8(status), uint8(LoanStatus.Cancelled));
    assertEq(storedNextDueDate, nextDueDate);
    assertEq(storedMaturityDate, maturityDate);
  }

  function test_UpdateLoanData_UpdatesTimestamp(uint48 updateTime) public {
    updateTime = uint48(bound(updateTime, MIN_TIMESTAMP, MAX_TIMESTAMP));

    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.DoesNotExist, 0, 0, updateTime);

    (, uint48 updatedAt, , , ) = loans.data(loanId);
    assertEq(updatedAt, updateTime);
  }
}
