// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";

/**
 * @title Vault_PortfolioHoldingsChangedTest
 * @notice Verifies that share-price-sensitive operations (`approveDeposit`,
 * `approveRedemption`) reject a cached NAV after the vault's loan NFT
 * ownership set has changed, until a fresh `updateNav` finalizes against
 * the new holdings.
 */
contract Vault_PortfolioHoldingsChangedTest is VaultTestBase {
  function setUp() public override {
    super.setUp();

    usdc.mint(shareholder1, type(uint128).max);
    vm.prank(shareholder1);
    usdc.approve(address(vault), type(uint256).max);
  }

  function test_ApproveDeposit_Reverts_WhenHoldingsChangedAfterNav() public {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    // Transfer an additional loan into the vault, bumping its ownershipNonce
    uint64 extraLoan = _createActiveLoan(25_000e6);
    _transferLoanToVault(extraLoan);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.PortfolioHoldingsChanged.selector);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  function test_ApproveRedemption_Reverts_WhenHoldingsChangedAfterNav() public {
    uint256 shares = _setupShareholderWithShares(shareholder1, DEFAULT_DEPOSIT_AMOUNT, DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    uint64 extraLoan = _createActiveLoan(25_000e6);
    _transferLoanToVault(extraLoan);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.PortfolioHoldingsChanged.selector);
    vault.approveRedemption(shareholder1, shares);
  }

  function test_Approve_Succeeds_AfterReNav() public {
    _setupInitialNav(DEFAULT_LOAN_VALUATION);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    uint64 extraLoan = _createActiveLoan(25_000e6);
    _transferLoanToVault(extraLoan);

    _refreshNav();

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    assertEq(vault.claimableDepositAssets(shareholder1), DEFAULT_DEPOSIT_AMOUNT);
  }
}
