// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Entry, ILoans, ServicerWithdrawalResult} from "contracts/interfaces/ILoans.sol";
import {ENTRY_SERVICER_FEE_WITHDRAWAL} from "contracts/interfaces/LedgerEntries.sol";
import {ACC_CASH, ACC_SERVICER_FEE_PAID} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_ServicerWithdrawTest is LoansTestBase {
  int128 constant PRINCIPAL = 10_000e6;
  int128 constant SERVICER_FEE = 10e6;
  bytes32 constant REF = bytes32("test_ref");

  function setUp() public override {
    super.setUp();
    loanId = _createLoanWithInvestorCashflow(PRINCIPAL, REF);
  }

  function test_servicerWithdraw() public accountingEquationHolds {
    uint256 servicerBalanceBefore = usdc.balanceOf(servicer);
    uint256 contractBalanceBefore = _loansContractBalance();
    uint64 entryCountBefore = loans.entryCount(loanId);

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId;

    vm.prank(servicer);
    loans.servicerWithdraw(loanIds, timeNow, REF);

    assertEq(loans.entryCount(loanId), entryCountBefore + 1);

    Entry memory entry = loans.getLoanEntry(loanId, entryCountBefore + 1);
    assertEq(uint8(entry.from), ACC_CASH);
    assertEq(uint8(entry.to), ACC_SERVICER_FEE_PAID);
    assertEq(entry.amount, SERVICER_FEE);
    assertEq(entry.entryType, ENTRY_SERVICER_FEE_WITHDRAWAL);

    assertEq(usdc.balanceOf(servicer), servicerBalanceBefore + asUint(SERVICER_FEE));
    assertEq(_loansContractBalance(), contractBalanceBefore - asUint(SERVICER_FEE));
  }

  function test_servicerWithdraw_multiLoan() public accountingEquationHolds {
    uint64 loanId2 = _createLoanWithInvestorCashflow(PRINCIPAL, bytes32("loan2"));

    uint256 servicerBalanceBefore = usdc.balanceOf(servicer);

    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanId;
    loanIds[1] = loanId2;

    vm.prank(servicer);
    ServicerWithdrawalResult[] memory results = loans.servicerWithdraw(loanIds, timeNow, REF);

    assertEq(results.length, 2);
    assertEq(results[0].loanId, loanId);
    assertEq(results[0].servicingFee, SERVICER_FEE);
    assertEq(results[1].loanId, loanId2);
    assertEq(results[1].servicingFee, SERVICER_FEE);

    assertEq(usdc.balanceOf(servicer), servicerBalanceBefore + asUint(SERVICER_FEE) * 2);
  }

  function test_servicerWithdraw_revertsOnLoanIdZero() public {
    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = 0;

    vm.prank(servicer);
    vm.expectRevert(ILoans.DoesNotExist.selector);
    loans.servicerWithdraw(loanIds, timeNow, REF);
  }
}
