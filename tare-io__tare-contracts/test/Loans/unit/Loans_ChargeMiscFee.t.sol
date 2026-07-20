// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, ILoans, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {ENTRY_MISC_FEE_CHARGE} from "contracts/interfaces/LedgerEntries.sol";
import {ACC_SERVICER_MISC_FEE_PAYABLE, ACC_BORROWER_MISC_FEE_RECEIVABLE} from "contracts/interfaces/Accounts.sol";
import {MIN_USDC_AMOUNT, MAX_USDC_AMOUNT} from "test/lib/Constants.sol";

/// @notice Unit tests for Loans.chargeMiscFee()
contract Loans_ChargeMiscFeeTest is LoansTestBase {
  int128 constant PRINCIPAL = 10_000e6;
  bytes32 constant REF = bytes32("misc_fee_ref");

  function setUp() public override {
    super.setUp();
    loanId = _createActiveLoan(PRINCIPAL);
  }

  function test_ChargeMiscFee_AsServicer(uint256 feeRaw) public accountingEquationHolds {
    int128 feeAmount = int128(int256(bound(feeRaw, MIN_USDC_AMOUNT, MAX_USDC_AMOUNT)));

    vm.prank(servicer);
    loans.chargeMiscFee(loanId, feeAmount, timeNow, REF);

    uint64 entryNumber = loans.entryCount(loanId);
    Entry memory entry = loans.getLoanEntry(loanId, entryNumber);
    assertEq(entry.amount, feeAmount);
    assertEq(uint8(entry.from), ACC_SERVICER_MISC_FEE_PAYABLE);
    assertEq(uint8(entry.to), ACC_BORROWER_MISC_FEE_RECEIVABLE);
    assertEq(entry.entryType, ENTRY_MISC_FEE_CHARGE);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_MISC_FEE_PAYABLE), -feeAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_MISC_FEE_RECEIVABLE), feeAmount);
  }

  function test_ChargeMiscFee_AsAdmin(uint256 feeRaw) public accountingEquationHolds {
    int128 feeAmount = int128(int256(bound(feeRaw, MIN_USDC_AMOUNT, MAX_USDC_AMOUNT)));

    vm.prank(admin);
    loans.chargeMiscFee(loanId, feeAmount, timeNow, REF);

    uint64 entryNumber = loans.entryCount(loanId);
    Entry memory entry = loans.getLoanEntry(loanId, entryNumber);
    assertEq(entry.amount, feeAmount);
  }

  function test_ChargeMiscFee_RevertsWhenUnauthorized() public {
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.chargeMiscFee(loanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_RevertsWhenCalledByBorrower() public {
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.chargeMiscFee(loanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_RevertsWithZeroAmount() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.chargeMiscFee(loanId, 0, timeNow, REF);
  }

  function test_ChargeMiscFee_RevertsWithNegativeAmount() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.chargeMiscFee(loanId, -1e6, timeNow, REF);
  }

  function test_ChargeMiscFee_RevertsOnCancelledLoan() public {
    uint64 cancelledLoanId = _createCancelledLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.chargeMiscFee(cancelledLoanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_RevertsOnClosedLoan() public {
    uint64 closedLoanId = _createClosedLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.chargeMiscFee(closedLoanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_Reverts_WhenStatusCreated() public {
    uint64 createdLoanId = _createTestLoan(PRINCIPAL);
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.chargeMiscFee(createdLoanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_Reverts_WhenStatusFullyFunded() public {
    uint64 fullyFundedLoanId = _createFullyFundedLoan(PRINCIPAL);
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.chargeMiscFee(fullyFundedLoanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_Reverts_WhenStatusFullyPaid() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.FullyPaid, 0, 0, timeNow);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.chargeMiscFee(loanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_Succeeds_WhenStatusChargedOff() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.ChargedOff, 0, 0, timeNow);

    vm.prank(servicer);
    loans.chargeMiscFee(loanId, 25e6, timeNow, REF);
  }

  function test_ChargeMiscFee_Reverts_WhenLoanDoesNotExist() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.chargeMiscFee(999, 25e6, timeNow, REF);
  }
}
