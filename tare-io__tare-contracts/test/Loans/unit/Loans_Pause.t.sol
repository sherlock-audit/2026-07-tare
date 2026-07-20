// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {Roles, ILoans, LedgerEntryInput, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {ACC_SERVICER_FEE_PAID, ACC_BORROWER_INTEREST_PAID} from "contracts/interfaces/Accounts.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

contract Loans_PauseTest is LoansTestBase {
  // ──────── create ────────

  function test_Create_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loans.pause();

    vm.prank(originator);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.create(borrower, investor, servicer, originator, DEFAULT_TEST_PRINCIPAL, timeNow);
  }

  // ──────── fund ────────

  function test_Fund_Reverts_WhenPaused() public {
    uint64 id = _createTestLoan(DEFAULT_TEST_PRINCIPAL);

    vm.prank(guardian);
    loans.pause();

    vm.prank(investor);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.fund(id, DEFAULT_TEST_PRINCIPAL, timeNow, bytes32("ref"));
  }

  // ──────── disburse ────────

  function test_Disburse_Reverts_WhenPaused() public {
    uint64 id = _createFullyFundedLoan(DEFAULT_TEST_PRINCIPAL);

    vm.prank(guardian);
    loans.pause();

    vm.prank(originator);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.disburse(
      id,
      DEFAULT_TEST_PRINCIPAL,
      0,
      timeNow,
      timeNow + 30 days,
      timeNow + 365 days,
      DEFAULT_INTEREST_RATE,
      DEFAULT_EXPECTED_MONTHLY_PAYMENT,
      timeNow,
      bytes32("ref")
    );
  }

  // ──────── accrue ────────

  function test_Accrue_Reverts_WhenPaused() public {
    uint64 id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);

    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.accrue(id, DEFAULT_ACCRUAL_AMOUNT, timeNow, bytes32("ref"));
  }

  // ──────── chargeMiscFee ────────

  function test_ChargeMiscFee_Reverts_WhenPaused() public {
    uint64 id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);

    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.chargeMiscFee(id, DEFAULT_ACCRUAL_AMOUNT, timeNow, bytes32("ref"));
  }

  // ──────── pay ────────

  function test_Pay_Reverts_WhenPaused() public {
    uint64 id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);

    usdc.mint(borrower, asUint(DEFAULT_PAYMENT_AMOUNT));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(guardian);
    loans.pause();

    vm.prank(borrower);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.pay(id, DEFAULT_PAYMENT_AMOUNT, timeNow, bytes32("ref"));
  }

  // ──────── applyWaterfall ────────

  function test_ApplyWaterfall_Reverts_WhenPaused() public {
    uint64 id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);

    // Accrue and receive payment so there's something to allocate
    vm.prank(servicer);
    loans.accrue(id, DEFAULT_ACCRUAL_AMOUNT, timeNow, bytes32("ref"));

    usdc.mint(borrower, asUint(DEFAULT_PAYMENT_AMOUNT));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(borrower);
    loans.pay(id, DEFAULT_PAYMENT_AMOUNT, timeNow, bytes32("ref"));

    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.applyWaterfall(
      id,
      0,
      DEFAULT_SERVICER_FEE,
      DEFAULT_INVESTOR_INTEREST,
      DEFAULT_PRINCIPAL_REPAYMENT,
      0,
      timeNow,
      bytes32("ref")
    );
  }

  // ──────── servicerWithdraw ────────

  function test_ServicerWithdraw_Reverts_WhenPaused() public {
    uint64 id = _createLoanWithInvestorCashflow(DEFAULT_TEST_PRINCIPAL, bytes32("ref"));

    vm.prank(guardian);
    loans.pause();

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.servicerWithdraw(ids, timeNow, bytes32("ref"));
  }

  // ──────── investorWithdraw ────────

  function test_InvestorWithdraw_Reverts_WhenPaused() public {
    uint64 id = _createLoanWithInvestorCashflow(DEFAULT_TEST_PRINCIPAL, bytes32("ref"));

    vm.prank(guardian);
    loans.pause();

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    vm.prank(investor);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.investorWithdraw(ids, timeNow, bytes32("ref"));
  }

  // ──────── investorWithdraw ────────

  function test_InvestorWithdraw_Unlocker_Reverts_WhenPaused() public {
    uint64 id = _createLoanWithInvestorCashflow(DEFAULT_TEST_PRINCIPAL, bytes32("ref"));

    // Lock the loan to a locker
    address locker = makeAddr("locker");
    vm.prank(investor);
    loansNFT.lock(locker, uint256(id));

    vm.prank(guardian);
    loans.pause();

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    vm.prank(locker);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.investorWithdraw(ids, timeNow, bytes32("ref"));
  }

  // ──────── originatorWithdraw ────────

  function test_OriginatorWithdraw_Reverts_WhenPaused() public {
    uint64 id = _createActiveLoanWithOriginationFee(DEFAULT_TEST_PRINCIPAL, DEFAULT_ACCRUAL_AMOUNT);

    vm.prank(guardian);
    loans.pause();

    uint64[] memory ids = new uint64[](1);
    ids[0] = id;

    vm.prank(originator);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.originatorWithdraw(ids, timeNow, bytes32("ref"));
  }

  // ──────── refundBorrower ────────

  function test_RefundBorrower_Reverts_WhenPaused() public {
    uint64 id = _createLoanWithInvestorCashflow(DEFAULT_TEST_PRINCIPAL, bytes32("ref"));

    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.refundBorrower(id, ACC_BORROWER_INTEREST_PAID, DEFAULT_ACCRUAL_AMOUNT, timeNow, 0, bytes32("ref"));
  }

  // ──────── returnFunds ────────

  function test_ReturnFunds_Reverts_WhenPaused() public {
    uint64 id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);

    usdc.mint(servicer, uint256(uint128(DEFAULT_TEST_PRINCIPAL)));
    vm.prank(servicer);
    usdc.approve(address(loans), type(uint256).max);

    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.returnFunds(id, ACC_SERVICER_FEE_PAID, DEFAULT_ACCRUAL_AMOUNT, timeNow, 0, bytes32("ref"));
  }

  // ──────── rescueERC20Tokens ────────

  function test_RescueERC20Tokens_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loans.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.rescueERC20Tokens(address(1), 1);
  }

  // ──────── rescueERC721Tokens ────────

  function test_RescueERC721Tokens_Reverts_WhenPaused() public {
    vm.prank(guardian);
    loans.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.rescueERC721Tokens(address(1), 1);
  }

  // ──────── updateBorrower ────────

  function test_UpdateBorrower_Reverts_WhenPaused() public {
    uint64 loanId = _createActiveLoan(100_000e6);

    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.updateBorrower(loanId, address(0xBEEF));
  }

  // ──────── updateServicer ────────

  function test_UpdateServicer_Reverts_WhenPaused() public {
    uint64 loanId = _createActiveLoan(100_000e6);

    vm.prank(guardian);
    loans.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.updateServicer(loanId, address(0xBEEF));
  }

  // ──────── createLedgerEntries ────────

  function test_CreateLedgerEntries_Reverts_WhenPaused() public {
    uint64 loanId = _createActiveLoan(100_000e6);

    vm.prank(guardian);
    loans.pause();

    LedgerEntryInput[] memory entries = new LedgerEntryInput[](0);

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.createLedgerEntries(loanId, timeNow, entries);
  }

  // ──────── updateLoanData ────────

  function test_UpdateLoanData_Reverts_WhenPaused() public {
    uint64 loanId = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);

    vm.prank(guardian);
    loans.pause();

    vm.prank(servicer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    loans.updateLoanData({
      loanId: loanId,
      status: LoanStatus.ChargedOff,
      nextDueDate: 0,
      maturityDate: 0,
      timestamp: timeNow
    });
  }
}
