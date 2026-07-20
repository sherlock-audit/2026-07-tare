// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {InvestorWithdrawalResult} from "contracts/interfaces/ILoans.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ACC_INVESTOR_INTEREST_PAID, ACC_INVESTOR_PRINCIPAL_REPAID} from "contracts/interfaces/Accounts.sol";

contract Vault_CollectCashflowsTest is VaultTestBase {
  bytes32 constant REF = bytes32("collect_ref");

  uint64 loanWithCashflow;
  uint64 loanWithCashflow2;

  function setUp() public override {
    super.setUp();

    // Grant PORTFOLIO_MANAGER to manager (base only grants INVESTOR_MANAGER)
    vm.prank(guardian);
    vault.grantRole(portfolioManagerRole, manager);
  }

  // ──────── Helpers ────────

  /** @notice Creates a loan owned by the vault with no withdrawable cashflows */
  function _createVaultLoanWithoutCashflow() internal returns (uint64 id) {
    id = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    _transferLoanToVault(id);
  }

  // ──────── Single Loan ────────

  function test_CollectCashflows_SingleLoan() public {
    loanWithCashflow = _createVaultLoanWithCashflow();
    uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.prank(manager);
    InvestorWithdrawalResult[] memory results = vault.collectCashflows(loanIds, REF);

    uint256 expectedTotal = uint128(DEFAULT_INVESTOR_INTEREST) + uint128(DEFAULT_PRINCIPAL_REPAYMENT);

    assertEq(results.length, 1, "should return 1 result");
    assertEq(results[0].loanId, loanWithCashflow, "loanId mismatch");
    assertEq(results[0].interest, DEFAULT_INVESTOR_INTEREST, "interest mismatch");
    assertEq(results[0].principal, DEFAULT_PRINCIPAL_REPAYMENT, "principal mismatch");
    assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore + expectedTotal, "vault USDC balance mismatch");
  }

  // ──────── Multiple Loans ────────

  function test_CollectCashflows_MultipleLoans() public {
    loanWithCashflow = _createVaultLoanWithCashflow();
    loanWithCashflow2 = _createVaultLoanWithCashflow();
    uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanWithCashflow;
    loanIds[1] = loanWithCashflow2;

    vm.prank(manager);
    InvestorWithdrawalResult[] memory results = vault.collectCashflows(loanIds, REF);

    uint256 expectedPerLoan = uint128(DEFAULT_INVESTOR_INTEREST) + uint128(DEFAULT_PRINCIPAL_REPAYMENT);

    assertEq(results.length, 2, "should return 2 results");
    assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore + expectedPerLoan * 2, "vault USDC balance mismatch");
  }

  // ──────── Zero Withdrawable (no-op) ────────

  function test_CollectCashflows_ZeroWithdrawable() public {
    uint64 loanNoCashflow = _createVaultLoanWithoutCashflow();
    uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanNoCashflow;

    vm.prank(manager);
    InvestorWithdrawalResult[] memory results = vault.collectCashflows(loanIds, REF);

    assertEq(results.length, 1, "should return 1 result");
    assertEq(results[0].interest, 0, "interest should be 0");
    assertEq(results[0].principal, 0, "principal should be 0");
    assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore, "vault balance should not change");
  }

  // ──────── Event Emission ────────

  function test_CollectCashflows_EmitsCashflowsCollectedEvent() public {
    loanWithCashflow = _createVaultLoanWithCashflow();

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.prank(manager);
    // Check event is emitted (can't predict exact results array, so just check topic)
    vm.expectEmit(false, false, false, false);
    emit IPortfolioVault.CashflowsCollected(new InvestorWithdrawalResult[](0));
    vault.collectCashflows(loanIds, REF);
  }

  // ──────── Access Control ────────

  function test_CollectCashflows_Reverts_WhenNotManager() public {
    loanWithCashflow = _createVaultLoanWithCashflow();

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, portfolioManagerRole)
    );
    vm.prank(randomUser);
    vault.collectCashflows(loanIds, REF);
  }

  function test_CollectCashflows_CallableByInvestorManager() public {
    loanWithCashflow = _createVaultLoanWithCashflow();

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    // manager already has INVESTOR_MANAGER from VaultTestBase setUp
    // Revoke PORTFOLIO_MANAGER to verify INVESTOR_MANAGER alone works
    vm.prank(guardian);
    vault.revokeRole(portfolioManagerRole, manager);

    vm.prank(manager);
    vault.collectCashflows(loanIds, REF);
  }

  // ──────── Blocked During NAV Computation ────────

  function test_CollectCashflows_Reverts_WhenNavInProgress() public {
    loanWithCashflow = _createVaultLoanWithCashflow();
    // Create a second loan so NAV computation requires 2 batches
    _createVaultLoanWithCashflow();

    // Start NAV computation but don't finish (process only 1 of 2 loans)
    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    vm.prank(manager);
    vault.updateNav(1);

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.collectCashflows(loanIds, REF);
  }

  // ──────── Loan Account Balances ────────

  function test_CollectCashflows_DecreasesLoanAccountBalances() public {
    loanWithCashflow = _createVaultLoanWithCashflow();

    int128 interestBefore = loans.getLoanAccountBalance(loanWithCashflow, ACC_INVESTOR_INTEREST_PAID);
    int128 principalBefore = loans.getLoanAccountBalance(loanWithCashflow, ACC_INVESTOR_PRINCIPAL_REPAID);

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.prank(manager);
    vault.collectCashflows(loanIds, REF);

    int128 interestAfter = loans.getLoanAccountBalance(loanWithCashflow, ACC_INVESTOR_INTEREST_PAID);
    int128 principalAfter = loans.getLoanAccountBalance(loanWithCashflow, ACC_INVESTOR_PRINCIPAL_REPAID);

    // After withdrawal, the paid accounts should reflect the withdrawal
    assertEq(
      interestAfter - interestBefore,
      DEFAULT_INVESTOR_INTEREST,
      "interest paid account should zero out after withdrawal"
    );
    assertEq(
      principalAfter - principalBefore,
      DEFAULT_PRINCIPAL_REPAYMENT,
      "principal repaid account should zero out after withdrawal"
    );
  }

  // ──────── NAV invalidation ────────

  /// @dev `collectCashflows` mutates idleLiquidity and per-loan ledger state
  /// without bumping the loansNFT ownership nonce, so it must clear
  /// `lastNavUpdate` to force a fresh NAV before the next approval.
  function test_CollectCashflows_InvalidatesNav() public {
    loanWithCashflow = _createVaultLoanWithCashflow();
    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);
    vault.updateNav(NAV_BATCH_SIZE);
    assertGt(vault.lastNavUpdate(), 0, "baseline NAV must be fresh");

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vm.prank(manager);
    vault.collectCashflows(loanIds, REF);

    assertEq(vault.lastNavUpdate(), 0, "collectCashflows must clear lastNavUpdate");
  }

  // ──────── NAV membership enforcement ────────

  /// @dev Cashflows from a loan excluded from NAV would silently inflate NAV via idleLiquidity;
  /// `collectCashflows` must reject any loanId not currently in `_navLoanIds`.
  function test_CollectCashflows_Reverts_WhenLoanNotInNav() public {
    loanWithCashflow = _createVaultLoanWithCashflow();

    vm.prank(manager);
    vault.removeLoansFromNav(_singleLoanArray(loanWithCashflow));

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.LoanNotInNav.selector);
    vault.collectCashflows(loanIds, REF);
  }

  function test_CollectCashflows_Reverts_AtomicallyWhenOneLoanNotInNav() public {
    loanWithCashflow = _createVaultLoanWithCashflow();
    loanWithCashflow2 = _createVaultLoanWithCashflow();

    vm.prank(manager);
    vault.removeLoansFromNav(_singleLoanArray(loanWithCashflow2));

    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanWithCashflow;
    loanIds[1] = loanWithCashflow2;

    uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.LoanNotInNav.selector);
    vault.collectCashflows(loanIds, REF);

    assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore, "no cashflows should have been collected");
  }
}
