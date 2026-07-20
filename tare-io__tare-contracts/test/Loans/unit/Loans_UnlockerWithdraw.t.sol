// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, InvestorWithdrawalResult, ILoans} from "contracts/interfaces/ILoans.sol";
import {
  ENTRY_INVESTOR_INTEREST_WITHDRAWAL,
  ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL
} from "contracts/interfaces/LedgerEntries.sol";
import {ACC_CASH, ACC_INVESTOR_INTEREST_PAID, ACC_INVESTOR_PRINCIPAL_REPAID} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_UnlockerWithdrawTest is LoansTestBase {
  bytes32 constant REF = bytes32("test_ref");
  address unlocker = makeAddr("unlocker");

  function setUp() public override {
    super.setUp();
  }

  function _lockAllTestLoans() internal {
    for (uint256 i = 0; i < testLoanIds.length; i++) {
      vm.prank(investor);
      loansNFT.lock(unlocker, uint256(testLoanIds[i]));
    }
  }

  function test_unlockerWithdraw_sendsToUnlocker() public {
    _createLoansWithInvestorCashflow(1);
    _lockAllTestLoans();

    uint256 unlockerBalanceBefore = usdc.balanceOf(unlocker);
    uint256 investorBalanceBefore = usdc.balanceOf(investor);

    vm.prank(unlocker);
    InvestorWithdrawalResult[] memory results = loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);

    assertEq(results.length, 1);
    assertEq(results[0].loanId, testLoanIds[0]);
    assertEq(results[0].principal, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(results[0].interest, DEFAULT_INVESTOR_INTEREST);

    uint256 totalWithdrawn = asUint(DEFAULT_INVESTOR_INTEREST + DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(usdc.balanceOf(unlocker), unlockerBalanceBefore + totalWithdrawn);
    assertEq(usdc.balanceOf(investor), investorBalanceBefore);
  }

  function test_unlockerWithdraw_multipleLoans() public {
    _createLoansWithInvestorCashflow(3);
    _lockAllTestLoans();

    uint256 unlockerBalanceBefore = usdc.balanceOf(unlocker);

    vm.prank(unlocker);
    InvestorWithdrawalResult[] memory results = loans.investorWithdraw(_getTestLoanIdArray(3), timeNow, REF);

    assertEq(results.length, 3);
    for (uint256 i = 0; i < 3; i++) {
      assertEq(results[i].loanId, testLoanIds[i]);
      assertEq(results[i].principal, DEFAULT_PRINCIPAL_REPAYMENT);
      assertEq(results[i].interest, DEFAULT_INVESTOR_INTEREST);
    }

    uint256 totalWithdrawn = asUint((DEFAULT_INVESTOR_INTEREST + DEFAULT_PRINCIPAL_REPAYMENT) * 3);
    assertEq(usdc.balanceOf(unlocker), unlockerBalanceBefore + totalWithdrawn);
  }

  function test_unlockerWithdraw_createsCorrectLedgerEntries() public {
    _createLoansWithInvestorCashflow(1);
    _lockAllTestLoans();

    uint64 entryCountBefore = loans.entryCount(testLoanIds[0]);

    vm.prank(unlocker);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);

    assertEq(loans.entryCount(testLoanIds[0]), entryCountBefore + 2);

    Entry memory e1 = loans.getLoanEntry(testLoanIds[0], entryCountBefore + 1);
    assertEq(uint8(e1.from), ACC_CASH);
    assertEq(uint8(e1.to), ACC_INVESTOR_INTEREST_PAID);
    assertEq(e1.amount, DEFAULT_INVESTOR_INTEREST);
    assertEq(e1.entryType, ENTRY_INVESTOR_INTEREST_WITHDRAWAL);

    Entry memory e2 = loans.getLoanEntry(testLoanIds[0], entryCountBefore + 2);
    assertEq(uint8(e2.from), ACC_CASH);
    assertEq(uint8(e2.to), ACC_INVESTOR_PRINCIPAL_REPAID);
    assertEq(e2.amount, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(e2.entryType, ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL);
  }

  function test_unlockerWithdraw_revertsWhenNotLocked() public {
    _createLoansWithInvestorCashflow(1);

    vm.prank(unlocker);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);
  }

  function test_unlockerWithdraw_revertsWhenCallerIsNotUnlocker() public {
    _createLoansWithInvestorCashflow(1);
    _lockAllTestLoans();

    // Investor cannot call investorWithdraw
    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);

    // Admin cannot call investorWithdraw
    vm.prank(admin);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);

    // Random user cannot call investorWithdraw
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);
  }

  function test_unlockerWithdraw_revertsWhenDifferentUnlockers() public {
    _createLoansWithInvestorCashflow(2);

    address unlocker2 = makeAddr("unlocker2");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(testLoanIds[0]));

    vm.prank(investor);
    loansNFT.lock(unlocker2, uint256(testLoanIds[1]));

    // unlocker calls with both loans — second loan is locked to unlocker2
    vm.prank(unlocker);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(2), timeNow, REF);
  }

  function test_unlockerWithdraw_revertsWhenDifferentInvestors() public {
    _createLoansWithInvestorCashflow(1);

    address investor2 = makeAddr("investor2");
    _registerAddressesForLoan(loans, originator, borrower, investor2, servicer);

    usdc.mint(investor2, asUint(100_000_000e6));
    vm.prank(investor2);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(originator);
    uint64 loanId2 = loans.create(borrower, investor2, servicer, originator, DEFAULT_TEST_PRINCIPAL, timeNow);

    vm.prank(investor2);
    loans.fund(loanId2, DEFAULT_TEST_PRINCIPAL, timeNow, bytes32("fund"));

    vm.prank(originator);
    loans.disburse(
      loanId2,
      DEFAULT_TEST_PRINCIPAL,
      0,
      timeNow,
      timeNow + 30 days,
      timeNow + 365 days,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      bytes32("disburse")
    );

    // Lock both loans to the same unlocker
    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(testLoanIds[0]));
    vm.prank(investor2);
    loansNFT.lock(unlocker, uint256(loanId2));

    uint64[] memory mixedIds = new uint64[](2);
    mixedIds[0] = testLoanIds[0];
    mixedIds[1] = loanId2;

    vm.prank(unlocker);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(mixedIds, timeNow, REF);
  }

  function test_unlockerWithdraw_revertsOnNonexistentLoan() public {
    uint64[] memory ids = new uint64[](1);
    ids[0] = 999;

    vm.prank(unlocker);
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.investorWithdraw(ids, timeNow, REF);
  }
}
