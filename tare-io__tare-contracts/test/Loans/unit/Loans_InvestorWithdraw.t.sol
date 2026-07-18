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

contract Loans_InvestorWithdrawTest is LoansTestBase {
  bytes32 constant REF = bytes32("test_ref");

  function setUp() public override {
    super.setUp();
  }

  function test_investorWithdraw_singleLoan() public {
    _createLoansWithInvestorCashflow(1);

    uint256 investorBalanceBefore = usdc.balanceOf(investor);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(investor);
    InvestorWithdrawalResult[] memory results = loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);

    assertEq(results.length, 1);
    assertEq(results[0].loanId, loanId);
    assertEq(results[0].principal, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(results[0].interest, DEFAULT_INVESTOR_INTEREST);

    assertEq(loans.entryCount(loanId), entryCountBefore + 2);

    uint256 totalWithdrawn = asUint(DEFAULT_INVESTOR_INTEREST + DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(usdc.balanceOf(investor), investorBalanceBefore + totalWithdrawn);
    assertEq(_loansContractBalance(), contractBalanceBefore - totalWithdrawn);
  }

  function test_investorWithdraw_multipleLoans() public {
    _createLoansWithInvestorCashflow(3);

    uint256 investorBalanceBefore = usdc.balanceOf(investor);
    uint256 contractBalanceBefore = _loansContractBalance();

    uint64[] memory entryCountsBefore = new uint64[](3);
    for (uint256 i = 0; i < 3; i++) {
      entryCountsBefore[i] = loans.entryCount(testLoanIds[i]);
    }

    vm.prank(investor);
    InvestorWithdrawalResult[] memory results = loans.investorWithdraw(_getTestLoanIdArray(3), timeNow, REF);

    assertEq(results.length, 3);
    for (uint256 i = 0; i < 3; i++) {
      assertEq(results[i].loanId, testLoanIds[i]);
      assertEq(results[i].principal, DEFAULT_PRINCIPAL_REPAYMENT);
      assertEq(results[i].interest, DEFAULT_INVESTOR_INTEREST);
      assertEq(loans.entryCount(testLoanIds[i]), entryCountsBefore[i] + 2);
    }

    Entry memory e1 = loans.getLoanEntry(testLoanIds[0], entryCountsBefore[0] + 1);
    assertEq(uint8(e1.from), ACC_CASH);
    assertEq(uint8(e1.to), ACC_INVESTOR_INTEREST_PAID);
    assertEq(e1.amount, DEFAULT_INVESTOR_INTEREST);
    assertEq(e1.entryType, ENTRY_INVESTOR_INTEREST_WITHDRAWAL);

    Entry memory e2 = loans.getLoanEntry(testLoanIds[0], entryCountsBefore[0] + 2);
    assertEq(uint8(e2.from), ACC_CASH);
    assertEq(uint8(e2.to), ACC_INVESTOR_PRINCIPAL_REPAID);
    assertEq(e2.amount, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(e2.entryType, ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL);

    uint256 totalWithdrawn = asUint((DEFAULT_INVESTOR_INTEREST + DEFAULT_PRINCIPAL_REPAYMENT) * 3);
    assertEq(usdc.balanceOf(investor), investorBalanceBefore + totalWithdrawn);
    assertEq(_loansContractBalance(), contractBalanceBefore - totalWithdrawn);
  }

  function test_investorWithdraw_loanWithZeroPayable() public {
    _createLoansWithInvestorCashflow(2);

    vm.prank(investor);
    loans.investorWithdraw(_getTestLoanIdArray(2), timeNow, REF);

    uint256 investorBalanceBefore = usdc.balanceOf(investor);
    uint64 entryCountBefore = loans.entryCount(testLoanIds[0]);

    vm.prank(investor);
    InvestorWithdrawalResult[] memory results = loans.investorWithdraw(_getTestLoanIdArray(2), timeNow, REF);

    assertEq(results.length, 2);
    assertEq(results[0].principal, 0);
    assertEq(results[0].interest, 0);
    assertEq(results[1].principal, 0);
    assertEq(results[1].interest, 0);

    assertEq(loans.entryCount(testLoanIds[0]), entryCountBefore);
    assertEq(usdc.balanceOf(investor), investorBalanceBefore);
  }

  function test_investorWithdraw_mixedPayableAmounts() public {
    _createLoansWithInvestorCashflow(2);

    uint64[] memory firstLoan = new uint64[](1);
    firstLoan[0] = testLoanIds[0];

    vm.prank(investor);
    loans.investorWithdraw(firstLoan, timeNow, REF);

    uint256 investorBalanceBefore = usdc.balanceOf(investor);

    vm.prank(investor);
    InvestorWithdrawalResult[] memory results = loans.investorWithdraw(_getTestLoanIdArray(2), timeNow, REF);

    assertEq(results[0].principal, 0);
    assertEq(results[0].interest, 0);
    assertEq(results[1].principal, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(results[1].interest, DEFAULT_INVESTOR_INTEREST);

    assertEq(
      usdc.balanceOf(investor),
      investorBalanceBefore + asUint(DEFAULT_INVESTOR_INTEREST + DEFAULT_PRINCIPAL_REPAYMENT)
    );
  }

  function test_investorWithdraw_adminCanWithdraw() public {
    _createLoansWithInvestorCashflow(1);

    uint256 investorBalanceBefore = usdc.balanceOf(investor);

    vm.prank(admin);
    InvestorWithdrawalResult[] memory results = loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);

    assertEq(results[0].principal, DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(results[0].interest, DEFAULT_INVESTOR_INTEREST);

    uint256 totalWithdrawn = asUint(DEFAULT_INVESTOR_INTEREST + DEFAULT_PRINCIPAL_REPAYMENT);
    assertEq(usdc.balanceOf(investor), investorBalanceBefore + totalWithdrawn);
  }

  function test_investorWithdraw_revertsOnNonexistentLoan() public {
    uint64[] memory ids = new uint64[](1);
    ids[0] = 999;

    vm.prank(investor);
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.investorWithdraw(ids, timeNow, REF);
  }

  function test_investorWithdraw_revertsOnLoanIdZero() public {
    uint64[] memory ids = new uint64[](1);
    ids[0] = 0;

    vm.prank(investor);
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.investorWithdraw(ids, timeNow, REF);
  }

  function test_investorWithdraw_revertsOnUnauthorized() public {
    _createLoansWithInvestorCashflow(1);

    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);
  }

  function test_investorWithdraw_revertsOnDifferentInvestors() public {
    _createLoansWithInvestorCashflow(1);

    address investor2 = makeAddr("investor2");
    _registerAddressesForLoan(loans, originator, borrower, investor2, servicer);

    usdc.mint(investor2, asUint(100_000_000e6));
    vm.prank(investor2);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(originator);
    uint64 differentInvestorLoan = loans.create(
      borrower,
      investor2,
      servicer,
      originator,
      DEFAULT_TEST_PRINCIPAL,
      timeNow
    );

    vm.prank(investor2);
    loans.fund(differentInvestorLoan, DEFAULT_TEST_PRINCIPAL, timeNow, bytes32("fund"));

    vm.prank(originator);
    loans.disburse(
      differentInvestorLoan,
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

    uint64[] memory mixedIds = new uint64[](2);
    mixedIds[0] = testLoanIds[0];
    mixedIds[1] = differentInvestorLoan;

    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(mixedIds, timeNow, REF);
  }

  function test_investorWithdraw_revertsWhenLoanIsLocked() public {
    _createLoansWithInvestorCashflow(1);

    address unlocker = makeAddr("unlocker");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(testLoanIds[0]));

    // Investor cannot withdraw a locked loan (only the unlocker can)
    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);

    // Admin cannot withdraw a locked loan (only the unlocker can)
    vm.prank(admin);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(1), timeNow, REF);
  }

  function test_investorWithdraw_revertsWhenInvestorCallIncludesLockedLoan() public {
    _createLoansWithInvestorCashflow(2);

    address attacker = makeAddr("attacker");

    vm.prank(investor);
    loansNFT.lock(attacker, uint256(testLoanIds[1]));

    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(2), timeNow, REF);
  }

  function test_investorWithdraw_revertsWhenUnlockerCallIncludesUnlockedLoan() public {
    _createLoansWithInvestorCashflow(2);

    address unlocker = makeAddr("unlocker");

    vm.prank(investor);
    loansNFT.lock(unlocker, uint256(testLoanIds[0]));

    vm.prank(unlocker);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.investorWithdraw(_getTestLoanIdArray(2), timeNow, REF);
  }
}
