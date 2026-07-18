// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, LedgerEntryInput} from "contracts/interfaces/ILoans.sol";
import {ENTRY_INTEREST_REVERSAL} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_BORROWER_INTEREST_RECEIVABLE,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE
} from "contracts/interfaces/Accounts.sol";

contract Loans_CreateLedgerEntriesTest is LoansTestBase {
  bytes32 constant REF = bytes32("test_ref");

  function setUp() public override {
    super.setUp();
    loanId = _createLoanWithInvestorCashflow(DEFAULT_PRINCIPAL_AMOUNT, REF);
  }

  function test_BatchReversal() public accountingEquationHolds {
    int128 reversalAmount = 50e6;
    uint64 entryCountBefore = loans.entryCount(loanId);

    int128 interestReceivableBefore = loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_RECEIVABLE);
    int128 unallocatedInterestBefore = loans.getLoanAccountBalance(loanId, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE);
    int128 investorInterestPayableBefore = loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE);

    LedgerEntryInput[] memory ledgerEntries = new LedgerEntryInput[](2);
    ledgerEntries[0] = LedgerEntryInput({
      from: ACC_BORROWER_INTEREST_RECEIVABLE,
      to: ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      amount: reversalAmount,
      entryType: ENTRY_INTEREST_REVERSAL,
      ref: REF
    });
    ledgerEntries[1] = LedgerEntryInput({
      from: ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      to: ACC_INVESTOR_INTEREST_PAYABLE,
      amount: reversalAmount,
      entryType: ENTRY_INTEREST_REVERSAL,
      ref: REF
    });

    vm.prank(servicer);
    uint128[] memory indices = loans.createLedgerEntries(loanId, timeNow, ledgerEntries);

    assertEq(indices.length, 2);
    assertEq(loans.entryCount(loanId), entryCountBefore + 2);

    Entry memory e0 = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(e0.from, ACC_BORROWER_INTEREST_RECEIVABLE);
    assertEq(e0.to, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE);
    assertEq(e0.amount, reversalAmount);
    assertEq(e0.entryType, ENTRY_INTEREST_REVERSAL);

    Entry memory e1 = loans.getLoanEntry(loanId, entryCountBefore + 2);
    assertEq(e1.from, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE);
    assertEq(e1.to, ACC_INVESTOR_INTEREST_PAYABLE);
    assertEq(e1.amount, reversalAmount);
    assertEq(e1.entryType, ENTRY_INTEREST_REVERSAL);

    assertEq(
      loans.getLoanAccountBalance(loanId, ACC_BORROWER_INTEREST_RECEIVABLE),
      interestReceivableBefore - reversalAmount
    );
    assertEq(loans.getLoanAccountBalance(loanId, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE), unallocatedInterestBefore);
    assertEq(
      loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE),
      investorInterestPayableBefore + reversalAmount
    );
  }
}
