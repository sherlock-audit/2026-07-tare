// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, LoanStatus, LedgerEntryInput} from "contracts/interfaces/ILoans.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";
import {ENTRY_ADJUSTMENT} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_BORROWER_INTEREST_PAID,
  ACC_BORROWER_INTEREST_RECEIVABLE,
  ACC_BORROWER_PAYMENT_CLEARING,
  ACC_BORROWER_PRINCIPAL_RECEIVABLE,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_CASH,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_PAYABLE,
  ACC_INVESTOR_PRINCIPAL_REPAID,
  ACC_ORIGINATOR_FEE_PAID,
  ACC_ORIGINATOR_FEE_PAYABLE,
  ACC_SERVICER_FEE_PAID,
  ACC_SERVICER_FEE_PAYABLE,
  ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
  ACC_UNFUNDED_COMMITMENT
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract LoanLedgerTestsTest is LoansTestBase {
  function setUp() public override {
    super.setUp();
    loanId = _createTestLoan();
  }

  function test_CreateInternalEntry() public {
    bytes32 testRef = bytes32("test_reference");

    assertEq(loans.entryCount(loanId), 1); // Initial loan commitment entry

    LedgerEntryInput[] memory ledgerEntries = new LedgerEntryInput[](1);
    ledgerEntries[0] = LedgerEntryInput({
      from: ACC_SERVICER_FEE_PAYABLE,
      to: ACC_SERVICER_FEE_PAID,
      amount: 1000,
      entryType: ENTRY_ADJUSTMENT,
      ref: testRef
    });

    vm.prank(servicer);
    uint128[] memory entryIndices = loans.createLedgerEntries(loanId, timeNow, ledgerEntries);

    uint128 entryIndex = entryIndices[0];

    assertEq(loans.entryCount(loanId), 2);

    assertEq(entryIndex, (uint128(loanId) << 64) | 2);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -1000);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAID), 1000);

    Entry memory storedEntry = loans.getLoanEntry(loanId, 2);
    assertEq(storedEntry.amount, 1000);
    assertEq(uint8(storedEntry.from), uint8(ACC_SERVICER_FEE_PAYABLE));
    assertEq(uint8(storedEntry.to), uint8(ACC_SERVICER_FEE_PAID));
    assertEq(storedEntry.ref, testRef);
    assertEq(storedEntry.timestamp, timeNow);
  }

  /// @notice End-to-end lifecycle test following specs/ledger_e2e_example.md (Phase 1–3)
  /// Create → Fund → Disburse (with origination fee) → Pay originator →
  /// Accrue → Receive payment → Apply waterfall → Servicer withdraw → Investor withdraw
  function test_FullPaymentLifecycle() public {
    int128 principal = 10_000e6;
    int128 originationFee = 100e6;
    int128 netDisbursed = 9_900e6;
    int128 accrualAmount = 100e6;
    int128 paymentAmount = 600e6;
    int128 svcFee = 10e6;
    int128 intAmt = 90e6;
    int128 prinRepay = 500e6;
    bytes32 ref = bytes32("e2e");

    // ═══════════════ Phase 1: Origination ═══════════════

    // Entry #1: Loan commitment (UnfundedCommitment → BorrowerPrincipalReceivable)
    uint64 loanId = _createTestLoan(principal);
    assertEq(loans.entryCount(loanId), 1);
    assertEq(_getLoanTotalBalance(loanId), 0);

    // Entry #2: Fund (InvestorPrincipalPayable → Cash)
    vm.prank(investor);
    loans.fund(loanId, principal, timeNow, ref);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), principal);
    (LoanStatus fundedStatus, , , , ) = loans.data(loanId);
    assertEq(uint8(fundedStatus), uint8(LoanStatus.FullyFunded));
    assertEq(_getLoanTotalBalance(loanId), 0);

    // Entries #3-4: Disburse with origination fee
    vm.prank(originator);
    loans.disburse(
      loanId,
      netDisbursed,
      originationFee,
      timeNow,
      timeNow + 30 days,
      timeNow + 365 days,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      ref
    );
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), originationFee); // Fee held in Cash
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNFUNDED_COMMITMENT), 0);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_ORIGINATOR_FEE_PAYABLE), -originationFee);
    (LoanStatus activeStatus, , , , ) = loans.data(loanId);
    assertEq(uint8(activeStatus), uint8(LoanStatus.Active));
    assertEq(_getLoanTotalBalance(loanId), 0);

    // Entry #5: Pay originator
    uint64[] memory originatorLoanIds = new uint64[](1);
    originatorLoanIds[0] = loanId;
    vm.prank(originator);
    loans.originatorWithdraw(originatorLoanIds, timeNow, ref);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), 0);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_ORIGINATOR_FEE_PAID), originationFee);

    // Phase 1 balance sheet
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_RECEIVABLE), principal);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE), -principal);
    assertEq(loans.entryCount(loanId), 5);
    assertEq(_getLoanTotalBalance(loanId), 0);

    // ═══════════════ Phase 2: Accrual ($100) ═══════════════

    // Entry #6: Accrue borrower obligation
    vm.prank(servicer);
    loans.accrue(loanId, accrualAmount, timeNow, ref);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_RECEIVABLE), accrualAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE), -accrualAmount);
    assertEq(loans.entryCount(loanId), 6);
    assertEq(_getLoanTotalBalance(loanId), 0);

    // ═══════════════ Phase 3: First Payment ($600) ═══════════════

    // 3.a: Receive borrower payment
    usdc.mint(borrower, asUint(paymentAmount));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    // Entry #7: Receive payment (BorrowerPaymentClearing → Cash)
    vm.prank(borrower);
    loans.pay(loanId, paymentAmount, timeNow, ref);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), paymentAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING), -paymentAmount);
    assertEq(loans.entryCount(loanId), 7);
    assertEq(_getLoanTotalBalance(loanId), 0);

    // 3.b: Apply waterfall (entries #8-11)
    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, svcFee, intAmt, prinRepay, 0, timeNow, ref);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -svcFee);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -intAmt);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE), 0);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING), 0);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), -(svcFee + intAmt));
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), -prinRepay);
    assertEq(loans.entryCount(loanId), 11);
    assertEq(_getLoanTotalBalance(loanId), 0);

    // 3.c: Payouts
    // Entry #12: Servicer withdraws fees
    uint64[] memory svcLoanIds = new uint64[](1);
    svcLoanIds[0] = loanId;
    vm.prank(servicer);
    loans.servicerWithdraw(svcLoanIds, timeNow, ref);

    // Entries #13-14: Investor withdraws interest + principal
    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId;

    vm.prank(investor);
    loans.investorWithdraw(loanIds, timeNow, ref);

    // ═══════════════ Final Balance Sheet (Phase 3) ═══════════════
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), 0);
    // Net principal receivable: 10,000 - 500 = 9,500
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_RECEIVABLE), principal);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), -prinRepay);
    // Net interest receivable: 100 - 100 = 0
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_RECEIVABLE), accrualAmount);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_PAID), -(svcFee + intAmt));
    // Net investor principal: 10,000 - 500 = 9,500
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_PAYABLE), -principal);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_PRINCIPAL_REPAID), prinRepay);
    // Net investor interest: 90 - 90 = 0
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -intAmt);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAID), intAmt);
    // Net servicer fees: 10 - 10 = 0
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAYABLE), -svcFee);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_FEE_PAID), svcFee);
    // Net originator fees: 100 - 100 = 0
    assertEq(loans.getLoanAccountBalance(loanId, ACC_ORIGINATOR_FEE_PAYABLE), -originationFee);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_ORIGINATOR_FEE_PAID), originationFee);

    assertEq(loans.entryCount(loanId), 14);
    assertEq(_getLoanTotalBalance(loanId), 0);
  }

  // ========== getLoanEntries ==========

  function _seedExtraEntries(uint64 loanId_, uint64 count) private {
    LedgerEntryInput[] memory inputs = new LedgerEntryInput[](count);
    for (uint64 i = 0; i < count; ++i) {
      inputs[i] = LedgerEntryInput({
        from: ACC_SERVICER_FEE_PAYABLE,
        to: ACC_SERVICER_FEE_PAID,
        amount: int128(uint128(1000 + i)),
        entryType: ENTRY_ADJUSTMENT,
        ref: bytes32(uint256(i + 1))
      });
    }
    vm.prank(servicer);
    loans.createLedgerEntries(loanId_, timeNow, inputs);
  }

  function _assertEntriesEqual(Entry memory actual, Entry memory expected) private pure {
    assertEq(actual.amount, expected.amount);
    assertEq(uint8(actual.from), uint8(expected.from));
    assertEq(uint8(actual.to), uint8(expected.to));
    assertEq(actual.ref, expected.ref);
    assertEq(actual.timestamp, expected.timestamp);
    assertEq(uint16(actual.entryType), uint16(expected.entryType));
  }

  function test_GetLoanEntries_SingleEntry() public view {
    // setUp already created entry #1 (loan commitment)
    Entry[] memory range = loans.getLoanEntries(loanId, 1, 1);
    assertEq(range.length, 1);
    _assertEntriesEqual(range[0], loans.getLoanEntry(loanId, 1));
  }

  function test_GetLoanEntries_FullRange() public {
    _seedExtraEntries(loanId, 4); // appends entries #2..#5

    uint64 count = loans.entryCount(loanId);
    assertEq(count, 5);

    Entry[] memory range = loans.getLoanEntries(loanId, 1, count);
    assertEq(range.length, count);
    for (uint64 i = 1; i <= count; ++i) {
      _assertEntriesEqual(range[i - 1], loans.getLoanEntry(loanId, i));
    }
  }

  function test_GetLoanEntries_Subrange() public {
    _seedExtraEntries(loanId, 4); // entry count == 5

    Entry[] memory range = loans.getLoanEntries(loanId, 2, 4);
    assertEq(range.length, 3);
    for (uint64 i = 2; i <= 4; ++i) {
      _assertEntriesEqual(range[i - 2], loans.getLoanEntry(loanId, i));
    }
  }

  function test_GetLoanEntries_RevertsWhenStartIndexZero() public {
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.getLoanEntries(loanId, 0, 1);
  }

  function test_GetLoanEntries_RevertsWhenStartIndexAboveCount() public {
    uint64 count = loans.entryCount(loanId);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.getLoanEntries(loanId, count + 1, count + 1);
  }

  function test_GetLoanEntries_RevertsWhenEndIndexBelowStartIndex() public {
    _seedExtraEntries(loanId, 2); // entry count == 3
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.getLoanEntries(loanId, 2, 1);
  }

  function test_GetLoanEntries_RevertsWhenEndIndexAboveCount() public {
    uint64 count = loans.entryCount(loanId);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    loans.getLoanEntries(loanId, 1, count + 1);
  }

  function test_GetLoanEntries_RevertsForNonexistentLoan() public {
    uint64 nonexistent = loans.loanCount() + 1; // next-to-allocate id is unused
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.getLoanEntries(nonexistent, 1, 1);
  }

  function test_GetLoanEntry_RevertsForLoanIdZero() public {
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.getLoanEntry(0, 1);
  }

  function test_GetLoanEntries_RevertsForLoanIdZero() public {
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.getLoanEntries(0, 1, 1);
  }
}
