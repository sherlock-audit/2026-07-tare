// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {INavCalculator} from "contracts/interfaces/INavCalculator.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";
import {MockNavCalculator} from "test/lib/MockNavCalculator.sol";

/**
 * @title Vault_CalculatorConfigurationChangedTest
 * @notice Verifies that share-price-sensitive operations (`approveDeposit`,
 * `approveRedemption`) reject a cached NAV after the calculator's factor
 * version has been bumped, until a fresh `updateNav` finalizes against the
 * new version. Also verifies mid-cycle restarts and `setCalculator` invalidation.
 */
contract Vault_CalculatorConfigurationChangedTest is VaultTestBase {
  function setUp() public override {
    super.setUp();

    usdc.mint(shareholder1, type(uint128).max);
    vm.prank(shareholder1);
    usdc.approve(address(vault), type(uint256).max);
  }

  // ─────────────────── approveDeposit / approveRedemption ───────────────

  function test_ApproveDeposit_Reverts_AfterFactorsBump() public {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    mockCalculator.bumpConfigurationVersion();

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.CalculatorConfigurationChanged.selector);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveDeposit_Succeeds_AfterFreshUpdateNav() public {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    // Bump and then recompute NAV; approveDeposit should work again
    mockCalculator.bumpConfigurationVersion();
    _refreshNav();

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    assertEq(vault.claimableDepositAssets(shareholder1), DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveRedemption_Reverts_AfterFactorsBump() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, DEFAULT_DEPOSIT_AMOUNT, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    mockCalculator.bumpConfigurationVersion();

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.CalculatorConfigurationChanged.selector);
    vault.approveRedemption(shareholder1, shares);
  }

  function test_ApproveRedemption_Succeeds_AfterFreshUpdateNav() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, DEFAULT_DEPOSIT_AMOUNT, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    // Bump and then recompute NAV; approveRedemption should work again
    mockCalculator.bumpConfigurationVersion();
    _refreshNav();

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    assertEq(vault.claimableRedeemShares(shareholder1), shares);
  }

  // ─────────────────── lastCalculatorConfigurationVersion bookkeeping ────────────────

  function test_UpdateNav_StoresLastCalculatorConfigurationVersion() public {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);
    assertEq(vault.lastCalculatorConfigurationVersion(), mockCalculator.configurationVersion());

    mockCalculator.bumpConfigurationVersion();
    _refreshNav();
    assertEq(vault.lastCalculatorConfigurationVersion(), mockCalculator.configurationVersion());
  }

  // ─────────────────── mid-cycle restart on version change ─────────────

  function test_UpdateNav_RestartsCycle_WhenFactorsChangeMidCycle() public {
    // Seed two loans so cycle requires at least two batches at batchSize=1
    uint64 loan1 = _createActiveLoan(25_000e6);
    uint64 loan2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(loan1);
    _transferLoanToVault(loan2);
    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(10_000e6);

    // First batch — opens a cycle
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(block.timestamp);
    vm.prank(manager);
    vault.updateNav(1);
    assertEq(vault.navCursor(), 1);

    // Bump factors, then resume — must restart the cycle from cursor 0
    mockCalculator.bumpConfigurationVersion();
    uint256 postBumpVersion = mockCalculator.configurationVersion();

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(block.timestamp);
    vm.prank(manager);
    vault.updateNav(1);
    assertEq(vault.navCursor(), 1, "cursor restarted from 0 then advanced to 1");

    // Finish the restarted cycle and verify the finalized snapshot reflects
    // the post-bump version, not the pre-bump one captured on the first batch.
    vm.prank(manager);
    vault.updateNav(1);
    assertEq(vault.navCursor(), 0, "cycle finalized");
    assertEq(
      vault.lastCalculatorConfigurationVersion(),
      postBumpVersion,
      "finalized version must match post-bump snapshot"
    );
  }

  // ─────────────────── setCalculator invalidates lastNav ───────────────

  function test_SetCalculator_InvalidatesLastNav() public {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);
    assertTrue(vault.lastNavUpdate() > 0);

    // Deploy a new compatible calculator
    MockNavCalculator newCalc = new MockNavCalculator();

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.CalculatorUpdated(address(newCalc));
    vm.prank(guardian);
    vault.setCalculator(address(newCalc));

    assertEq(vault.lastNavUpdate(), 0, "lastNavUpdate must be zeroed");
  }

  function test_ApproveDeposit_Reverts_AfterSetCalculator() public {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    MockNavCalculator newCalc = new MockNavCalculator();
    vm.prank(guardian);
    vault.setCalculator(address(newCalc));

    vm.prank(manager);
    // Zeroed lastNavUpdate triggers StaleNav since (block.timestamp - 0) > maxNavAge
    vm.expectRevert(IPortfolioVault.StaleNav.selector);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }
}
