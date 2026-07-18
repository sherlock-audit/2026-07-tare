// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {ILoansExchange} from "contracts/interfaces/ILoansExchange.sol";
import {ILoans, Roles} from "contracts/interfaces/ILoans.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Vault_PauseTest
 * @notice Verifies that all whenNotPaused functions on PortfolioVault revert with
 * EnforcedPause when the contract is paused.
 */
contract Vault_PauseTest is VaultTestBase {
  function setUp() public override {
    super.setUp();

    // Grant PORTFOLIO_MANAGER to manager
    vm.prank(guardian);
    vault.grantRole(portfolioManagerRole, manager);

    // Investor registers vault as buyer
    vm.prank(investor);
    loans.registerAddress(Roles.Investor, address(vault));

    // Investor approves exchange
    vm.prank(investor);
    loansNFT.setApprovalForAll(address(exchange), true);

    // Fund vault
    usdc.mint(address(vault), uint256(DEFAULT_OFFER_PRICE) * 10);

    // Register loanBuyer in vault's address book
    vm.prank(guardian);
    vault.registerAddress(loanBuyer);

    // Fund loanBuyer
    usdc.mint(loanBuyer, uint256(DEFAULT_OFFER_PRICE) * 10);
    vm.prank(loanBuyer);
    usdc.approve(address(exchange), type(uint256).max);
  }

  // ──────── Helpers ────────

  function _setupShareholderWithShares() internal returns (uint256 shares) {
    return _setupShareholderWithShares(shareholder1, DEFAULT_DEPOSIT_AMOUNT, DEFAULT_LOAN_VALUATION);
  }

  // ──────── requestDeposit ────────

  function test_RequestDeposit_Reverts_WhenPaused() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
    vault.pause();

    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);
  }

  // ──────── approveDeposit ────────

  function test_ApproveDeposit_Reverts_WhenPaused() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vault.pause();

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);
  }

  // ──────── deposit ────────

  function test_Deposit_Reverts_WhenPaused() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vault.pause();

    uint256 claimableAssets = vault.claimableDepositRequest(0, shareholder1);
    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.deposit(claimableAssets, shareholder1, shareholder1);
  }

  // ──────── mint ────────

  function test_Mint_Reverts_WhenPaused() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vault.pause();

    uint256 claimableShares = vault.claimableDepositShares(shareholder1);
    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.mint(claimableShares, shareholder1, shareholder1);
  }

  // ──────── cancelDepositRequest ────────

  function test_CancelDeposit_Reverts_WhenPaused() public {
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vault.pause();

    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.cancelDepositRequest(shareholder1, shareholder1);
  }

  // ──────── requestRedeem ────────

  function test_RequestRedeem_Reverts_WhenPaused() public {
    _setupShareholderWithShares();
    vault.pause();

    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.requestRedeem(DEFAULT_REDEEM_SHARES, shareholder1, shareholder1);
  }

  // ──────── approveRedemption ────────

  function test_ApproveRedemption_Reverts_WhenPaused() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vault.pause();

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.approveRedemption(shareholder1, shares);
  }

  // ──────── redeem ────────

  function test_Redeem_Reverts_WhenPaused() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    vault.pause();

    uint256 claimableShares = vault.maxRedeem(shareholder1);
    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.redeem(claimableShares, shareholder1, shareholder1);
  }

  // ──────── withdraw ────────

  function test_Withdraw_Reverts_WhenPaused() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    vault.pause();

    uint256 claimableAssets = vault.maxWithdraw(shareholder1);
    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.withdraw(claimableAssets, shareholder1, shareholder1);
  }

  // ──────── cancelRedeemRequest ────────

  function test_CancelRedeem_Reverts_WhenPaused() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vault.pause();

    vm.prank(shareholder1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.cancelRedeemRequest(shareholder1, shareholder1);
  }

  // ──────── collectCashflows ────────

  function test_CollectCashflows_Reverts_WhenPaused() public {
    uint64 loanWithCashflow = _createVaultLoanWithCashflow();

    vault.pause();

    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanWithCashflow;

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.collectCashflows(loanIds, bytes32("ref"));
  }

  // ──────── updateNav ────────

  function test_UpdateNav_Reverts_WhenPaused() public {
    _createVaultLoanWithCashflow();
    usdc.mint(address(vault), INITIAL_ASSETS);
    mockCalculator.setNextValuation(DEFAULT_LOAN_VALUATION);

    vault.pause();

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.updateNav(NAV_BATCH_SIZE);
  }

  // ──────── acceptSaleOffer ────────

  function test_AcceptSaleOffer_Reverts_WhenPaused() public {
    (uint64 offerId, ) = _createOfferForVault();

    vault.pause();

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.acceptSaleOffer(offerId);
  }

  // ──────── createSaleOffer ────────

  function test_CreateSaleOffer_Reverts_WhenPaused() public {
    uint64 loanId_ = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    _transferLoanToVault(loanId_);

    vault.pause();

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.createSaleOffer(loanBuyer, DEFAULT_OFFER_PRICE, _deadline(), _singleLoanArray(loanId_));
  }

  // ──────── cancelSaleOffer ────────

  function test_CancelSaleOffer_Reverts_WhenPaused() public {
    (uint64 offerId, ) = _createSaleOfferFromVault();

    vault.pause();

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.cancelSaleOffer(offerId);
  }

  // ──────── transferLoans ────────

  function test_TransferLoans_Reverts_WhenPaused() public {
    uint64 loanId_ = _createActiveLoan(DEFAULT_TEST_PRINCIPAL);
    _transferLoanToVault(loanId_);

    vault.pause();

    vm.prank(manager);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vault.transferLoans(_singleLoanArray(loanId_), loanBuyer);
  }

  // ──────── max* views reflect the paused state ────────

  function test_MaxDepositAndMint_ReturnZero_WhenPaused() public {
    _setupInitialNav();
    _fundShareholder(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    vm.prank(shareholder1);
    vault.requestDeposit(DEFAULT_DEPOSIT_AMOUNT, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveDeposit(shareholder1, DEFAULT_DEPOSIT_AMOUNT);

    assertGt(vault.maxDeposit(shareholder1), 0, "maxDeposit should be non-zero before pause");
    assertGt(vault.maxMint(shareholder1), 0, "maxMint should be non-zero before pause");

    vault.pause();

    assertEq(vault.maxDeposit(shareholder1), 0, "maxDeposit should be 0 when paused");
    assertEq(vault.maxMint(shareholder1), 0, "maxMint should be 0 when paused");
  }

  function test_MaxWithdrawAndRedeem_ReturnZero_WhenPaused() public {
    uint256 shares = _setupShareholderWithShares();

    vm.prank(shareholder1);
    vault.requestRedeem(shares, shareholder1, shareholder1);

    vm.prank(manager);
    vault.approveRedemption(shareholder1, shares);

    assertGt(vault.maxWithdraw(shareholder1), 0, "maxWithdraw should be non-zero before pause");
    assertGt(vault.maxRedeem(shareholder1), 0, "maxRedeem should be non-zero before pause");

    vault.pause();

    assertEq(vault.maxWithdraw(shareholder1), 0, "maxWithdraw should be 0 when paused");
    assertEq(vault.maxRedeem(shareholder1), 0, "maxRedeem should be 0 when paused");
  }
}
