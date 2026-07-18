// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, LoanStatus, ILoans, LedgerEntryInput} from "contracts/interfaces/ILoans.sol";
import {
  ACC_CASH,
  ACC_ORIGINATOR_FEE_PAYABLE,
  ACC_UNFUNDED_COMMITMENT,
  ACC_BORROWER_PRINCIPAL_RECEIVABLE
} from "contracts/interfaces/Accounts.sol";
import {ENTRY_ORIGINATOR_FEE_WITHHOLDING, ENTRY_DISBURSEMENT_TO_BORROWER} from "contracts/interfaces/LedgerEntries.sol";

contract Loans_DisburseTest is LoansTestBase {
  int128 constant COMMITMENT = 10_000e6;
  int128 constant ORIGINATION_FEE = 100e6;
  int128 constant NET_DISBURSED = COMMITMENT - ORIGINATION_FEE; // 9_900e6

  bytes32 constant DISBURSE_REF = bytes32("disburse_ref");
  bytes32 constant FUND_REF = bytes32("fund");
  uint48 constant DISBURSE_TIMESTAMP_OFFSET = 100;
  uint64 entryCountAfterSetUp;
  uint48 originationDate;
  uint48 nextDueDate;
  uint48 maturityDate;

  function setUp() public override {
    super.setUp();
    loanId = _createFullyFundedLoan(COMMITMENT);

    entryCountAfterSetUp = loans.entryCount(loanId);
    originationDate = timeNow;
    nextDueDate = timeNow + 30 days;
    maturityDate = timeNow + 365 days;
  }

  // ============ Full Flow Tests ============

  function test_disburse_fullAmount_noFees() public {
    vm.prank(originator);
    uint64 noFeeLoanId = loans.create(borrower, investor, servicer, originator, COMMITMENT, timeNow);

    // Fund the loan fully to reach FullyFunded status
    usdc.mint(investor, uint256(int256(COMMITMENT)));
    vm.prank(investor);
    loans.fund(noFeeLoanId, COMMITMENT, timeNow, FUND_REF);

    // Verify loan is now FullyFunded
    (LoanStatus noFeeStatus1, , , , ) = loans.data(noFeeLoanId);
    assertEq(uint8(noFeeStatus1), uint8(LoanStatus.FullyFunded));

    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    uint48 timestamp = timeNow + DISBURSE_TIMESTAMP_OFFSET;

    // Disburse full amount with zero fees
    vm.prank(originator);
    loans.disburse(
      noFeeLoanId,
      COMMITMENT,
      0,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timestamp,
      DISBURSE_REF
    );

    // Verify loan status is now Active
    (LoanStatus noFeeStatus2, , , , ) = loans.data(noFeeLoanId);
    assertEq(uint8(noFeeStatus2), uint8(LoanStatus.Active));

    // Verify only 1 disburse entry created (no fee entries when fees are 0)
    // Total entries: 1 commitment + 1 fund + 1 disburse = 3
    assertEq(loans.entryCount(noFeeLoanId), 3);

    // Entry 3: Full disbursement (Cash -> UnfundedCommitment)
    Entry memory entry3 = loans.getLoanEntry(noFeeLoanId, 3);
    assertEq(uint8(entry3.from), uint8(ACC_CASH));
    assertEq(uint8(entry3.to), uint8(ACC_UNFUNDED_COMMITMENT));
    assertEq(entry3.amount, COMMITMENT);
    assertEq(entry3.entryType, ENTRY_DISBURSEMENT_TO_BORROWER);

    // Verify borrower received full commitment
    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore + uint256(int256(COMMITMENT)));

    // Verify balances zeroed out
    assertEq(loans.getLoanAccountBalance(noFeeLoanId, ACC_CASH), 0);
    assertEq(loans.getLoanAccountBalance(noFeeLoanId, ACC_UNFUNDED_COMMITMENT), 0);
  }

  function test_disburse_fullFlow_withOriginationFee() public {
    uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);
    uint48 timestamp = timeNow + DISBURSE_TIMESTAMP_OFFSET;

    vm.prank(originator);
    loans.disburse(
      loanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timestamp,
      DISBURSE_REF
    );

    // Verify loan status changed to Active
    (LoanStatus disburseStatus, , , , ) = loans.data(loanId);
    assertEq(uint8(disburseStatus), uint8(LoanStatus.Active));

    // Verify 2 new entries created (total 4: 1 commitment + 1 fund + 2 disburse)
    assertEq(loans.entryCount(loanId), entryCountAfterSetUp + 2);

    // Entry 3: Origination fee (OriginatorFeePayable -> UnfundedCommitment)
    Entry memory entry3 = loans.getLoanEntry(loanId, entryCountAfterSetUp + 1);
    assertEq(uint8(entry3.from), uint8(ACC_ORIGINATOR_FEE_PAYABLE));
    assertEq(uint8(entry3.to), uint8(ACC_UNFUNDED_COMMITMENT));
    assertEq(entry3.amount, ORIGINATION_FEE);
    assertEq(entry3.entryType, ENTRY_ORIGINATOR_FEE_WITHHOLDING);

    // Entry 4: Disbursement to borrower (Cash -> UnfundedCommitment)
    Entry memory entry4 = loans.getLoanEntry(loanId, entryCountAfterSetUp + 2);
    assertEq(uint8(entry4.from), uint8(ACC_CASH));
    assertEq(uint8(entry4.to), uint8(ACC_UNFUNDED_COMMITMENT));
    assertEq(entry4.amount, NET_DISBURSED);
    assertEq(entry4.entryType, ENTRY_DISBURSEMENT_TO_BORROWER);

    // Verify account balances
    // Cash = COMMITMENT - NET_DISBURSED = 10000 - 9900 = 100 (origination fee held for later payout)
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), ORIGINATION_FEE);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNFUNDED_COMMITMENT), 0);
    // OriginatorFeePayable = -ORIGINATION_FEE = -100e6
    assertEq(loans.getLoanAccountBalance(loanId, ACC_ORIGINATOR_FEE_PAYABLE), -ORIGINATION_FEE);

    // Verify borrower received correct amount
    assertEq(usdc.balanceOf(borrower), borrowerBalanceBefore + uint256(int256(NET_DISBURSED)));
  }

  // ============ Revert Tests ============

  function test_disburse_revert_unauthorized() public {
    // Random user
    vm.prank(randomUser);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.disburse(
      loanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );

    // Borrower
    vm.prank(borrower);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.disburse(
      loanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );

    // Investor
    vm.prank(investor);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.disburse(
      loanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );

    // Servicer
    vm.prank(servicer);
    vm.expectRevert(ILoans.Unauthorized.selector);
    loans.disburse(
      loanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );
  }

  function test_disburse_revert_amountMismatch() public {
    // netDisbursedAmount + originationFee != commitment
    int128 wrongNetAmount = NET_DISBURSED - 100e6; // Too low

    vm.prank(originator);
    vm.expectRevert(ILoans.InvalidAmountDisbursed.selector);
    loans.disburse(
      loanId,
      wrongNetAmount,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );
  }

  function test_disburse_revert_notFullyFunded() public {
    // Create unfunded loan and do not fund it.
    vm.prank(originator);
    uint64 unfundedLoanId = loans.create(borrower, investor, servicer, originator, COMMITMENT, timeNow);

    // Verify loan is still Created (not FullyFunded).
    (LoanStatus unfundedStatus, , , , ) = loans.data(unfundedLoanId);
    assertEq(uint8(unfundedStatus), uint8(LoanStatus.Created));

    // Disburse should fail because loan is not FullyFunded.
    vm.prank(originator);
    vm.expectRevert(ILoans.InvalidStatus.selector);
    loans.disburse(
      unfundedLoanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );
  }

  // Defense-in-depth: a servicer poisoning ACC_UNFUNDED_COMMITMENT (flipping it positive,
  // so commitment = -balance is negative) must not allow disbursement.
  // The equality check `netDisbursedAmount + originationFee == commitment` rejects this
  // because the LHS is strictly positive and the RHS is negative.
  function test_Disburse_Reverts_WhenUnfundedCommitmentPositive() public {
    // Move some balance from BORROWER_PRINCIPAL_RECEIVABLE to UNFUNDED_COMMITMENT
    // to push UNFUNDED_COMMITMENT positive (commitment becomes negative).
    LedgerEntryInput[] memory entries = new LedgerEntryInput[](1);
    entries[0] = LedgerEntryInput({
      from: ACC_BORROWER_PRINCIPAL_RECEIVABLE,
      to: ACC_UNFUNDED_COMMITMENT,
      amount: COMMITMENT + 1,
      entryType: 0,
      ref: bytes32("poison")
    });

    vm.prank(servicer);
    loans.createLedgerEntries(loanId, timeNow, entries);

    // Sanity: ACC_UNFUNDED_COMMITMENT is now positive (commitment is negative)
    assertGt(loans.getLoanAccountBalance(loanId, ACC_UNFUNDED_COMMITMENT), 0);

    vm.prank(originator);
    vm.expectRevert(ILoans.InvalidAmountDisbursed.selector);
    loans.disburse(
      loanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );
  }

  // Regression: a servicer flipping status to FullyFunded via updateLoanData
  // on an unfunded loan must not enable disburse to drain cash and
  // fabricate an originator-fee liability.
  function test_disburse_revert_notFullyFunded_whenStatusSpoofedViaUpdateLoanData() public {
    vm.prank(originator);
    uint64 spoofedLoanId = loans.create(borrower, investor, servicer, originator, COMMITMENT, timeNow);

    // Servicer spoofs status to FullyFunded without any investor funding.
    vm.prank(servicer);
    loans.updateLoanData(spoofedLoanId, LoanStatus.FullyFunded, 0, 0, timeNow);

    (LoanStatus spoofedStatus, , , , ) = loans.data(spoofedLoanId);
    assertEq(uint8(spoofedStatus), uint8(LoanStatus.FullyFunded));

    // Disburse must revert: funded != commitment
    vm.prank(originator);
    vm.expectRevert(ILoans.NotFullyFunded.selector);
    loans.disburse(
      spoofedLoanId,
      NET_DISBURSED,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );
  }

  function test_disburse_revert_invalidAmount_whenNetDisbursedZero() public {
    vm.prank(originator);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.disburse(
      loanId,
      0,
      ORIGINATION_FEE,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );
  }

  function test_disburse_revert_invalidAmount_whenOriginationFeeNegative() public {
    vm.prank(originator);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.disburse(
      loanId,
      COMMITMENT,
      -1,
      originationDate,
      nextDueDate,
      maturityDate,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      DISBURSE_REF
    );
  }
}
