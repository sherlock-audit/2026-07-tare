// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "./setup/LoansTestBase.t.sol";
import {VaultTestBase} from "./VaultTestBase.t.sol";
import {NavCalculator} from "contracts/NavCalculator.sol";
import {
  ILoans,
  LedgerEntryInput,
  InvestorWithdrawalResult,
  ServicerWithdrawalResult
} from "contracts/interfaces/ILoans.sol";
import {
  ENTRY_INTEREST_REVERSAL,
  ENTRY_INTEREST_RECLASSIFICATION,
  ENTRY_SERVICER_FEE_REVERSAL,
  ENTRY_SERVICER_FEE_ALLOCATION,
  ENTRY_SERVICER_FEE_RECLASSIFICATION,
  ENTRY_SERVICER_FUND_RETURN,
  ENTRY_ADJUSTMENT
} from "contracts/interfaces/LedgerEntries.sol";
import {
  ACC_CASH,
  ACC_BORROWER_INTEREST_RECEIVABLE,
  ACC_BORROWER_PRINCIPAL_REPAID,
  ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
  ACC_INVESTOR_INTEREST_PAYABLE,
  ACC_INVESTOR_INTEREST_PAID,
  ACC_INVESTOR_PRINCIPAL_REPAID,
  ACC_SERVICER_ADJUSTMENT,
  ACC_SERVICER_FEE_PAYABLE,
  ACC_SERVICER_FEE_PAID,
  ACC_SERVICER_MISC_FEE_PAYABLE,
  ACC_SERVICER_MISC_FEE_PAID
} from "contracts/interfaces/Accounts.sol";
import {asUint} from "test/helpers/Int128Utils.sol";

/**
 * @title NegativeNetGuardsTest
 * @notice Regression tests for the negative-net-payable guards (findings 291/607/1200):
 * `createLedgerEntries` rejects batches that end with a negative investor net
 * (`InvestorNetNegative`), and `servicerWithdraw` reverts while either servicer fee
 * bucket is negative (`ServicerOwesFunds`). Withdrawal settlement itself is the
 * original per-bucket logic — safe because the dangerous states are unrepresentable
 * (investor) or frozen until cured (servicer).
 */
contract NegativeNetGuardsTest is LoansTestBase {
  bytes32 internal constant REF = bytes32("guards");

  /// @dev Accrues, charges, pays, and allocates one borrower payment cycle.
  function _payAndAllocate(uint64 id, int128 miscFees, int128 svcFee, int128 invInterest, int128 principal) internal {
    _payAndAllocateWithAccrual(id, svcFee + invInterest, miscFees, svcFee, invInterest, principal);
  }

  /// @dev Same as `_payAndAllocate` but with an explicit (possibly wrong) accrual amount.
  function _payAndAllocateWithAccrual(
    uint64 id,
    int128 accrual,
    int128 miscFees,
    int128 svcFee,
    int128 invInterest,
    int128 principal
  ) internal {
    if (accrual > 0) {
      vm.prank(servicer);
      loans.accrue(id, accrual, timeNow, REF);
    }
    if (miscFees > 0) {
      vm.prank(servicer);
      loans.chargeMiscFee(id, miscFees, timeNow, REF);
    }

    int128 payment = accrual + miscFees + principal;
    usdc.mint(borrower, asUint(payment));
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);
    vm.prank(borrower);
    loans.pay(id, payment, timeNow, REF);

    vm.prank(servicer);
    loans.applyWaterfall(id, miscFees, svcFee, invInterest, principal, 0, timeNow, REF);
  }

  /// @dev Withdraws all investor and servicer cash so the loan starts the next cycle clean.
  function _distributeAll(uint64 id) internal {
    uint64[] memory ids = _ids(id);
    vm.prank(investor);
    loans.investorWithdraw(ids, timeNow, REF);
    vm.prank(servicer);
    loans.servicerWithdraw(ids, timeNow, REF);
  }

  function _ids(uint64 id) internal pure returns (uint64[] memory ids) {
    ids = new uint64[](1);
    ids[0] = id;
  }

  function _netInterest(uint64 id) internal view returns (int128) {
    return
      -loans.getLoanAccountBalance(id, ACC_INVESTOR_INTEREST_PAYABLE) -
      loans.getLoanAccountBalance(id, ACC_INVESTOR_INTEREST_PAID);
  }

  function _netPrincipal(uint64 id) internal view returns (int128) {
    return
      -loans.getLoanAccountBalance(id, ACC_BORROWER_PRINCIPAL_REPAID) -
      loans.getLoanAccountBalance(id, ACC_INVESTOR_PRINCIPAL_REPAID);
  }

  function _netServicingFee(uint64 id) internal view returns (int128) {
    return
      -loans.getLoanAccountBalance(id, ACC_SERVICER_FEE_PAYABLE) -
      loans.getLoanAccountBalance(id, ACC_SERVICER_FEE_PAID);
  }

  function _netMiscFee(uint64 id) internal view returns (int128) {
    return
      -loans.getLoanAccountBalance(id, ACC_SERVICER_MISC_FEE_PAYABLE) -
      loans.getLoanAccountBalance(id, ACC_SERVICER_MISC_FEE_PAID);
  }

  function _entry(
    uint8 from,
    uint8 to,
    int128 amount,
    uint16 entryType
  ) internal pure returns (LedgerEntryInput memory) {
    return LedgerEntryInput({from: from, to: to, amount: amount, entryType: entryType, ref: REF});
  }

  // ─────────────── createLedgerEntries: investor nets must end >= 0 ───────────────

  /// @dev Finding 1200's shape: reversing already-paid investor interest without
  ///      rebooking the delta leaves the interest net negative.
  function test_createLedgerEntries_revertsOnNegativeInterestNet() public {
    uint64 id = _createActiveLoan(10_000e6);
    _payAndAllocate(id, 0, 10e6, 90e6, 0);
    _distributeAll(id);

    LedgerEntryInput[] memory batch = new LedgerEntryInput[](2);
    batch[0] = _entry(
      ACC_BORROWER_INTEREST_RECEIVABLE,
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      40e6,
      ENTRY_INTEREST_REVERSAL
    );
    batch[1] = _entry(
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      ACC_INVESTOR_INTEREST_PAYABLE,
      40e6,
      ENTRY_INTEREST_REVERSAL
    );

    vm.expectRevert(ILoans.InvestorNetNegative.selector);
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);
  }

  /// @dev The legacy correction recharacterizing paid interest as
  ///      early principal return leaves the principal net negative.
  function test_createLedgerEntries_revertsOnNegativePrincipalNet() public {
    uint64 id = _createActiveLoan(10_000e6);
    _payAndAllocate(id, 0, 10e6, 90e6, 500e6);
    _distributeAll(id);

    LedgerEntryInput[] memory batch = new LedgerEntryInput[](1);
    batch[0] = _entry(ACC_INVESTOR_INTEREST_PAID, ACC_INVESTOR_PRINCIPAL_REPAID, 40e6, ENTRY_INTEREST_RECLASSIFICATION);

    vm.expectRevert(ILoans.InvestorNetNegative.selector);
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);
  }

  /// @dev The check is batch-end: an in-batch transient negative is fine as long as the
  ///      batch restores the nets before it completes.
  function test_createLedgerEntries_allowsTransientNegatives() public {
    uint64 id = _createActiveLoan(10_000e6);
    _payAndAllocate(id, 0, 10e6, 90e6, 500e6);
    _distributeAll(id);

    LedgerEntryInput[] memory batch = new LedgerEntryInput[](2);
    batch[0] = _entry(ACC_INVESTOR_INTEREST_PAID, ACC_INVESTOR_PRINCIPAL_REPAID, 40e6, ENTRY_INTEREST_RECLASSIFICATION);
    batch[1] = _entry(ACC_INVESTOR_PRINCIPAL_REPAID, ACC_INVESTOR_INTEREST_PAID, 40e6, ENTRY_INTEREST_RECLASSIFICATION);

    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);

    assertEq(_netInterest(id), 0);
    assertEq(_netPrincipal(id), 0);
  }

  /// @dev Canonical Scenario 4A correction: investor was over-distributed $10 of interest
  ///      (earned 90, allocated and paid 100) and the servicer absorbs the loss. The
  ///      4-entry batch passes the check and is balance-neutral: its value is the audit trail.
  function test_createLedgerEntries_canonicalWriteOffRecipe() public {
    uint64 id = _createActiveLoan(10_000e6);
    // Correct accrual 110 (20 svc + 90 interest); wrong split: 10 svc / 100 investor interest.
    _payAndAllocateWithAccrual(id, 110e6, 0, 10e6, 100e6, 500e6);
    _distributeAll(id);

    int128 payableBefore = loans.getLoanAccountBalance(id, ACC_INVESTOR_INTEREST_PAYABLE);
    int128 svcPayableBefore = loans.getLoanAccountBalance(id, ACC_SERVICER_FEE_PAYABLE);

    LedgerEntryInput[] memory batch = new LedgerEntryInput[](4);
    batch[0] = _entry(
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      ACC_INVESTOR_INTEREST_PAYABLE,
      10e6,
      ENTRY_INTEREST_REVERSAL
    );
    batch[1] = _entry(
      ACC_SERVICER_FEE_PAYABLE,
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      10e6,
      ENTRY_SERVICER_FEE_ALLOCATION
    );
    batch[2] = _entry(ACC_SERVICER_ADJUSTMENT, ACC_SERVICER_FEE_PAYABLE, 10e6, ENTRY_ADJUSTMENT);
    batch[3] = _entry(ACC_INVESTOR_INTEREST_PAYABLE, ACC_SERVICER_ADJUSTMENT, 10e6, ENTRY_ADJUSTMENT);

    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);

    assertEq(
      loans.getLoanAccountBalance(id, ACC_INVESTOR_INTEREST_PAYABLE),
      payableBefore,
      "investor payable unchanged"
    );
    assertEq(loans.getLoanAccountBalance(id, ACC_SERVICER_FEE_PAYABLE), svcPayableBefore, "servicer payable unchanged");
    assertEq(loans.getLoanAccountBalance(id, ACC_SERVICER_ADJUSTMENT), 0, "adjustment passes through to zero");
    assertEq(loans.getLoanAccountBalance(id, ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE), 0, "unallocated clean");
    assertEq(_netInterest(id), 0);
    assertEq(_netPrincipal(id), 0);
    assertEq(_netServicingFee(id), 0);
  }

  // ─────────────── servicerWithdraw: freezes while a fee bucket is negative ───────────────

  /// @dev Documented Scenario 2A lifecycle is unaffected by the guard: the credit is
  ///      absorbed by the next cycle's fee allocation before any withdrawal happens.
  ///      The borrower's own over-payment credit caps the next waterfall's interest
  ///      portion at 100, so the residual 10 of unallocated obligation is routed to the
  ///      servicer with an explicit allocation entry.
  function test_servicerWithdraw_scenario2ACreditLifecycle() public {
    uint64 id = _createActiveLoan(10_000e6);
    // Over-accrual 120 (should be 110); wrong split gives the servicer 30 instead of 20.
    _payAndAllocateWithAccrual(id, 120e6, 0, 30e6, 90e6, 500e6);
    _distributeAll(id);

    // 2A correction: reverse over-accrual, reverse servicer over-allocation.
    LedgerEntryInput[] memory batch = new LedgerEntryInput[](2);
    batch[0] = _entry(
      ACC_BORROWER_INTEREST_RECEIVABLE,
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      10e6,
      ENTRY_INTEREST_REVERSAL
    );
    batch[1] = _entry(
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      ACC_SERVICER_FEE_PAYABLE,
      10e6,
      ENTRY_SERVICER_FEE_REVERSAL
    );
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);

    assertEq(_netServicingFee(id), -10e6, "credit open");

    // Guard: an indebted servicer cannot withdraw while the credit is open.
    vm.expectRevert(ILoans.ServicerOwesFunds.selector);
    vm.prank(servicer);
    loans.servicerWithdraw(_ids(id), timeNow, REF);

    // Next cycle: borrower pays 600 (110 accrual - 10 credit + 500 principal).
    vm.prank(servicer);
    loans.accrue(id, 110e6, timeNow, REF);
    usdc.mint(borrower, 600e6);
    vm.prank(borrower);
    loans.pay(id, 600e6, timeNow, REF);
    vm.prank(servicer);
    loans.applyWaterfall(id, 0, 10e6, 90e6, 500e6, 0, timeNow, REF);

    // Route the residual 10 of unallocated obligation to the servicer.
    LedgerEntryInput[] memory residual = new LedgerEntryInput[](1);
    residual[0] = _entry(
      ACC_SERVICER_FEE_PAYABLE,
      ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      10e6,
      ENTRY_SERVICER_FEE_ALLOCATION
    );
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, residual);

    assertEq(_netServicingFee(id), 10e6, "credit absorbed: servicer nets 10 over both cycles");

    uint256 balanceBefore = usdc.balanceOf(servicer);
    vm.prank(servicer);
    ServicerWithdrawalResult[] memory results = loans.servicerWithdraw(_ids(id), timeNow, REF);
    assertEq(usdc.balanceOf(servicer) - balanceBefore, 10e6, "servicer nets 10 after repaying the credit");
    assertEq(results[0].servicingFee, 10e6);
    assertEq(loans.getLoanAccountBalance(id, ACC_CASH), 590e6, "remaining cash backs the investor's 90 + 500");
  }

  /// @dev Finding 607's shape: servicing credit open while misc income is withdrawable.
  function test_servicerWithdraw_revertsWhenServicingLegNegative() public {
    uint64 id = _setupServicingCreditWithMiscIncome();

    vm.expectRevert(ILoans.ServicerOwesFunds.selector);
    vm.prank(servicer);
    loans.servicerWithdraw(_ids(id), timeNow, REF);
  }

  function test_servicerWithdraw_revertsWhenMiscLegNegative() public {
    uint64 id = _createActiveLoan(10_000e6);
    _payAndAllocate(id, 20e6, 0, 0, 0);
    vm.prank(servicer);
    loans.servicerWithdraw(_ids(id), timeNow, REF);

    // Servicer owes back 8 of already-received misc fees.
    LedgerEntryInput[] memory batch = new LedgerEntryInput[](1);
    batch[0] = _entry(ACC_SERVICER_ADJUSTMENT, ACC_SERVICER_MISC_FEE_PAYABLE, 8e6, ENTRY_ADJUSTMENT);
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);

    _payAndAllocate(id, 0, 30e6, 0, 0);

    vm.expectRevert(ILoans.ServicerOwesFunds.selector);
    vm.prank(servicer);
    loans.servicerWithdraw(_ids(id), timeNow, REF);
  }

  /// @dev Cure path 1: the servicer returns cash for the amount it owes.
  function test_servicerWithdraw_curedByReturnFunds() public {
    uint64 id = _setupServicingCreditWithMiscIncome();

    usdc.mint(servicer, 6e6);
    vm.startPrank(servicer);
    usdc.approve(address(loans), type(uint256).max);
    loans.returnFunds(id, ACC_SERVICER_FEE_PAID, 6e6, timeNow, ENTRY_SERVICER_FUND_RETURN, REF);
    vm.stopPrank();

    assertEq(_netServicingFee(id), 0, "cash return cures the credit");

    uint256 balanceBefore = usdc.balanceOf(servicer);
    vm.prank(servicer);
    ServicerWithdrawalResult[] memory results = loans.servicerWithdraw(_ids(id), timeNow, REF);
    assertEq(usdc.balanceOf(servicer) - balanceBefore, 20e6, "full misc income withdrawable after cure");
    assertEq(results[0].miscFee, 20e6);
  }

  /// @dev Cure path 2: a manual reclassification entry between the two servicer paid
  ///      accounts (preserves paid balances == cash received by the servicer).
  function test_servicerWithdraw_curedByManualReclassification() public {
    uint64 id = _setupServicingCreditWithMiscIncome();

    LedgerEntryInput[] memory batch = new LedgerEntryInput[](1);
    batch[0] = _entry(ACC_SERVICER_FEE_PAID, ACC_SERVICER_MISC_FEE_PAID, 6e6, ENTRY_SERVICER_FEE_RECLASSIFICATION);
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);

    assertEq(_netServicingFee(id), 0, "reclass cures the servicing leg");
    assertEq(_netMiscFee(id), 14e6, "misc entitlement reduced by the debt");

    uint256 balanceBefore = usdc.balanceOf(servicer);
    vm.prank(servicer);
    ServicerWithdrawalResult[] memory results = loans.servicerWithdraw(_ids(id), timeNow, REF);
    assertEq(usdc.balanceOf(servicer) - balanceBefore, 14e6, "pays the netted amount");
    assertEq(results[0].miscFee, 14e6);
    assertEq(results[0].servicingFee, 0);
  }

  /// @dev Servicing credit of 6 (owed back) alongside 20 of withdrawable misc income; cash 20.
  function _setupServicingCreditWithMiscIncome() internal returns (uint64 id) {
    id = _createActiveLoan(10_000e6);
    _payAndAllocate(id, 0, 10e6, 90e6, 0);
    _distributeAll(id);

    LedgerEntryInput[] memory batch = new LedgerEntryInput[](1);
    batch[0] = _entry(ACC_SERVICER_ADJUSTMENT, ACC_SERVICER_FEE_PAYABLE, 6e6, ENTRY_ADJUSTMENT);
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);

    _payAndAllocate(id, 20e6, 0, 0, 0);

    assertEq(_netServicingFee(id), -6e6, "servicing credit open");
    assertEq(_netMiscFee(id), 20e6, "misc income withdrawable");
  }
}

/**
 * @title NegativeNetGuardsVaultTest
 * @notice The vault can never observe a mixed-sign investor state: the correction that
 * would create one (finding 1200's setup) reverts at `createLedgerEntries`, so routine
 * cash collection always transfers exactly the investor's entitlement.
 */
contract NegativeNetGuardsVaultTest is VaultTestBase {
  bytes32 internal constant REF = bytes32("guards-nav");

  NavCalculator internal realCalculator;

  function setUp() public override {
    super.setUp();

    uint256[8] memory factors = [
      uint256(WAD),
      uint256(WAD),
      uint256(WAD),
      uint256(WAD),
      uint256(WAD),
      uint256(WAD),
      uint256(WAD),
      uint256(WAD)
    ];
    realCalculator = new NavCalculator(guardian, factors);

    vm.prank(guardian);
    vault.setCalculator(address(realCalculator));
  }

  function test_correctionCreatingMixedSignStateReverts() public {
    uint64 id = _createActiveLoan(10_000e6);
    _transferLoanToVault(id);

    vm.prank(servicer);
    loans.accrue(id, 100e6, timeNow, REF);
    usdc.mint(borrower, 100e6);
    vm.prank(borrower);
    usdc.approve(address(loans), type(uint256).max);
    vm.prank(borrower);
    loans.pay(id, 100e6, timeNow, REF);
    vm.prank(servicer);
    loans.applyWaterfall(id, 0, 10e6, 90e6, 0, 0, timeNow, REF);

    vault.collectCashflows(_singleLoanArray(id), REF);
    assertEq(usdc.balanceOf(address(vault)), 90e6, "interest collected");

    // Finding 1200's correction: reverse 50 of the already-collected interest.
    LedgerEntryInput[] memory batch = new LedgerEntryInput[](2);
    batch[0] = LedgerEntryInput({
      from: ACC_BORROWER_INTEREST_RECEIVABLE,
      to: ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      amount: 50e6,
      entryType: ENTRY_INTEREST_REVERSAL,
      ref: REF
    });
    batch[1] = LedgerEntryInput({
      from: ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE,
      to: ACC_INVESTOR_INTEREST_PAYABLE,
      amount: 50e6,
      entryType: ENTRY_INTEREST_REVERSAL,
      ref: REF
    });

    vm.expectRevert(ILoans.InvestorNetNegative.selector);
    vm.prank(servicer);
    loans.createLedgerEntries(id, timeNow, batch);
  }
}
