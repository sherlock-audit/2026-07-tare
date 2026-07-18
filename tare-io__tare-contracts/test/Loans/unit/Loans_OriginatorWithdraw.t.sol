// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, ILoans, OriginatorWithdrawalResult} from "contracts/interfaces/ILoans.sol";
import {ENTRY_ORIGINATOR_FEE_WITHDRAWAL} from "contracts/interfaces/LedgerEntries.sol";
import {ACC_CASH, ACC_ORIGINATOR_FEE_PAID, ACC_ORIGINATOR_FEE_PAYABLE} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_OriginatorWithdrawTest is LoansTestBase {
  int128 constant PRINCIPAL = 10_000e6;
  int128 constant ORIGINATION_FEE = 500e6;

  function setUp() public override {
    super.setUp();
    usdc.mint(borrower, asUint(PRINCIPAL * 10));
  }

  function test_originatorWithdraw_multipleLoans() public {
    testLoanIds.push(_createActiveLoanWithOriginationFee(PRINCIPAL, ORIGINATION_FEE));
    testLoanIds.push(_createActiveLoanWithOriginationFee(PRINCIPAL, ORIGINATION_FEE));
    testLoanIds.push(_createActiveLoanWithOriginationFee(PRINCIPAL, ORIGINATION_FEE));
    uint256 originatorBalanceBefore = usdc.balanceOf(originator);
    uint256 contractBalanceBefore = _loansContractBalance();

    uint64[3] memory entryCountsBefore;
    for (uint256 i = 0; i < 3; i++) {
      entryCountsBefore[i] = loans.entryCount(testLoanIds[i]);
    }

    vm.prank(originator);
    OriginatorWithdrawalResult[] memory results = loans.originatorWithdraw(
      _getTestLoanIdArray(3),
      timeNow,
      offchainRef
    );

    assertEq(results.length, 3);
    for (uint256 i = 0; i < 3; i++) {
      assertEq(results[i].loanId, testLoanIds[i]);
      assertEq(results[i].amount, ORIGINATION_FEE);
      assertEq(loans.entryCount(testLoanIds[i]), entryCountsBefore[i] + 1);

      Entry memory e = loans.getLoanEntry(testLoanIds[i], entryCountsBefore[i] + 1);
      assertEq(uint8(e.from), ACC_CASH);
      assertEq(uint8(e.to), ACC_ORIGINATOR_FEE_PAID);
      assertEq(e.amount, ORIGINATION_FEE);
      assertEq(e.entryType, ENTRY_ORIGINATOR_FEE_WITHDRAWAL);

      int128 feePayable = loans.getLoanAccountBalance(testLoanIds[i], ACC_ORIGINATOR_FEE_PAYABLE);
      int128 feePaid = loans.getLoanAccountBalance(testLoanIds[i], ACC_ORIGINATOR_FEE_PAID);
      assertEq(feePayable + feePaid, 0, "Originator fee not fully settled");
    }

    uint256 totalWithdrawn = asUint(ORIGINATION_FEE) * 3;
    assertEq(usdc.balanceOf(originator), originatorBalanceBefore + totalWithdrawn);
    assertEq(_loansContractBalance(), contractBalanceBefore - totalWithdrawn);
  }

  function test_originatorWithdraw_revertsOnLoanIdZero() public {
    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = 0;

    vm.prank(originator);
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.originatorWithdraw(loanIds, timeNow, offchainRef);
  }
}
