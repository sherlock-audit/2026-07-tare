// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {LoanStatus, LoanTerms} from "contracts/interfaces/ILoans.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_LoanTermsTest is LoansTestBase {
  int128 constant PRINCIPAL = 10_000e6;
  int128 constant PAYMENT_AMOUNT = 600e6;
  uint32 constant INTEREST_RATE = 500; // 5.00%
  int128 constant EXPECTED_MONTHLY_PAYMENT = 850e6;
  bytes32 constant REF = bytes32("test_ref");

  function test_loanTerms_setAtDisburse() public {
    uint64 id = _createFullyFundedLoan(PRINCIPAL);

    vm.prank(originator);
    loans.disburse(
      id,
      PRINCIPAL,
      0,
      timeNow,
      timeNow + 30 days,
      timeNow + 365 days,
      INTEREST_RATE,
      EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      REF
    );

    (uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment) = loans.loanTerms(id);
    assertEq(originationDate, timeNow);
    assertEq(interestRate, INTEREST_RATE);
    assertEq(expectedMonthlyPayment, EXPECTED_MONTHLY_PAYMENT);
  }

  function test_loanTerms_zeroBeforeDisburse() public {
    uint64 id = _createFullyFundedLoan(PRINCIPAL);

    (uint48 originationDate, uint32 interestRate, int128 expectedMonthlyPayment) = loans.loanTerms(id);
    assertEq(originationDate, 0);
    assertEq(interestRate, 0);
    assertEq(expectedMonthlyPayment, 0);
  }

  function test_lastPaymentDate_zeroBeforePayment() public {
    uint64 id = _createActiveLoan(PRINCIPAL);

    (, , uint48 lastPaymentDate, , ) = loans.data(id);
    assertEq(lastPaymentDate, 0);
  }

  function test_lastPaymentDate_updatedAfterPayment() public {
    uint64 id = _createActiveLoan(PRINCIPAL);

    usdc.mint(borrower, asUint(PAYMENT_AMOUNT));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    uint48 paymentTimestamp = timeNow + 15 days;
    vm.prank(borrower);
    loans.pay(id, PAYMENT_AMOUNT, paymentTimestamp, REF);

    (, , uint48 lastPaymentDate, , ) = loans.data(id);
    assertEq(lastPaymentDate, paymentTimestamp);
  }

  function test_lastPaymentDate_updatesOnEachPayment() public {
    uint64 id = _createActiveLoan(PRINCIPAL);

    usdc.mint(borrower, asUint(PAYMENT_AMOUNT * 2));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    // First payment
    uint48 firstTimestamp = timeNow + 15 days;
    vm.prank(borrower);
    loans.pay(id, PAYMENT_AMOUNT, firstTimestamp, REF);

    (, , uint48 lastPaymentDate1, , ) = loans.data(id);
    assertEq(lastPaymentDate1, firstTimestamp);

    // Second payment
    uint48 secondTimestamp = timeNow + 45 days;
    vm.prank(borrower);
    loans.pay(id, PAYMENT_AMOUNT, secondTimestamp, REF);

    (, , uint48 lastPaymentDate2, , ) = loans.data(id);
    assertEq(lastPaymentDate2, secondTimestamp);
  }

  function test_dataNoLongerReturnsOriginationDate() public {
    uint64 id = _createActiveLoan(PRINCIPAL);

    // data() returns (status, updatedAt, lastPaymentDate, nextDueDate, maturityDate)
    (LoanStatus status, uint48 updatedAt, uint48 lastPaymentDate, uint48 nextDueDate, uint48 maturityDate) = loans.data(
      id
    );

    assertEq(uint8(status), uint8(LoanStatus.Active));
    assertTrue(nextDueDate > 0);
    assertTrue(maturityDate > 0);
    assertTrue(updatedAt > 0);
    assertEq(lastPaymentDate, 0);

    // originationDate is now in loanTerms
    (uint48 originationDate, , ) = loans.loanTerms(id);
    assertTrue(originationDate > 0);
  }
}
