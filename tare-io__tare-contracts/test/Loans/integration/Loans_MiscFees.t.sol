// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry} from "contracts/interfaces/ILoans.sol";
import {
  ENTRY_MISC_FEE_CHARGE,
  ENTRY_MISC_FEE_DEBT_CLEARANCE,
  ENTRY_MISC_FEE_WITHDRAWAL,
  ENTRY_SERVICER_FEE_WITHDRAWAL
} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_BORROWER_MISC_FEE_PAID,
  ACC_BORROWER_MISC_FEE_RECEIVABLE,
  ACC_BORROWER_PAYMENT_CLEARING,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_CASH,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_SERVICER_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAYABLE
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_MiscFeesTest is LoansTestBase {
  int128 constant PRINCIPAL = 10_000e6;
  int128 constant ACCRUAL_AMOUNT = 100e6;
  int128 constant MISC_FEE = 25e6;
  bytes32 constant REF = bytes32("misc_fee_test");

  /// @notice Instead of $600, Borrower only pays $80 — misc fees get priority, then servicer fee,
  ///         then partial interest. No principal repayment.
  ///         Waterfall: $25 misc + $10 svc fee + $45 interest + $0 principal = $80
  function test_miscFeeLifecycle_partialPayment() public accountingEquationHolds {
    loanId = _createActiveLoan(PRINCIPAL);

    int128 servicerFee = 10e6;
    int128 partialInterest = 45e6;
    int128 paymentAmount = 80e6;

    // ═══════════════ Charge misc fee ═══════════════
    vm.prank(servicer);
    loans.chargeMiscFee(loanId, MISC_FEE, timeNow, REF);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_SERVICER_MISC_FEE_PAYABLE), -MISC_FEE);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_MISC_FEE_RECEIVABLE), MISC_FEE);

    Entry memory chargeEntry = loans.getLoanEntry(loanId, loans.entryCount(loanId));
    assertEq(uint8(chargeEntry.from), ACC_SERVICER_MISC_FEE_PAYABLE);
    assertEq(uint8(chargeEntry.to), ACC_BORROWER_MISC_FEE_RECEIVABLE);
    assertEq(chargeEntry.amount, MISC_FEE);
    assertEq(chargeEntry.entryType, ENTRY_MISC_FEE_CHARGE);

    // ═══════════════ Accrue regular interest ═══════════════
    vm.prank(servicer);
    loans.accrue(loanId, ACCRUAL_AMOUNT, timeNow, REF);

    // ═══════════════ Borrower only pays $80 ═══════════════
    usdc.mint(borrower, asUint(paymentAmount));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(borrower);
    loans.pay(loanId, paymentAmount, timeNow, REF);

    // ═══════════════ Apply waterfall (misc fees first, partial interest, no principal) ═══════════════
    uint64 entryCountBefore = loans.entryCount(loanId);

    vm.prank(servicer);
    loans.applyWaterfall(loanId, MISC_FEE, servicerFee, partialInterest, 0, 0, timeNow, REF);

    // 4 entries: misc fee clearance, svc alloc, interest alloc, interest clearance (no principal)
    assertEq(loans.entryCount(loanId), entryCountBefore + 4);

    Entry memory miscClearance = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(uint8(miscClearance.from), ACC_BORROWER_MISC_FEE_PAID);
    assertEq(uint8(miscClearance.to), ACC_BORROWER_PAYMENT_CLEARING);
    assertEq(miscClearance.amount, MISC_FEE);
    assertEq(miscClearance.entryType, ENTRY_MISC_FEE_DEBT_CLEARANCE);

    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_MISC_FEE_PAID), -MISC_FEE);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PAYMENT_CLEARING), 0);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_INVESTOR_INTEREST_PAYABLE), -partialInterest);
    assertEq(loans.getLoanAccountBalance(loanId, ACC_BORROWER_PRINCIPAL_REPAID), 0);

    // ═══════════════ Servicer withdraws both fees ═══════════════
    uint256 servicerBalanceBefore = usdc.balanceOf(servicer);
    uint256 contractBalanceBefore = _loansContractBalance();
    entryCountBefore = loans.entryCount(loanId);

    uint64[] memory svcLoanIds = new uint64[](1);
    svcLoanIds[0] = loanId;
    vm.prank(servicer);
    loans.servicerWithdraw(svcLoanIds, timeNow, REF);

    assertEq(loans.entryCount(loanId), entryCountBefore + 2);

    Entry memory svcEntry = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(uint8(svcEntry.from), ACC_CASH);
    assertEq(uint8(svcEntry.to), ACC_SERVICER_FEE_PAID);
    assertEq(svcEntry.amount, servicerFee);
    assertEq(svcEntry.entryType, ENTRY_SERVICER_FEE_WITHDRAWAL);

    Entry memory miscEntry = loans.getLoanEntry(loanId, entryCountBefore + 2);
    assertEq(uint8(miscEntry.from), ACC_CASH);
    assertEq(uint8(miscEntry.to), ACC_SERVICER_MISC_FEE_PAID);
    assertEq(miscEntry.amount, MISC_FEE);
    assertEq(miscEntry.entryType, ENTRY_MISC_FEE_WITHDRAWAL);

    int128 totalServicerWithdrawal = servicerFee + MISC_FEE;
    assertEq(usdc.balanceOf(servicer), servicerBalanceBefore + asUint(totalServicerWithdrawal));
    assertEq(_loansContractBalance(), contractBalanceBefore - asUint(totalServicerWithdrawal));

    // Remaining cash = $45 (partial interest), available for investor
    assertEq(loans.getLoanAccountBalance(loanId, ACC_CASH), partialInterest);
  }
}
