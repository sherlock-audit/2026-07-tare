// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, LoanStatus, ILoans} from "contracts/interfaces/ILoans.sol";
import {ACC_BORROWER_PRINCIPAL_RECEIVABLE, ACC_UNFUNDED_COMMITMENT} from "contracts/interfaces/Accounts.sol";
import {ENTRY_LOAN_COMMITMENT} from "contracts/interfaces/LedgerEntries.sol";
import {ILoansAuth} from "contracts/misc/interfaces/ILoansAuth.sol";

contract LoanCreationTest is LoansTestBase {
  function test_CreateLoan() public {
    uint64 loanId = _createTestLoan();
    assertEq(loanId, 1);
    (LoanStatus status, , , , ) = loans.data(loanId);
    assertEq(uint8(status), uint8(LoanStatus.Created));
  }

  function test_CreateLoan_CreatesInitialCommitmentEntry() public {
    int128 principalAmount = 50000;
    uint64 loanId = _createTestLoan(principalAmount);

    // Verify entry was created
    assertEq(loans.entryCount(loanId), 1);

    // Verify entry details
    // Credit account (liability) → from, Debit account (asset) → to
    Entry memory entry = loans.getLoanEntry(loanId, 1);
    assertEq(entry.amount, principalAmount);
    assertEq(uint8(entry.from), uint8(ACC_UNFUNDED_COMMITMENT));
    assertEq(uint8(entry.to), uint8(ACC_BORROWER_PRINCIPAL_RECEIVABLE));
    assertEq(entry.entryType, ENTRY_LOAN_COMMITMENT);
    assertEq(entry.ref, bytes32("initial_loan_commitment"));
    assertEq(entry.timestamp, timeNow);
  }

  function test_CreateLoan_SetsCorrectAccountBalances() public {
    int128 principalAmount = 75000;
    uint64 loanId = _createTestLoan(principalAmount);

    // UnfundedCommitment (from account) goes negative
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNFUNDED_COMMITMENT), -principalAmount);
    // Normalized: UnfundedCommitment (liability) = Normally-negative account → flips sign
    assertEq(loans.getLoanAccountBalanceNormalized(loanId, ACC_UNFUNDED_COMMITMENT), principalAmount);

    // BorrowerPrincipalReceivable (to account) goes positive
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_RECEIVABLE), principalAmount);
    // Normalized: BorrowerPrincipalReceivable (asset) = Normally-positive account → no sign flip
    assertEq(loans.getLoanAccountBalanceNormalized(loanId, ACC_BORROWER_PRINCIPAL_RECEIVABLE), principalAmount);
  }

  function test_CreateLoan_AccountingEquationBalances() public {
    int128 principalAmount = 100000;
    uint64 loanId = _createTestLoan(principalAmount);

    // Total of all accounts should sum to zero
    int128 totalBalance = _getLoanTotalBalance(loanId);
    assertEq(totalBalance, 0, "Accounting equation should balance to zero");
  }

  function test_CreateLoan_EmitsEntryCreatedEvent() public {
    int128 principalAmount = 25000;

    // The entry index will be (loanId << 64) | 1, and loanId will be 1 (first loan)
    uint64 expectedLoanId = loans.loanCount() + 1;
    uint128 expectedEntryIndex = (uint128(expectedLoanId) << 64) | 1;

    vm.expectEmit(true, true, true, true);
    emit ILoans.EntryCreated(
      expectedEntryIndex,
      ACC_UNFUNDED_COMMITMENT,
      ACC_BORROWER_PRINCIPAL_RECEIVABLE,
      principalAmount,
      -principalAmount,
      principalAmount,
      ENTRY_LOAN_COMMITMENT,
      bytes32("initial_loan_commitment")
    );

    vm.prank(originator);
    loans.create(borrower, investor, servicer, originator, principalAmount, timeNow);
  }

  function test_CreateLoan_Reverts_WhenPrincipalAmountZero() public {
    vm.prank(originator);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.create(borrower, investor, servicer, originator, 0, timeNow);
  }

  function test_CreateLoan_Reverts_WhenPrincipalAmountNegative() public {
    vm.prank(originator);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.create(borrower, investor, servicer, originator, -1, timeNow);
  }

  function test_CreateLoan_RevertsWhenOriginatorNotApproved() public {
    address unapprovedOriginator = makeAddr("unapprovedOriginator");

    // Register addresses in the unapproved originator's book so we isolate the originator check
    _registerAddressesForLoan(loans, unapprovedOriginator, borrower, investor, servicer);

    // Admin tries to create a loan with an unapproved originator
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(ILoansAuth.UnregisteredAddress.selector, unapprovedOriginator));
    loans.create(borrower, investor, servicer, unapprovedOriginator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);
  }

  function test_CreateLoan_AdminCanCreateWithApprovedOriginator() public {
    // Admin creates a loan specifying the approved originator
    vm.prank(admin);
    uint64 id = loans.create(borrower, investor, servicer, originator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);
    (LoanStatus adminStatus, , , , ) = loans.data(id);
    assertEq(uint8(adminStatus), uint8(LoanStatus.Created));
  }

  function test_CreateLoan_OriginatorCannotImpersonateAnotherOriginator() public {
    // Approve a second originator and register the same counterparties in its book
    address otherOriginator = makeAddr("otherOriginator");
    vm.prank(guardian);
    loans.approveOriginator(otherOriginator);
    _registerAddressesForLoan(loans, otherOriginator, borrower, investor, servicer);

    // `originator` is approved but tries to create a loan attributed to `otherOriginator`
    vm.prank(originator);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.create(borrower, investor, servicer, otherOriginator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);

    // Symmetric: otherOriginator cannot create under `originator`'s identity either
    vm.prank(otherOriginator);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.create(borrower, investor, servicer, originator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);
  }

  function test_CreateLoan_OriginatorCanCreateTheirOwnLoan() public {
    // Originator creates their own loan (msg.sender == originator param)
    vm.prank(originator);
    uint64 id = loans.create(borrower, investor, servicer, originator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);
    (LoanStatus status, , , , ) = loans.data(id);
    assertEq(uint8(status), uint8(LoanStatus.Created));
  }

  function test_CreateLoan_GuardianCanCreateOnBehalfOfAnyApprovedOriginator() public {
    // Guardian also has admin override
    vm.prank(guardian);
    uint64 id = loans.create(borrower, investor, servicer, originator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);
    (LoanStatus status, , , , ) = loans.data(id);
    assertEq(uint8(status), uint8(LoanStatus.Created));
  }

  function test_CreateLoan_RevokedOriginatorCannotBeUsed() public {
    // Revoke the originator
    vm.prank(admin);
    loans.revokeOriginator(originator);

    // Originator can no longer call create (no longer registered as approved originator)
    vm.prank(originator);
    vm.expectRevert(abi.encodeWithSelector(ILoansAuth.UnregisteredAddress.selector, originator));
    loans.create(borrower, investor, servicer, originator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);

    // Admin also cannot use the revoked originator as the originator argument
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(ILoansAuth.UnregisteredAddress.selector, originator));
    loans.create(borrower, investor, servicer, originator, DEFAULT_PRINCIPAL_AMOUNT, timeNow);
  }
}
