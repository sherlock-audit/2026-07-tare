// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, Roles, ILoans, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {ENTRY_BORROWER_PAYMENT} from "contracts/interfaces/LedgerEntries.sol";
import {ACC_BORROWER_PAYMENT_CLEARING, ACC_CASH} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_PayTest is LoansTestBase {
  int128 constant PRINCIPAL = 10_000e6;
  int128 constant PAYMENT_AMOUNT = 600e6;
  bytes32 constant REF = bytes32("test_ref");

  function setUp() public override {
    super.setUp();
    loanId = _createActiveLoan(PRINCIPAL);

    // Mint USDC to borrower and approve for payments
    usdc.mint(borrower, asUint(PAYMENT_AMOUNT));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);
  }

  function test_Pay() public accountingEquationHolds {
    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(borrower);
    uint128 entryIndex = loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);

    // Verify entry count and index format
    assertEq(loans.entryCount(loanId), entryCountBefore + 1);
    assertEq(entryIndex, (uint128(loanId) << 64) | uint128(entryCountBefore + 1));

    // Verify entry details
    Entry memory entry = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(entry.amount, PAYMENT_AMOUNT);
    assertEq(uint8(entry.from), ACC_BORROWER_PAYMENT_CLEARING);
    assertEq(uint8(entry.to), ACC_CASH);
    assertEq(entry.entryType, ENTRY_BORROWER_PAYMENT);
    assertEq(entry.ref, REF);

    // Verify account balances (Cash was 0 after full disburse)
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING), -PAYMENT_AMOUNT);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), PAYMENT_AMOUNT);

    // Verify token transfers
    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore - asUint(PAYMENT_AMOUNT));
    assertEq(_loansContractBalance(), contractBalanceBefore + asUint(PAYMENT_AMOUNT));
  }

  function test_Pay_PullsFromUpdatedBorrower() public accountingEquationHolds {
    // Set up a new borrower
    address newBorrower = makeAddr("newBorrower");

    // Register in servicer's address book (required by updateBorrower)
    vm.prank(servicer);
    loans.registerAddress(Roles.Borrower, newBorrower);

    // Update borrower on the loan
    vm.prank(servicer);
    loans.updateBorrower(loanId, newBorrower);

    // Fund the new borrower and approve
    usdc.mint(newBorrower, asUint(PAYMENT_AMOUNT));
    vm.prank(newBorrower);
    usdc.approve(address(loans), type(uint256).max);

    uint256 newBorrowerBalanceBefore = usdc.balanceOf(newBorrower);
    uint256 oldBorrowerBalanceBefore = usdc.balanceOf(borrower);

    // Pay — should pull from newBorrower, not old borrower
    vm.prank(newBorrower);
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);

    // New borrower's balance decreased
    assertEq(usdc.balanceOf(newBorrower), newBorrowerBalanceBefore - asUint(PAYMENT_AMOUNT));
    // Old borrower's balance unchanged
    assertEq(usdc.balanceOf(borrower), oldBorrowerBalanceBefore);
  }

  function test_Pay_RevertsWithNegativeAmount() public {
    vm.prank(borrower);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.pay(loanId, -1, timeNow, REF);
  }

  function test_Pay_RevertsWhenBorrowerHasNotApproved() public {
    vm.prank(borrower);
    usdc.approve(address(loans), 0);

    vm.prank(borrower);
    vm.expectRevert();
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_RevertsWhenCancelled() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Cancelled, 0, 0, timeNow);

    vm.prank(borrower);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_RevertsWhenClosed() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.Closed, 0, 0, timeNow);

    vm.prank(borrower);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_Reverts_WhenStatusCreated() public {
    uint64 newLoanId = _createTestLoan(PRINCIPAL);
    vm.prank(borrower);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.pay(newLoanId, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_Reverts_WhenStatusFullyFunded() public {
    uint64 newLoanId = _createFullyFundedLoan(PRINCIPAL);
    vm.prank(borrower);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.pay(newLoanId, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_Reverts_WhenStatusFullyPaid() public {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.FullyPaid, 0, 0, timeNow);

    vm.prank(borrower);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_Reverts_WhenLoanDoesNotExist() public {
    vm.prank(admin);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.pay(999, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_SucceedsWhenStatusChargedOff() public accountingEquationHolds {
    vm.prank(servicer);
    loans.updateLoanData(loanId, LoanStatus.ChargedOff, 0, 0, timeNow);

    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(borrower);
    uint128 entryIndex = loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);

    // Entry recorded
    assertEq(loans.entryCount(loanId), entryCountBefore + 1);
    assertEq(entryIndex, (uint128(loanId) << 64) | uint128(entryCountBefore + 1));

    Entry memory entry = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(entry.amount, PAYMENT_AMOUNT);
    assertEq(uint8(entry.from), ACC_BORROWER_PAYMENT_CLEARING);
    assertEq(uint8(entry.to), ACC_CASH);
    assertEq(entry.entryType, ENTRY_BORROWER_PAYMENT);
    assertEq(entry.ref, REF);

    // Tokens pulled from borrower into the contract
    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore - asUint(PAYMENT_AMOUNT));
    assertEq(_loansContractBalance(), contractBalanceBefore + asUint(PAYMENT_AMOUNT));

    // Status preserved
    (LoanStatus status, , , , ) = loans.data(loanId);
    assertEq(uint8(status), uint8(LoanStatus.ChargedOff));
  }

  function test_Pay_RevertsWhenCallerNotBorrowerOrAdmin() public {
    vm.prank(servicer);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);

    address randomUser = makeAddr("randomUser");
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);
  }

  function test_Pay_SucceedsWhenCalledByAdmin() public accountingEquationHolds {
    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(admin);
    loans.pay(loanId, PAYMENT_AMOUNT, timeNow, REF);

    // Entry recorded, tokens still pulled from borrowers[loanId]
    assertEq(loans.entryCount(loanId), entryCountBefore + 1);
    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore - asUint(PAYMENT_AMOUNT));
    assertEq(_loansContractBalance(), contractBalanceBefore + asUint(PAYMENT_AMOUNT));
  }
}
