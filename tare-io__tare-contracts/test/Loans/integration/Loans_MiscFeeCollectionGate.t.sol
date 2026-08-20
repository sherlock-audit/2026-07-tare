// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {ILoans, LedgerEntryInput, LoanValue, ServicerWithdrawalResult} from "contracts/interfaces/ILoans.sol";
import {ENTRY_ADJUSTMENT} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_BORROWER_MISC_FEE_PAID,
  ACC_BORROWER_MISC_FEE_RECEIVABLE,
  ACC_CASH,
  ACC_ORIGINATOR_FEE_PAYABLE,
  ACC_SERVICER_FEE_PAYABLE,
  ACC_SERVICER_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAYABLE,
  ACC_UNALLOCATED_BORROWER_MISC_FEE_PAYABLE
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

/// @notice Regression + invariant coverage for the misc-fee collection gate: the servicer
///         misc-fee payable is only recognized (and therefore withdrawable) once the borrower
///         has actually paid the fee through `applyWaterfall`.
contract Loans_MiscFeeCollectionGateTest is LoansTestBase {
  bytes32 constant REF = bytes32("misc_gate");

  function _ids(uint64 id) internal pure returns (uint64[] memory arr) {
    arr = new uint64[](1);
    arr[0] = id;
  }

  /// @dev A charged-but-uncollected misc fee must NOT be swept by `servicerWithdraw`; the
  ///      investor's full cash-backed claim stays withdrawable.
  function test_uncollectedMiscFee_notWithdrawn_investorUnblocked() public accountingEquationHolds {
    uint64 id = _createLoanWithInvestorCashflow(DEFAULT_TEST_PRINCIPAL, REF);
    loanId = id;
    // cash 600, investor owed 590 (90 interest + 500 principal), servicer fee 10.
    assertEq(loans.getLoanAccountBalance(id, ACC_CASH), 600e6);

    vm.prank(servicer);
    loans.chargeMiscFee(id, 50e6, timeNow, REF); // borrower has NOT paid it

    // The charge lands in the unallocated pool, not the withdrawable servicer payable.
    assertEq(loans.getLoanAccountBalance(id, ACC_UNALLOCATED_BORROWER_MISC_FEE_PAYABLE), -50e6);
    assertEq(loans.getLoanAccountBalance(id, ACC_SERVICER_MISC_FEE_PAYABLE), 0);

    uint256 servicerBefore = usdc.balanceOf(servicer);
    vm.prank(servicer);
    ServicerWithdrawalResult[] memory results = loans.servicerWithdraw(_ids(id), timeNow, REF);

    // Only the genuinely earned servicing fee is paid; the uncollected misc fee is not.
    assertEq(results[0].miscFee, 0, "uncollected misc fee must not be withdrawable");
    assertEq(results[0].servicingFee, 10e6);
    assertEq(usdc.balanceOf(servicer) - servicerBefore, 10e6);
    assertEq(loans.getLoanAccountBalance(id, ACC_CASH), 590e6);

    // The investor withdraws the full 590 — no InsufficientCashBalance revert.
    uint256 investorBefore = usdc.balanceOf(investor);
    vm.prank(investor);
    loans.investorWithdraw(_ids(id), timeNow, REF);
    assertEq(usdc.balanceOf(investor) - investorBefore, 590e6);
    assertEq(loans.getLoanAccountBalance(id, ACC_CASH), 0);
  }

  /// @dev On partial collection the servicer withdraws exactly what the borrower paid toward the
  ///      fee, and can never withdraw the same collected amount twice.
  function test_partialCollection_withdrawsExactlyCollected_neverTwice() public accountingEquationHolds {
    uint64 id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    loanId = id;

    vm.prank(servicer);
    loans.chargeMiscFee(id, 100e6, timeNow, REF);

    usdc.mint(borrower, asUint(160e6));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    // Borrower pays 40 toward the fee; waterfall allocates only that 40 to misc.
    vm.prank(borrower);
    loans.pay(id, 40e6, timeNow, REF);
    vm.prank(servicer);
    loans.applyWaterfall(id, 40e6, 0, 0, 0, 0, timeNow, REF);

    assertEq(loans.getLoanAccountBalance(id, ACC_SERVICER_MISC_FEE_PAYABLE), -40e6);
    assertEq(loans.getLoanAccountBalance(id, ACC_UNALLOCATED_BORROWER_MISC_FEE_PAYABLE), -60e6);

    uint256 servicerBefore = usdc.balanceOf(servicer);
    vm.prank(servicer);
    assertEq(loans.servicerWithdraw(_ids(id), timeNow, REF)[0].miscFee, 40e6);
    assertEq(usdc.balanceOf(servicer) - servicerBefore, 40e6);

    // A second sweep pays nothing — the collected 40 cannot be withdrawn twice.
    vm.prank(servicer);
    assertEq(loans.servicerWithdraw(_ids(id), timeNow, REF)[0].miscFee, 0);
    assertEq(usdc.balanceOf(servicer) - servicerBefore, 40e6);

    // Borrower pays the remaining 60; only now is it withdrawable.
    vm.prank(borrower);
    loans.pay(id, 60e6, timeNow, REF);
    vm.prank(servicer);
    loans.applyWaterfall(id, 60e6, 0, 0, 0, 0, timeNow, REF);
    vm.prank(servicer);
    assertEq(loans.servicerWithdraw(_ids(id), timeNow, REF)[0].miscFee, 60e6);

    // Total withdrawn equals the fee charged — never more.
    assertEq(usdc.balanceOf(servicer) - servicerBefore, 100e6);
    assertEq(loans.getLoanAccountBalance(id, ACC_SERVICER_MISC_FEE_PAID), 100e6);
  }

  /// @dev Waiving an uncollected fee is a self-contained receivable<->unallocated reversal
  ///      through the existing `createLedgerEntries` primitive; no servicer accounts involved.
  function test_waiveUncollectedMiscFee() public accountingEquationHolds {
    uint64 id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    loanId = id;

    vm.prank(servicer);
    loans.chargeMiscFee(id, 25e6, timeNow, REF);
    assertEq(loans.getLoanAccountBalance(id, ACC_BORROWER_MISC_FEE_RECEIVABLE), 25e6);
    assertEq(loans.getLoanAccountBalance(id, ACC_UNALLOCATED_BORROWER_MISC_FEE_PAYABLE), -25e6);

    LedgerEntryInput[] memory waiver = new LedgerEntryInput[](1);
    waiver[0] = LedgerEntryInput({
      from: ACC_BORROWER_MISC_FEE_RECEIVABLE,
      to: ACC_UNALLOCATED_BORROWER_MISC_FEE_PAYABLE,
      amount: 25e6,
      entryType: ENTRY_ADJUSTMENT,
      ref: REF
    });
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, waiver);

    assertEq(loans.getLoanAccountBalance(id, ACC_BORROWER_MISC_FEE_RECEIVABLE), 0);
    assertEq(loans.getLoanAccountBalance(id, ACC_UNALLOCATED_BORROWER_MISC_FEE_PAYABLE), 0);

    // Nothing became withdrawable for the servicer.
    vm.prank(servicer);
    assertEq(loans.servicerWithdraw(_ids(id), timeNow, REF)[0].miscFee, 0);
  }

  /// @dev Cash-backing invariant under standard flows: after charging a legitimate but uncollected
  ///      misc fee and running the routine servicer sweep, the sum of positive net payables never
  ///      exceeds `ACC_CASH` for any fee size.
  function testFuzz_cashBackingInvariant_holdsAfterUncollectedFee(uint256 feeRaw) public {
    uint64 id = _createLoanWithInvestorCashflow(DEFAULT_TEST_PRINCIPAL, REF);
    int128 fee = int128(int256(bound(feeRaw, 1, uint256(uint128(DEFAULT_TEST_PRINCIPAL)))));

    vm.prank(servicer);
    loans.chargeMiscFee(id, fee, timeNow, REF);

    vm.prank(servicer);
    loans.servicerWithdraw(_ids(id), timeNow, REF);

    assertLe(_sumPositiveNetPayables(id), loans.getLoanAccountBalance(id, ACC_CASH), "cash < payables");
  }

  function _netPayable(uint64 id, uint8 payable_, uint8 paid) internal view returns (int128) {
    return -loans.getLoanAccountBalance(id, payable_) - loans.getLoanAccountBalance(id, paid);
  }

  function _sumPositiveNetPayables(uint64 id) internal view returns (int128 total) {
    LoanValue memory value = loans.getLoanValues(_ids(id))[0];

    int128 servicerFee = _netPayable(id, ACC_SERVICER_FEE_PAYABLE, ACC_SERVICER_FEE_PAID);
    int128 miscFee = _netPayable(id, ACC_SERVICER_MISC_FEE_PAYABLE, ACC_SERVICER_MISC_FEE_PAID);
    int128 originatorFee = -loans.getLoanAccountBalance(id, ACC_ORIGINATOR_FEE_PAYABLE);

    if (servicerFee > 0) total += servicerFee;
    if (miscFee > 0) total += miscFee;
    if (originatorFee > 0) total += originatorFee;
    if (value.investorInterestWithdrawable > 0) total += value.investorInterestWithdrawable;
    if (value.investorPrincipalWithdrawable > 0) total += value.investorPrincipalWithdrawable;
  }
}
