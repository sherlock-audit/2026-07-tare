// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_E2ETest is LoansTestBase {
  /// @notice Full lifecycle E2E tracking USDC balances of every party at each phase.
  /// Create → Fund → Disburse (with origination fee) → Pay originator →
  /// Accrue → Receive payment → Apply waterfall → Servicer withdraw → Investor withdraw
  function test_FullLifecycle_USDCBalances() public {
    int128 principal = 10_000e6;
    int128 originationFee = 100e6;
    int128 netDisbursed = 9_900e6;
    int128 accrualAmount = 100e6;
    int128 paymentAmount = 600e6;
    int128 svcFee = 10e6;
    int128 investorInterest = 90e6;
    int128 prinRepay = 500e6;
    bytes32 ref = bytes32("e2e");

    // Snapshot initial balances (investor was pre-funded in LoansTestBase.setUp)
    uint256 investorStart = usdc.balanceOf(investor);

    // ═══════════════ Create ═══════════════
    loanId = _createTestLoan(principal);
    // No token movement
    assertEq(_loansContractBalance(), 0);

    // ═══════════════ Fund ═══════════════
    vm.prank(investor);
    loans.fund(loanId, principal, timeNow, ref);

    assertEq(usdc.balanceOf(investor), investorStart - asUint(principal));
    assertEq(_loansContractBalance(), asUint(principal));

    // ═══════════════ Disburse (with origination fee) ═══════════════
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

    assertEq(usdc.balanceOf(borrower), asUint(netDisbursed));
    assertEq(_loansContractBalance(), asUint(originationFee)); // fee held in contract
    assertEq(usdc.balanceOf(originator), 0); // not yet paid

    // ═══════════════ Pay originator ═══════════════
    uint64[] memory originatorLoanIds = new uint64[](1);
    originatorLoanIds[0] = loanId;
    vm.prank(originator);
    loans.originatorWithdraw(originatorLoanIds, timeNow, ref);

    assertEq(usdc.balanceOf(originator), asUint(originationFee));
    assertEq(_loansContractBalance(), 0);

    // ═══════════════ Accrue ═══════════════
    vm.prank(servicer);
    loans.accrue(loanId, accrualAmount, timeNow, ref);
    assertEq(_loansContractBalance(), 0);

    // ═══════════════ Receive borrower payment ═══════════════
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    uint256 borrowerBeforePayment = usdc.balanceOf(borrower);
    vm.prank(borrower);
    loans.pay(loanId, paymentAmount, timeNow, ref);

    assertEq(usdc.balanceOf(borrower), borrowerBeforePayment - asUint(paymentAmount));
    assertEq(_loansContractBalance(), asUint(paymentAmount));

    // ═══════════════ Apply waterfall ═══════════════
    vm.prank(servicer);
    loans.applyWaterfall(loanId, 0, svcFee, investorInterest, prinRepay, 0, timeNow, ref);
    assertEq(_loansContractBalance(), asUint(paymentAmount));

    // ═══════════════ Servicer withdraw ═══════════════
    uint64[] memory svcLoanIds = new uint64[](1);
    svcLoanIds[0] = loanId;
    vm.prank(servicer);
    loans.servicerWithdraw(svcLoanIds, timeNow, ref);

    assertEq(usdc.balanceOf(servicer), asUint(svcFee));
    assertEq(_loansContractBalance(), asUint(paymentAmount - svcFee));

    // ═══════════════ Investor withdraw ═══════════════
    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId;

    vm.prank(investor);
    loans.investorWithdraw(loanIds, timeNow, ref);

    assertEq(usdc.balanceOf(investor), investorStart - asUint(principal) + asUint(prinRepay + investorInterest));
    assertEq(_loansContractBalance(), 0);
  }
}
