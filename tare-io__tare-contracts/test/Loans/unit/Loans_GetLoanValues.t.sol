// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {InvestorWithdrawalResult, LoanValue, LoanStatus} from "contracts/Loans.sol";
import {
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_REPAID
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_GetLoanValuesTest is LoansTestBase {
  bytes32 constant REF = bytes32("test_ref");

  function setUp() public override {
    super.setUp();

    usdc.mint(borrower, 1_000_000_000e6);
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);
  }

  function test_singleActiveLoan() public {
    int128 principal = 10_000e6;
    uint64 id = _createActiveLoan(principal);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    LoanValue[] memory results = loans.getLoanValues(ids);

    assertEq(results.length, 1);
    assertEq(results[0].outstandingInvestorPrincipal, principal);
    assertEq(results[0].investorPrincipalWithdrawable, 0);
    assertEq(results[0].investorInterestWithdrawable, 0);
    assertEq(uint8(results[0].status), uint8(LoanStatus.Active));

    (, , , uint48 nextDueDate, ) = loans.data(id);
    assertEq(results[0].nextDueDate, nextDueDate);
  }

  function test_loanWithCashflow() public {
    int128 principal = DEFAULT_TEST_PRINCIPAL;
    uint64 id = _createLoanWithInvestorCashflow(principal, REF);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    LoanValue[] memory results = loans.getLoanValues(ids);

    // Borrower has repaid DEFAULT_PRINCIPAL_REPAYMENT (now collected in Loans and withdrawable by investor)
    assertEq(results[0].investorPrincipalWithdrawable, DEFAULT_PRINCIPAL_REPAYMENT);
    // Investor capital deployed is unchanged until the investor withdraws
    assertEq(results[0].outstandingInvestorPrincipal, principal);
    assertEq(results[0].investorInterestWithdrawable, DEFAULT_INVESTOR_INTEREST);
    assertEq(uint8(results[0].status), uint8(LoanStatus.Active));
    assertEq(results[0].nextDueDate, timeNow + 30 days);
  }

  function test_afterPartialInvestorWithdraw() public {
    int128 principal = DEFAULT_TEST_PRINCIPAL;
    uint64 id = _createLoanWithInvestorCashflow(principal, REF);

    uint64[] memory withdrawIds = new uint64[](1);
    withdrawIds[0] = id;
    vm.prank(investor);
    InvestorWithdrawalResult[] memory withdrawResults = loans.investorWithdraw(withdrawIds, timeNow, REF);

    int128 principalWithdrawn = withdrawResults[0].principal;
    int128 interestWithdrawn = withdrawResults[0].interest;

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    LoanValue[] memory results = loans.getLoanValues(ids);

    // Investor pulled out everything Loans had collected; nothing left to withdraw
    assertEq(results[0].investorPrincipalWithdrawable, 0);
    // After withdrawal, investor capital is reduced by the amount they took out
    assertEq(results[0].outstandingInvestorPrincipal, principal - principalWithdrawn);
    assertEq(results[0].investorInterestWithdrawable, DEFAULT_INVESTOR_INTEREST - interestWithdrawn);
  }

  function test_multipleLoans() public {
    uint64 id1 = _createActiveLoan(10_000e6);
    uint64 id2 = _createLoanWithInvestorCashflow(20_000e6, REF);
    uint64 id3 = _createTestLoan(5_000e6);

    uint64[] memory ids = new uint64[](3);
    ids[0] = id1;
    ids[1] = id2;
    ids[2] = id3;
    LoanValue[] memory results = loans.getLoanValues(ids);

    assertEq(results.length, 3);
    assertEq(uint8(results[0].status), uint8(LoanStatus.Active));
    assertEq(results[0].outstandingInvestorPrincipal, 10_000e6);
    assertEq(results[0].investorPrincipalWithdrawable, 0);
    assertEq(results[0].investorInterestWithdrawable, 0);
    assertEq(results[0].nextDueDate, timeNow + 30 days);
    assertEq(uint8(results[1].status), uint8(LoanStatus.Active));
    assertEq(results[1].outstandingInvestorPrincipal, 20_000e6);
    assertEq(results[1].investorPrincipalWithdrawable, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(results[1].investorInterestWithdrawable, DEFAULT_INVESTOR_INTEREST);
    assertEq(results[1].nextDueDate, timeNow + 30 days);
    assertEq(uint8(results[2].status), uint8(LoanStatus.Created));
    // Created loan: no investor capital deployed yet
    assertEq(results[2].outstandingInvestorPrincipal, 0);
    assertEq(results[2].investorPrincipalWithdrawable, 0);
    assertEq(results[2].investorInterestWithdrawable, 0);
    assertEq(results[2].nextDueDate, 0);
  }

  function test_nonExistentLoanId() public {
    uint64[] memory ids = new uint64[](1);
    ids[0] = 9999;
    LoanValue[] memory results = loans.getLoanValues(ids);

    assertEq(results.length, 1);
    assertEq(results[0].outstandingInvestorPrincipal, 0);
    assertEq(results[0].investorPrincipalWithdrawable, 0);
    assertEq(results[0].investorInterestWithdrawable, 0);
    assertEq(uint8(results[0].status), uint8(LoanStatus.DoesNotExist));
    assertEq(results[0].nextDueDate, 0);
  }

  function test_loanIdZero_ReturnsDoesNotExist() public {
    uint64[] memory ids = new uint64[](1);
    ids[0] = 0;
    LoanValue[] memory results = loans.getLoanValues(ids);

    assertEq(results.length, 1);
    assertEq(results[0].outstandingInvestorPrincipal, 0);
    assertEq(results[0].investorPrincipalWithdrawable, 0);
    assertEq(results[0].investorInterestWithdrawable, 0);
    assertEq(uint8(results[0].status), uint8(LoanStatus.DoesNotExist));
    assertEq(results[0].nextDueDate, 0);
  }

  function test_nextDueDateVariation() public {
    uint64 id1 = _createActiveLoan(10_000e6);

    vm.prank(servicer);
    loans.accrue(id1, DEFAULT_ACCRUAL_AMOUNT, timeNow, REF);

    uint48 newDueDate = timeNow + 60 days;

    vm.prank(borrower);
    loans.pay(id1, DEFAULT_PAYMENT_AMOUNT, timeNow, REF);

    vm.prank(servicer);
    loans.applyWaterfall(id1, 0, 0, 0, 0, newDueDate, timeNow, REF);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id1;
    LoanValue[] memory results = loans.getLoanValues(ids);

    assertEq(results[0].nextDueDate, newDueDate);
  }

  function test_matchesIndividualCalls() public {
    uint64 id = _createLoanWithInvestorCashflow(DEFAULT_TEST_PRINCIPAL, REF);

    int128 borrowerRepaid = loans.getLoanAccountBalance(id, ACC_BORROWER_PRINCIPAL_REPAID);
    int128 investorPrincipalPayable = loans.getLoanAccountBalance(id, ACC_INVESTOR_PRINCIPAL_PAYABLE);
    int128 investorPrincipalRepaid = loans.getLoanAccountBalance(id, ACC_INVESTOR_PRINCIPAL_REPAID);
    int128 interestPayable = loans.getLoanAccountBalance(id, ACC_INVESTOR_INTEREST_PAYABLE);
    int128 interestPaid = loans.getLoanAccountBalance(id, ACC_INVESTOR_INTEREST_PAID);
    (LoanStatus status, , , , ) = loans.data(id);
    (, , , uint48 nextDueDate, ) = loans.data(id);

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    LoanValue[] memory results = loans.getLoanValues(ids);

    assertEq(results[0].outstandingInvestorPrincipal, -investorPrincipalPayable - investorPrincipalRepaid);
    assertEq(results[0].investorPrincipalWithdrawable, -borrowerRepaid - investorPrincipalRepaid);
    assertEq(results[0].investorInterestWithdrawable, -interestPayable - interestPaid);
    assertEq(uint8(results[0].status), uint8(status));
    assertEq(results[0].nextDueDate, nextDueDate);
  }

  // Full lifecycle: accrue → pay → waterfall → withdraw → accrue → pay → waterfall → check remaining
  function test_complexLifecycle() public {
    int128 principal = 100_000e6;
    uint64 loanId = _createActiveLoan(principal);

    // ============ Phase 1: First payment cycle ============
    int128 servicerFee1 = 20e6;
    int128 investorInterest1 = 980e6;
    int128 accrual1 = servicerFee1 + investorInterest1;
    int128 principalRepayment1 = 1_000e6;
    int128 payment1 = accrual1 + principalRepayment1; // 2k monthly payment

    vm.prank(servicer);
    loans.accrue(loanId, accrual1, timeNow, REF);

    uint48 dueDate2 = timeNow + 60 days;
    vm.prank(borrower);
    loans.pay(loanId, payment1, timeNow, REF);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, servicerFee1, investorInterest1, principalRepayment1, dueDate2, timeNow, REF);

    // ============ Phase 2: Investor withdraws all available ============
    uint64[] memory withdrawloanIds = new uint64[](1);
    withdrawloanIds[0] = loanId;
    vm.prank(investor);
    InvestorWithdrawalResult[] memory withdrawals = loans.investorWithdraw(withdrawloanIds, timeNow, REF);
    assertEq(withdrawals[0].principal, principalRepayment1);
    assertEq(withdrawals[0].interest, investorInterest1);

    // ============ Phase 3: Second payment cycle (no withdraw) ============
    int128 servicerFee2 = 20e6;
    int128 investorInterest2 = 880e6;
    int128 accrual2 = servicerFee2 + investorInterest2;
    int128 principalRepayment2 = 1_100e6;
    int128 payment2 = accrual2 + principalRepayment2; // 2k monthly payment

    vm.prank(servicer);
    loans.accrue(loanId, accrual2, timeNow, REF);

    uint48 dueDate3 = timeNow + 90 days;
    vm.prank(borrower);
    loans.pay(loanId, payment2, timeNow, REF);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, servicerFee2, investorInterest2, principalRepayment2, dueDate3, timeNow, REF);

    // ============ Phase 4: Verify getLoanValues reflects full state ============
    uint64[] memory ids = new uint64[](1);
    ids[0] = loanId;
    LoanValue[] memory results = loans.getLoanValues(ids);

    // Investor capital deployed minus already-withdrawn principal
    int128 expectedOutstandingInvestorPrincipal = principal - principalRepayment1;
    assertEq(results[0].outstandingInvestorPrincipal, expectedOutstandingInvestorPrincipal);
    // Investor withdrew principalRepayment1 in phase 2; phase 3 waterfall left principalRepayment2 collectable
    assertEq(results[0].investorPrincipalWithdrawable, principalRepayment2);

    // Net outstanding investor interest = total interest - withdrawn interest (which includes interest accrued but not yet withdrawn)
    assertEq(results[0].investorInterestWithdrawable, investorInterest2);

    assertEq(uint8(results[0].status), uint8(LoanStatus.Active));
    assertEq(results[0].nextDueDate, dueDate3);
  }

  // After charge-off, getLoanValues must still report the ledger truth: outstanding investor
  // principal stays at the unrecovered amount, withdrawable cash reflects whatever has been
  // collected but not yet pulled, and the status flips to ChargedOff. NavCalculator depends on
  // this split to apply the ChargedOff bucket factor only to the credit-exposed portion.
  function test_chargedOffLoanReportsSplit() public {
    int128 principal = DEFAULT_TEST_PRINCIPAL;
    uint64 id = _createLoanWithInvestorCashflow(principal, REF);

    vm.prank(servicer);
    loans.updateLoanData({
      loanId: id,
      status: LoanStatus.ChargedOff,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    LoanValue[] memory results = loans.getLoanValues(ids);

    // Charge-off doesn't touch the ledger — investor capital remains deployed in full.
    assertEq(results[0].outstandingInvestorPrincipal, principal);
    // Whatever the borrower already repaid is still sitting collected, awaiting withdrawal.
    assertEq(results[0].investorPrincipalWithdrawable, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(results[0].investorInterestWithdrawable, DEFAULT_INVESTOR_INTEREST);
    assertEq(uint8(results[0].status), uint8(LoanStatus.ChargedOff));
  }
}
