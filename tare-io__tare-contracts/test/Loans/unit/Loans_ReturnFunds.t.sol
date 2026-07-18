// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry} from "contracts/interfaces/ILoans.sol";
import {ENTRY_SERVICER_FUND_RETURN} from "contracts/interfaces/LedgerEntries.sol";
import {ILoans, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {
  ACC_CASH,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_SERVICER_ADJUSTMENT,
  ACC_SERVICER_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAID
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_ReturnFundsTest is LoansTestBase {
  bytes32 constant REF = bytes32("test_ref");

  function setUp() public override {
    super.setUp();
    loanId = _createLoanWithInvestorCashflow(DEFAULT_PRINCIPAL_AMOUNT, REF);

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId;
    vm.prank(servicer);
    loans.servicerWithdraw(loanIds, timeNow, REF);
  }

  function test_returnFunds_servicingFee() public accountingEquationHolds {
    uint256 servicerBalanceBefore = usdc.balanceOf(servicer);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    uint128 entryIndex = loans.returnFunds(
      loanId,
      ACC_SERVICER_FEE_PAID,
      DEFAULT_SERVICER_FEE,
      timeNow,
      ENTRY_SERVICER_FUND_RETURN,
      REF
    );

    assertGt(entryIndex, 0);
    assertEq(loans.entryCount(loanId), entryCountBefore + 1);

    Entry memory entry = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(entry.from, ACC_SERVICER_FEE_PAID);
    assertEq(entry.to, ACC_CASH);
    assertEq(entry.amount, DEFAULT_SERVICER_FEE);
    assertEq(entry.entryType, ENTRY_SERVICER_FUND_RETURN);
    assertEq(entry.ref, REF);

    assertEq(usdc.balanceOf(servicer), servicerBalanceBefore - asUint(DEFAULT_SERVICER_FEE));
    assertEq(_loansContractBalance(), contractBalanceBefore + asUint(DEFAULT_SERVICER_FEE));
  }

  function test_returnFunds_revertsOnUnauthorized() public {
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.returnFunds(loanId, ACC_SERVICER_FEE_PAID, DEFAULT_SERVICER_FEE, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  function test_returnFunds_revertsOnInvalidAccount() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAccount.selector);
    loans.returnFunds(
      loanId,
      ACC_INVESTOR_INTEREST_PAID,
      DEFAULT_SERVICER_FEE,
      timeNow,
      ENTRY_SERVICER_FUND_RETURN,
      REF
    );
  }

  function test_ReturnFunds_RevertsWithNegativeAmount() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.returnFunds(loanId, ACC_SERVICER_FEE_PAID, -1, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  // Fix: prevent servicer from returning more than was actually collected for fee accounts.
  // Without bounding the amount, a servicer who never collected fees on a loan could call
  // returnFunds with an arbitrary positive amount, manipulating ledger balances.
  function test_ReturnFunds_Reverts_WhenAmountExceedsServicerFeePaidBalance() public {
    int128 collected = loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAID);
    assertGt(collected, 0);

    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAccount.selector);
    loans.returnFunds(loanId, ACC_SERVICER_FEE_PAID, collected + 1, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  function test_ReturnFunds_Reverts_WhenAmountExceedsServicerMiscFeePaidBalance() public {
    // ACC_SERVICER_MISC_FEE_PAID has never been credited on this loan (balance = 0).
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_MISC_FEE_PAID), 0);

    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidAccount.selector);
    loans.returnFunds(loanId, ACC_SERVICER_MISC_FEE_PAID, 1, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  // ACC_SERVICER_ADJUSTMENT is unbounded by design (a discretionary credit).
  function test_ReturnFunds_Succeeds_WhenAccountServicerAdjustment() public {
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);
    usdc.mint(servicer, 1_000e6);

    vm.prank(servicer);
    uint128 entryIndex = loans.returnFunds(
      loanId,
      ACC_SERVICER_ADJUSTMENT,
      1_000e6,
      timeNow,
      ENTRY_SERVICER_FUND_RETURN,
      REF
    );
    assertGt(entryIndex, 0);
  }

  function test_ReturnFunds_Succeeds_WhenAccountServicerMiscFeePaid() public accountingEquationHolds {
    // Build up a positive ACC_SERVICER_MISC_FEE_PAID balance via the natural flow:
    // charge a misc fee, receive a borrower payment to cover it, waterfall to the misc payable,
    // then have the servicer withdraw it.
    int128 miscFee = 25e6;

    vm.prank(servicer);
    loans.chargeMiscFee(loanId, miscFee, timeNow, REF);

    usdc.mint(borrower, asUint(miscFee));
    vm.prank(borrower);
    loans.pay(loanId, miscFee, timeNow, REF);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, miscFee, 0, 0, 0, 0, timeNow, REF);

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId;
    vm.prank(servicer);
    loans.servicerWithdraw(loanIds, timeNow, REF);

    // Sanity: misc fee has been paid to the servicer.
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_MISC_FEE_PAID), miscFee);

    uint256 servicerBalanceBefore = usdc.balanceOf(servicer);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    uint128 entryIndex = loans.returnFunds(
      loanId,
      ACC_SERVICER_MISC_FEE_PAID,
      miscFee,
      timeNow,
      ENTRY_SERVICER_FUND_RETURN,
      REF
    );

    assertGt(entryIndex, 0);
    assertEq(loans.entryCount(loanId), entryCountBefore + 1);

    Entry memory entry = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(entry.from, ACC_SERVICER_MISC_FEE_PAID);
    assertEq(entry.to, ACC_CASH);
    assertEq(entry.amount, miscFee);
    assertEq(entry.entryType, ENTRY_SERVICER_FUND_RETURN);
    assertEq(entry.ref, REF);

    // ACC_SERVICER_MISC_FEE_PAID drained back to zero.
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_MISC_FEE_PAID), 0);

    // Tokens pulled from servicer into the contract.
    assertEq(usdc.balanceOf(servicer), servicerBalanceBefore - asUint(miscFee));
    assertEq(_loansContractBalance(), contractBalanceBefore + asUint(miscFee));
  }

  function test_ReturnFunds_Succeeds_WhenStatusFullyPaid() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.FullyPaid, 0, 0, timeNow);

    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    uint128 entryIndex = loans.returnFunds(
      loanId,
      ACC_SERVICER_FEE_PAID,
      DEFAULT_SERVICER_FEE,
      timeNow,
      ENTRY_SERVICER_FUND_RETURN,
      REF
    );
    assertGt(entryIndex, 0);
  }

  function test_ReturnFunds_Succeeds_WhenStatusChargedOff() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.ChargedOff, 0, 0, timeNow);

    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(servicer);
    uint128 entryIndex = loans.returnFunds(
      loanId,
      ACC_SERVICER_FEE_PAID,
      DEFAULT_SERVICER_FEE,
      timeNow,
      ENTRY_SERVICER_FUND_RETURN,
      REF
    );
    assertGt(entryIndex, 0);
  }

  function test_ReturnFunds_Reverts_WhenStatusCreated() public {
    uint64 createdLoanId = _createTestLoan(DEFAULT_PRINCIPAL_AMOUNT);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.returnFunds(createdLoanId, ACC_SERVICER_ADJUSTMENT, 1e6, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  function test_ReturnFunds_Reverts_WhenStatusFullyFunded() public {
    uint64 fullyFundedLoanId = _createFullyFundedLoan(DEFAULT_PRINCIPAL_AMOUNT);

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.returnFunds(fullyFundedLoanId, ACC_SERVICER_ADJUSTMENT, 1e6, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  function test_ReturnFunds_RevertsOnCancelledLoan() public {
    uint64 cancelledLoanId = _createCancelledLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.returnFunds(cancelledLoanId, ACC_SERVICER_ADJUSTMENT, 1e6, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  function test_ReturnFunds_RevertsOnClosedLoan() public {
    uint64 closedLoanId = _createClosedLoan();

    vm.prank(servicer);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.returnFunds(closedLoanId, ACC_SERVICER_ADJUSTMENT, 1e6, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }

  function test_ReturnFunds_RevertsOnNonexistentLoan() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.returnFunds(999, ACC_SERVICER_ADJUSTMENT, 1e6, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
  }
}
