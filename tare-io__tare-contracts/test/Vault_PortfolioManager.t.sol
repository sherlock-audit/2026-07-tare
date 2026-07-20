// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultTestBase} from "./VaultTestBase.t.sol";
import {IPortfolioVault} from "contracts/interfaces/IPortfolioVault.sol";
import {ILoansExchange, SaleOffer} from "contracts/interfaces/ILoansExchange.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ILoans, LoanStatus, Roles} from "contracts/interfaces/ILoans.sol";
import {ILoansAuth} from "contracts/misc/interfaces/ILoansAuth.sol";
import {NonReceiverContract} from "test/mocks/NonReceiverContract.sol";

/**
 * @title Vault_PortfolioManagerTestBase
 * @notice Shared setup for all portfolio manager function tests. Grants PORTFOLIO_MANAGER
 * to the manager, sets up seller/buyer relationships for exchange operations, and
 * provides helpers for creating offers and transferring loans to the vault.
 */
abstract contract Vault_PortfolioManagerTestBase is VaultTestBase {
  int128 internal constant LOAN_PRINCIPAL = 50_000e6;
  uint128 internal constant OFFER_PRICE = 45_000e6;

  function setUp() public virtual override {
    super.setUp();

    // Grant PORTFOLIO_MANAGER to the manager
    vm.prank(guardian);
    vault.grantRole(portfolioManagerRole, manager);

    // Investor (default loan creator) registers vault as buyer in their address book
    vm.prank(investor);
    loans.registerAddress(Roles.Investor, address(vault));

    // Investor approves exchange for all NFTs
    vm.prank(investor);
    loansNFT.setApprovalForAll(address(exchange), true);

    // Fund vault with USDC for purchasing loans
    usdc.mint(address(vault), uint256(OFFER_PRICE) * 10);
    // Vault needs to approve exchange to pull USDC (handled by acceptSaleOffer internally via forceApprove)

    // Register loanBuyer in vault's address book (address(this) holds ADMIN_ROLE)
    vault.registerAddress(loanBuyer);

    // Register investor (seller in vault-as-buyer flows) in vault's address book
    vault.registerAddress(investor);

    // Fund loanBuyer with USDC and approve exchange
    usdc.mint(loanBuyer, uint256(OFFER_PRICE) * 10);
    vm.prank(loanBuyer);
    usdc.approve(address(exchange), type(uint256).max);

    // loanBuyer whitelists the vault (seller side) so it can accept offers from the vault
    vm.prank(loanBuyer);
    loans.registerAddress(Roles.Investor, address(vault));
  }

  /** @notice Starts a NAV computation without finalizing it (for blocking tests) */
  function _startNavComputation() internal {
    // Need at least 2 loans so a batch of 1 doesn't finalize
    uint64 idA = _createActiveLoan(25_000e6);
    uint64 idB = _createActiveLoan(25_000e6);
    _transferLoanToVault(idA);
    _transferLoanToVault(idB);
    mockCalculator.setNextValuation(10_000e6);
    vm.prank(manager);
    vault.updateNav(1); // Process only 1 of 2 — navStart is now set
    assertTrue(vault.navStart() > 0, "navStart should be set");
  }

  /** @notice Creates a sale offer from the vault, locking NFTs to the exchange */
  function _createSaleOfferFromVault() internal override returns (uint64 offerId, uint64 loanId_) {
    return _createSaleOfferFromVault(LOAN_PRINCIPAL, OFFER_PRICE);
  }

  /** @notice Creates an offer to sell a loan to the vault */
  function _createOfferForVault() internal override returns (uint64 offerId, uint64 loanId_) {
    return _createOfferForVault(LOAN_PRINCIPAL, OFFER_PRICE);
  }
}

// ============================================================================
// acceptSaleOffer
// ============================================================================

contract Vault_AcceptSaleOfferTest is Vault_PortfolioManagerTestBase {
  function test_AcceptSaleOffer_TransfersNFTAndPaysUSDC() public {
    (uint64 offerId, uint64 loanId_) = _createOfferForVault();
    uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
    uint256 sellerUsdcBefore = usdc.balanceOf(investor);

    vm.prank(manager);
    vault.acceptSaleOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), address(vault), "vault should own NFT");
    assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore - uint256(OFFER_PRICE), "vault USDC decreased");
    assertEq(usdc.balanceOf(investor), sellerUsdcBefore + uint256(OFFER_PRICE), "seller USDC increased");
    assertTrue(vault.isInNav(loanId_), "acquired loan must be admitted into NAV");
    assertEq(vault.navLoanCount(), 1, "curated list grew by one");
  }

  function test_AcceptSaleOffer_AdmitsAllLoansInOffer() public {
    // Build a multi-loan offer so the auto-admit loop is exercised over length > 1.
    uint64 a = _createActiveLoan(LOAN_PRINCIPAL);
    uint64 b = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory ids = new uint64[](2);
    ids[0] = a;
    ids[1] = b;
    vm.prank(investor);
    uint64 offerId = exchange.createOffer(address(vault), 0, _deadline(), ids);

    vm.prank(manager);
    vault.acceptSaleOffer(offerId);

    assertTrue(vault.isInNav(a));
    assertTrue(vault.isInNav(b));
    assertEq(vault.navLoanCount(), 2, "both loans admitted");
  }

  function test_AcceptSaleOffer_WorksWithZeroPrice() public {
    (uint64 offerId, uint64 loanId_) = _createOfferForVault(LOAN_PRINCIPAL, 0);
    uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

    vm.prank(manager);
    vault.acceptSaleOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), address(vault), "vault should own NFT");
    assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore, "vault USDC unchanged");
  }

  function test_AcceptSaleOffer_Reverts_WhenNotPortfolioManager() public {
    (uint64 offerId, ) = _createOfferForVault();

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        shareholder1,
        portfolioManagerRole
      )
    );
    vault.acceptSaleOffer(offerId);
  }

  function test_AcceptSaleOffer_Reverts_WhenNavInProgress() public {
    _startNavComputation();

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.acceptSaleOffer(1);
  }

  function test_AcceptSaleOffer_Reverts_WhenPendingDepositsReduceIdleLiquidity() public {
    // Set up NAV so approveDeposit works and vault has a known state
    _setupInitialNav();

    // Shareholder deposits USDC — these become pending and earmarked
    uint256 depositAmount = usdc.balanceOf(address(vault));
    _fundShareholder(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    // Idle liquidity = balance - pending deposits - claimable redeems.
    // Price the offer 1 unit above idle so acceptSaleOffer reverts on the
    // InsufficientLiquidity check.
    uint256 vaultBalance = usdc.balanceOf(address(vault));
    uint256 pendingDeposits = vault.totalPendingDepositAssets();
    (uint64 offerId, ) = _createOfferForVault(LOAN_PRINCIPAL, uint128(vaultBalance - pendingDeposits + 1));

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.acceptSaleOffer(offerId);
  }

  function test_AcceptSaleOffer_Reverts_WhenClaimableRedeemsReduceIdleLiquidity() public {
    _setupInitialNav();

    // Shareholder gets shares via deposit flow, then requests redemption
    uint256 depositAmount = 100_000e6;
    _fundShareholder(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.deposit(depositAmount, shareholder1, shareholder1);

    // Refresh NAV after deposit
    _refreshNav();

    // Request and approve redemption — this earmarks assets as claimable
    uint256 redeemShares = shareToken.balanceOf(shareholder1);
    vm.prank(shareholder1);
    shareToken.approve(address(vault), redeemShares);
    vm.prank(shareholder1);
    vault.requestRedeem(redeemShares, shareholder1, shareholder1);
    _refreshNav();
    vm.prank(manager);
    vault.approveRedemption(shareholder1, redeemShares);

    // Now totalClaimableRedeemAssets is non-zero, reducing idle liquidity
    uint256 vaultBalance = usdc.balanceOf(address(vault));
    uint256 pendingDeposits = vault.totalPendingDepositAssets();
    uint256 claimableRedeems = vault.totalClaimableRedeemAssets();
    uint256 idleLiquidity = vaultBalance - pendingDeposits - claimableRedeems;

    // Create an offer priced just above idle liquidity
    (uint64 offerId, ) = _createOfferForVault(LOAN_PRINCIPAL, uint128(idleLiquidity + 1));

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.acceptSaleOffer(offerId);
  }

  function test_AcceptSaleOffer_Succeeds_WhenPriceEqualsIdleLiquidity() public {
    _setupInitialNav();

    uint256 vaultBalance = usdc.balanceOf(address(vault));
    uint256 pendingDeposits = vault.totalPendingDepositAssets();
    uint256 claimableRedeems = vault.totalClaimableRedeemAssets();
    uint256 idleLiquidity = vaultBalance - pendingDeposits - claimableRedeems;

    // Create an offer priced exactly at idle liquidity
    (uint64 offerId, uint64 loanId_) = _createOfferForVault(LOAN_PRINCIPAL, uint128(idleLiquidity));

    vm.prank(manager);
    vault.acceptSaleOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), address(vault), "vault should own NFT");
  }

  function test_AcceptSaleOffer_Reverts_WhenExchangeFailsToTransferNFT() public {
    // Real offer is created so getOffer / price / approval paths run normally.
    (uint64 offerId, uint64 loanId_) = _createOfferForVault();

    // Stub acceptOffer to a no-op so the NFT is never transferred to the vault.
    vm.mockCall(address(exchange), abi.encodeWithSelector(ILoansExchange.acceptOffer.selector, offerId), "");

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.LoanNotOwned.selector);
    vault.acceptSaleOffer(offerId);

    vm.clearMockedCalls();

    // Sanity: ownership did not silently change to the vault.
    assertTrue(loansNFT.ownerOf(loanId_) != address(vault), "vault must not own the NFT after revert");
    assertFalse(vault.isInNav(loanId_), "loan must not be admitted into NAV after revert");
  }
}

// ============================================================================
// createSaleOffer
// ============================================================================

contract Vault_CreateSaleOfferTest is Vault_PortfolioManagerTestBase {
  function test_CreateSaleOffer_LocksNFTAndReturnsOfferId() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    _transferLoanToVault(loanId_);

    vm.prank(manager);
    uint64 offerId = vault.createSaleOffer(loanBuyer, OFFER_PRICE, _deadline(), _singleLoanArray(loanId_));

    assertEq(offerId, 1, "offerId should be 1");
    assertEq(loansNFT.ownerOf(loanId_), address(vault), "vault should still own NFT");
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(exchange), "NFT should be locked to exchange");

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.seller, address(vault));
    assertEq(offer.buyer, loanBuyer);
    assertEq(offer.price, OFFER_PRICE);
    assertEq(offer.loanIds.length, 1);
    assertEq(offer.loanIds[0], loanId_);
  }

  function test_CreateSaleOffer_MultipleLoans() public {
    uint64 loanId1 = _createActiveLoan(25_000e6);
    uint64 loanId2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(loanId1);
    _transferLoanToVault(loanId2);

    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanId1;
    loanIds[1] = loanId2;

    vm.prank(manager);
    uint64 offerId = vault.createSaleOffer(loanBuyer, OFFER_PRICE, _deadline(), loanIds);

    assertEq(loansNFT.ownerOf(loanId1), address(vault), "vault still owns NFT 1");
    assertEq(loansNFT.ownerOf(loanId2), address(vault), "vault still owns NFT 2");
    assertEq(loansNFT.getLocked(uint256(loanId1)), address(exchange), "NFT 1 locked");
    assertEq(loansNFT.getLocked(uint256(loanId2)), address(exchange), "NFT 2 locked");

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.loanIds.length, 2);
  }

  function test_CreateSaleOffer_Reverts_WhenNotPortfolioManager() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    _transferLoanToVault(loanId_);

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        shareholder1,
        portfolioManagerRole
      )
    );
    vault.createSaleOffer(loanBuyer, OFFER_PRICE, _deadline(), _singleLoanArray(loanId_));
  }
}

// ============================================================================
// cancelSaleOffer
// ============================================================================

contract Vault_CancelSaleOfferTest is Vault_PortfolioManagerTestBase {
  function test_CancelSaleOffer_UnlocksNFTs() public {
    (uint64 offerId, uint64 loanId_) = _createSaleOfferFromVault();

    vm.prank(manager);
    vault.cancelSaleOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), address(vault), "NFT should still be in vault");
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(0), "NFT should be unlocked");
  }

  function test_CancelSaleOffer_Reverts_WhenNotPortfolioManager() public {
    (uint64 offerId, ) = _createSaleOfferFromVault();

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        shareholder1,
        portfolioManagerRole
      )
    );
    vault.cancelSaleOffer(offerId);
  }
}

// ============================================================================
// transferLoans
// ============================================================================

contract Vault_TransferLoansTest is Vault_PortfolioManagerTestBase {
  function test_TransferLoans_TransfersNFTToRecipient() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    _transferLoanToVault(loanId_);

    vm.prank(manager);
    vault.transferLoans(_singleLoanArray(loanId_), loanBuyer);

    assertEq(loansNFT.ownerOf(loanId_), loanBuyer, "loanBuyer should own NFT");
  }

  function test_TransferLoans_MultipleLoans() public {
    uint64 loanId1 = _createActiveLoan(25_000e6);
    uint64 loanId2 = _createActiveLoan(25_000e6);
    _transferLoanToVault(loanId1);
    _transferLoanToVault(loanId2);

    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanId1;
    loanIds[1] = loanId2;

    vm.prank(manager);
    vault.transferLoans(loanIds, loanBuyer);

    assertEq(loansNFT.ownerOf(loanId1), loanBuyer);
    assertEq(loansNFT.ownerOf(loanId2), loanBuyer);
  }

  function test_TransferLoans_Succeeds_WhenRecipientIsNonReceiverContract() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    _transferLoanToVault(loanId_);

    NonReceiverContract nonReceiver = new NonReceiverContract();

    vm.prank(manager);
    vault.transferLoans(_singleLoanArray(loanId_), address(nonReceiver));

    assertEq(loansNFT.ownerOf(loanId_), address(nonReceiver));
  }

  function test_TransferLoans_Reverts_WhenNotPortfolioManager() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    _transferLoanToVault(loanId_);

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        shareholder1,
        portfolioManagerRole
      )
    );
    vault.transferLoans(_singleLoanArray(loanId_), loanBuyer);
  }

  function test_TransferLoans_Reverts_WhenNavInProgress() public {
    _startNavComputation();

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.transferLoans(_singleLoanArray(1), loanBuyer);
  }
}

// ============================================================================
// registerAddress / unregisterAddress
// ============================================================================

contract Vault_AddressBookTest is Vault_PortfolioManagerTestBase {
  function test_RegisterAddress_RegistersInvestorRole() public {
    address buyer = makeAddr("buyer");
    vm.prank(manager);
    vault.registerAddress(buyer);

    assertTrue(
      ILoansAuth(address(loans)).isRegisteredForRole(address(vault), Roles.Investor, buyer),
      "buyer should be registered as investor"
    );
  }

  function test_UnregisterAddress_ClearsInvestorRole() public {
    address buyer = makeAddr("buyer");
    vm.prank(manager);
    vault.registerAddress(buyer);
    vm.prank(manager);
    vault.unregisterAddress(buyer);

    assertFalse(
      ILoansAuth(address(loans)).isRegisteredForRole(address(vault), Roles.Investor, buyer),
      "buyer should be unregistered"
    );
  }

  function test_RegisterAddress_AdminCanRegister() public {
    address buyer = makeAddr("buyer");
    // address(this) holds ADMIN_ROLE (granted in VaultTestBase)
    vault.registerAddress(buyer);

    assertTrue(ILoansAuth(address(loans)).isRegisteredForRole(address(vault), Roles.Investor, buyer));
  }

  function test_RegisterAddress_GuardianCanRegister() public {
    address buyer = makeAddr("buyer");
    vm.prank(guardian);
    vault.registerAddress(buyer);

    assertTrue(ILoansAuth(address(loans)).isRegisteredForRole(address(vault), Roles.Investor, buyer));
  }

  function test_RegisterAddress_Reverts_WhenUnauthorized() public {
    vm.prank(investor);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, investor, portfolioManagerRole)
    );
    vault.registerAddress(makeAddr("buyer"));
  }

  function test_UnregisterAddress_Reverts_WhenUnauthorized() public {
    vm.prank(investor);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, investor, portfolioManagerRole)
    );
    vault.unregisterAddress(makeAddr("buyer"));
  }
}

// ============================================================================
// fundLoan
// ============================================================================

contract Vault_FundLoanTest is Vault_PortfolioManagerTestBase {
  bytes32 internal constant FUND_REF = bytes32("vault_fund");

  function _assertFundLoanOutcome(uint64 loanId_, int128 amount, LoanStatus expectedStatus) internal {
    _assertFundLoanOutcome(loanId_, amount, timeNow, expectedStatus);
  }

  function _assertFundLoanOutcome(uint64 loanId_, int128 amount, uint48 timestamp, LoanStatus expectedStatus) internal {
    uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
    uint256 loansUsdcBefore = usdc.balanceOf(address(loans));
    uint128 entryCountBefore = loans.entryCount(loanId_);

    vm.prank(manager);
    vault.fundLoan(loanId_, amount, timestamp, FUND_REF);

    (LoanStatus status, uint48 updatedAt, , , ) = loans.data(loanId_);
    assertEq(uint8(status), uint8(expectedStatus), "unexpected loan status");
    assertEq(updatedAt, timestamp, "unexpected loan updatedAt");
    assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore - uint256(int256(amount)));
    assertEq(usdc.balanceOf(address(loans)), loansUsdcBefore + uint256(int256(amount)));
    assertEq(loans.entryCount(loanId_), entryCountBefore + 1, "funding should create one ledger entry");
  }

  function test_FundLoan_FundsLoanAndTransitionsToFullyFunded() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);
    uint128 expectedEntryIndex = (uint128(loanId_) << 64) | uint128(loans.entryCount(loanId_) + 1);

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.LoanFunded(loanId_, LOAN_PRINCIPAL, expectedEntryIndex, FUND_REF);

    _assertFundLoanOutcome(loanId_, LOAN_PRINCIPAL, LoanStatus.FullyFunded);
    assertTrue(vault.isInNav(loanId_), "funded loan must be admitted into NAV");
  }

  function test_FundLoan_Succeeds_WhenAmountEqualsIdleLiquidity() public {
    _setupInitialNav();

    uint256 idleLiquidity = usdc.balanceOf(address(vault)) -
      vault.totalPendingDepositAssets() -
      vault.totalClaimableRedeemAssets();
    assertGt(idleLiquidity, 0, "idle liquidity should be positive");
    assertLe(idleLiquidity, uint256(int256(type(int128).max)), "idle liquidity must fit int128");

    int128 amount = int128(int256(idleLiquidity));
    uint64 loanId_ = _createLoanForVaultInvestor(amount);

    _assertFundLoanOutcome(loanId_, amount, LoanStatus.FullyFunded);
  }

  function testFuzz_FundLoan_Succeeds_WhenAmountAtMostIdleLiquidity(uint96 rawAmount) public {
    _setupInitialNav();
    uint256 idleLiquidity = usdc.balanceOf(address(vault)) -
      vault.totalPendingDepositAssets() -
      vault.totalClaimableRedeemAssets();
    uint256 maxFundable = idleLiquidity;
    uint256 int128Max = uint256(int256(type(int128).max));
    if (int128Max < maxFundable) maxFundable = int128Max;
    vm.assume(maxFundable > 0);

    int128 amount = int128(int256(bound(uint256(rawAmount), 1, maxFundable)));
    uint64 loanId_ = _createLoanForVaultInvestor(amount);

    _assertFundLoanOutcome(loanId_, amount, LoanStatus.FullyFunded);
  }

  function test_FundLoan_Reverts_WhenNotPortfolioManager() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(shareholder1);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        shareholder1,
        portfolioManagerRole
      )
    );
    vault.fundLoan(loanId_, LOAN_PRINCIPAL, timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenNavInProgress() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);
    _startNavComputation();

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.NavComputationInProgress.selector);
    vault.fundLoan(loanId_, LOAN_PRINCIPAL, timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenAmountIsNonPositive() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    vault.fundLoan(loanId_, 0, timeNow, FUND_REF);

    vm.prank(manager);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    vault.fundLoan(loanId_, -1, timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenVaultIsNotLoanNftOwner() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vault.transferLoans(_singleLoanArray(loanId_), loanBuyer);

    vm.prank(manager);
    vm.expectRevert(ILoans.Unauthorized.selector);
    vault.fundLoan(loanId_, LOAN_PRINCIPAL, timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenAmountExceedsCommitment() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    vault.fundLoan(loanId_, LOAN_PRINCIPAL + 1, timeNow, FUND_REF);
  }

  function test_FundLoan_ExactApproval_LeavesNoResidualAllowance() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vault.fundLoan(loanId_, LOAN_PRINCIPAL, timeNow, FUND_REF);

    assertEq(usdc.allowance(address(vault), address(loans)), 0, "no leftover allowance expected");
  }

  function test_FundLoan_UsesProvidedTimestamp() public {
    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);
    uint48 customTimestamp = timeNow + 123;

    _assertFundLoanOutcome(loanId_, LOAN_PRINCIPAL, customTimestamp, LoanStatus.FullyFunded);
  }

  function testFuzz_FundLoan_Reverts_WhenAmountExceedsIdleLiquidity(uint256 overBy) public {
    _setupInitialNav();

    uint256 depositAmount = DEFAULT_DEPOSIT_AMOUNT;
    _fundShareholder(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    uint256 idleLiquidity = usdc.balanceOf(address(vault)) -
      vault.totalPendingDepositAssets() -
      vault.totalClaimableRedeemAssets();

    overBy = bound(overBy, 1, uint256(int256(type(int128).max)) - idleLiquidity);
    int128 amount = int128(int256(idleLiquidity + overBy));

    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.fundLoan(loanId_, amount, timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenPendingDepositsConsumeIdleLiquidity() public {
    _setupInitialNav();

    uint256 depositAmount = DEFAULT_DEPOSIT_AMOUNT;
    _fundShareholder(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    uint256 vaultBalance = usdc.balanceOf(address(vault));
    uint256 pendingDeposits = vault.totalPendingDepositAssets();
    uint256 claimableRedeems = vault.totalClaimableRedeemAssets();
    uint256 idleLiquidity = vaultBalance - pendingDeposits - claimableRedeems;

    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.fundLoan(loanId_, int128(int256(idleLiquidity + 1)), timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenClaimableRedeemsConsumeIdleLiquidity() public {
    _setupInitialNav();

    uint256 depositAmount = DEFAULT_DEPOSIT_AMOUNT;
    _fundShareholder(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);
    vm.prank(manager);
    vault.approveDeposit(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.deposit(depositAmount, shareholder1, shareholder1);

    _refreshNav();

    uint256 redeemShares = shareToken.balanceOf(shareholder1);
    vm.prank(shareholder1);
    shareToken.approve(address(vault), redeemShares);
    vm.prank(shareholder1);
    vault.requestRedeem(redeemShares, shareholder1, shareholder1);
    _refreshNav();
    vm.prank(manager);
    vault.approveRedemption(shareholder1, redeemShares);

    uint256 vaultBalance = usdc.balanceOf(address(vault));
    uint256 pendingDeposits = vault.totalPendingDepositAssets();
    uint256 claimableRedeems = vault.totalClaimableRedeemAssets();
    uint256 idleLiquidity = vaultBalance - pendingDeposits - claimableRedeems;

    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.fundLoan(loanId_, int128(int256(idleLiquidity + 1)), timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenReservedAssetsExceedBalance() public {
    _setupInitialNav();

    uint256 baseBalance = usdc.balanceOf(address(vault));
    _fundShareholder(shareholder1, baseBalance);
    vm.prank(shareholder1);
    vault.requestDeposit(baseBalance, shareholder1, shareholder1);

    uint256 pendingDeposits = vault.totalPendingDepositAssets();
    uint256 rescueAmount = usdc.balanceOf(address(vault)) - pendingDeposits + 1;

    vm.prank(guardian);
    vault.rescueERC20Tokens(address(usdc), rescueAmount);

    uint256 reservedAssets = vault.totalPendingDepositAssets() + vault.totalClaimableRedeemAssets();
    uint256 balance = usdc.balanceOf(address(vault));
    assertGt(reservedAssets, balance, "reserved assets should exceed balance");

    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.fundLoan(loanId_, 1, timeNow, FUND_REF);
  }

  function test_FundLoan_Reverts_WhenReservedAssetsEqualBalance() public {
    _setupInitialNav();

    uint256 initialBalance = usdc.balanceOf(address(vault));
    vm.prank(guardian);
    vault.rescueERC20Tokens(address(usdc), initialBalance);

    uint256 depositAmount = DEFAULT_DEPOSIT_AMOUNT;
    _fundShareholder(shareholder1, depositAmount);
    vm.prank(shareholder1);
    vault.requestDeposit(depositAmount, shareholder1, shareholder1);

    uint256 reservedAssets = vault.totalPendingDepositAssets() + vault.totalClaimableRedeemAssets();
    uint256 balance = usdc.balanceOf(address(vault));
    assertEq(reservedAssets, balance, "reserved assets should equal balance");

    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.fundLoan(loanId_, 1, timeNow, FUND_REF);
  }

  /// @dev `fundLoan` is NAV-preserving only when the calculator's portfolioFactor
  /// is 1e18; under any discount, moving idle USDC into a loan position changes
  /// the cached NAV without bumping the loansNFT ownership nonce. The function
  /// must clear `lastNavUpdate` so the next approval prices against fresh inputs.
  function test_FundLoan_InvalidatesNav() public {
    _setupInitialNav();
    assertGt(vault.lastNavUpdate(), 0, "baseline NAV must be fresh");

    uint64 loanId_ = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavInvalidated();
    vm.prank(manager);
    vault.fundLoan(loanId_, LOAN_PRINCIPAL, timeNow, FUND_REF);

    assertEq(vault.lastNavUpdate(), 0, "fundLoan must clear lastNavUpdate");
  }

  // -- fundLoans (batch) --

  function _twoLoanIds(uint64 a, uint64 b) internal pure returns (uint64[] memory ids) {
    ids = new uint64[](2);
    ids[0] = a;
    ids[1] = b;
  }

  function _twoAmounts(int128 a, int128 b) internal pure returns (int128[] memory amts) {
    amts = new int128[](2);
    amts[0] = a;
    amts[1] = b;
  }

  function test_FundLoans_FundsMultipleLoansInOneTx() public {
    int128 amountA = LOAN_PRINCIPAL;
    int128 amountB = LOAN_PRINCIPAL / 2;
    uint64 loanA = _createLoanForVaultInvestor(amountA);
    uint64 loanB = _createLoanForVaultInvestor(amountB);

    uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
    uint256 loansUsdcBefore = usdc.balanceOf(address(loans));

    vm.prank(manager);
    vault.fundLoans(_twoLoanIds(loanA, loanB), _twoAmounts(amountA, amountB), timeNow, FUND_REF);

    (LoanStatus statusA, , , , ) = loans.data(loanA);
    (LoanStatus statusB, , , , ) = loans.data(loanB);
    assertEq(uint8(statusA), uint8(LoanStatus.FullyFunded), "loanA must be FullyFunded");
    assertEq(uint8(statusB), uint8(LoanStatus.FullyFunded), "loanB must be FullyFunded");

    uint256 totalAmount = uint256(int256(amountA)) + uint256(int256(amountB));
    assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore - totalAmount, "vault USDC must decrease by sum");
    assertEq(usdc.balanceOf(address(loans)), loansUsdcBefore + totalAmount, "loans USDC must increase by sum");
    assertTrue(vault.isInNav(loanA), "loanA must be admitted into NAV");
    assertTrue(vault.isInNav(loanB), "loanB must be admitted into NAV");
    assertEq(usdc.allowance(address(vault), address(loans)), 0, "no leftover allowance expected");
    assertEq(vault.lastNavUpdate(), 0, "fundLoans must clear lastNavUpdate");
  }

  function test_FundLoans_Reverts_WhenLoanIdsEmpty() public {
    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.ZeroAmount.selector);
    vault.fundLoans(new uint64[](0), new int128[](0), timeNow, FUND_REF);
  }

  function test_FundLoans_Reverts_WhenLengthsMismatch() public {
    uint64 loanA = _createLoanForVaultInvestor(LOAN_PRINCIPAL);
    uint64 loanB = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    int128[] memory amounts = new int128[](1);
    amounts[0] = LOAN_PRINCIPAL;

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.LengthMismatch.selector);
    vault.fundLoans(_twoLoanIds(loanA, loanB), amounts, timeNow, FUND_REF);
  }

  function test_FundLoans_Reverts_WhenSumExceedsIdleLiquidity() public {
    _setupInitialNav();

    uint256 idleLiquidity = usdc.balanceOf(address(vault)) -
      vault.totalPendingDepositAssets() -
      vault.totalClaimableRedeemAssets();
    // Split idle liquidity across two loans such that the sum overshoots by 1 wei.
    int128 amountA = int128(int256(idleLiquidity / 2 + 1));
    int128 amountB = int128(int256(idleLiquidity / 2 + 1));
    uint64 loanA = _createLoanForVaultInvestor(amountA);
    uint64 loanB = _createLoanForVaultInvestor(amountB);

    vm.prank(manager);
    vm.expectRevert(IPortfolioVault.InsufficientLiquidity.selector);
    vault.fundLoans(_twoLoanIds(loanA, loanB), _twoAmounts(amountA, amountB), timeNow, FUND_REF);
  }

  function test_FundLoans_Reverts_AtomicallyWhenOneAmountIsNonPositive() public {
    uint64 loanA = _createLoanForVaultInvestor(LOAN_PRINCIPAL);
    uint64 loanB = _createLoanForVaultInvestor(LOAN_PRINCIPAL);

    vm.prank(manager);
    vm.expectRevert(ILoans.InvalidAmount.selector);
    vault.fundLoans(_twoLoanIds(loanA, loanB), _twoAmounts(LOAN_PRINCIPAL, 0), timeNow, FUND_REF);

    // Neither loan funded.
    (LoanStatus statusA, , , , ) = loans.data(loanA);
    (LoanStatus statusB, , , , ) = loans.data(loanB);
    assertEq(uint8(statusA), uint8(LoanStatus.Created), "loanA must remain unfunded on atomic revert");
    assertEq(uint8(statusB), uint8(LoanStatus.Created), "loanB must remain unfunded on atomic revert");
  }
}

// ============================================================================
// NAV restart on exchange-driven settlement
// ============================================================================

/**
 * @notice Integration test for the ownership-nonce restart invariant.
 * @dev Exercises the real attack path that motivated the fix: the vault lists
 * one of its loans for sale, a NAV cycle begins, and an external buyer accepts
 * the offer directly via `LoansExchange.acceptOffer` (bypassing any vault
 * `_requireIdleNav` check). The next `updateNav` call must restart and
 * finalize a NAV that reflects the post-settlement portfolio + cash.
 */
contract Vault_NavRestartOnExchangeSettlementTest is Vault_PortfolioManagerTestBase {
  // Realistic mid-size loans with distinct face values. Distinct valuations
  // are essential: they let the test assert that *without* the fix the
  // finalized NAV would have used the sold loan's valuation instead of the
  // surviving loan's, materially mispricing shares.
  int128 internal constant LOAN_PRINCIPAL_A = 250_000e6;
  int128 internal constant LOAN_PRINCIPAL_B = 180_000e6;
  uint256 internal constant LOAN_VALUATION_A = 245_000e6;
  uint256 internal constant LOAN_VALUATION_B = 175_000e6;
  uint128 internal constant SALE_PRICE = 240_000e6;

  function test_UpdateNav_RestartsAndFinalizes_WhenBuyerAcceptsOfferMidCycle() public {
    // Vault acquires 2 loan NFTs.
    uint64 loanIdA = _createActiveLoan(LOAN_PRINCIPAL_A);
    uint64 loanIdB = _createActiveLoan(LOAN_PRINCIPAL_B);
    _transferLoanToVault(loanIdA);
    _transferLoanToVault(loanIdB);

    // Vault lists loanIdA for sale (the loan that will be processed in the
    // first batch). Selling the *already-processed* token is the canonical
    // trigger for the index-shift bug: ERC721Enumerable swap-and-pop replaces
    // loanIdA at index 0 with loanIdB, the persistent navCursor stays at 1,
    // and on the next batch the finalize branch fires with pendingNav still
    // holding the sold loan's valuation — silently skipping loanIdB.
    vm.prank(manager);
    uint64 offerId = vault.createSaleOffer(loanBuyer, SALE_PRICE, _deadline(), _singleLoanArray(loanIdA));

    uint256 vaultUsdcBeforeSale = usdc.balanceOf(address(vault));

    // Start the NAV cycle: process loanIdA at index 0.
    mockCalculator.setNextValuation(LOAN_VALUATION_A);
    vm.prank(manager);
    vault.updateNav(1);

    uint256 nonceBeforeSale = loansNFT.ownershipNonce(address(vault));
    assertEq(vault.navCursor(), 1, "first batch processed loanIdA");
    assertEq(vault.pendingNav(), LOAN_VALUATION_A, "pendingNav reflects loanIdA's valuation");
    assertTrue(vault.navStart() > 0, "NAV cycle is in progress");

    // Mid-cycle: external buyer settles the offer directly on the exchange.
    // The exchange calls `loansNFT.safeTransferFrom(vault, buyer, loanIdA)`
    // — the vault's code never executes during this transfer, so no
    // `_requireIdleNav` guard fires. ERC721Enumerable swap-and-pop reorders
    // the vault's owned-tokens array, surfacing the index-shift hazard.
    vm.prank(loanBuyer);
    exchange.acceptOffer(offerId);

    assertEq(loansNFT.ownerOf(uint256(loanIdA)), loanBuyer, "buyer now owns loanIdA");
    assertEq(loansNFT.balanceOf(address(vault)), 1, "vault now holds 1 loan");
    assertGt(loansNFT.ownershipNonce(address(vault)), nonceBeforeSale, "ownership nonce bumped by exchange transfer");

    // ------------------------------------------------------------------
    // Bug analysis (without the ownership-nonce restart):
    //   batch 2 would read cursor=1, balance=1 → remaining=0, count=0.
    //   The loop is skipped, the `cursor >= total` finalize branch fires
    //   with pendingNav still holding LOAN_VALUATION_A (the sold loan).
    //   loanIdB — the only loan actually still in the portfolio — would
    //   never be valued.
    //
    //   buggy_lastNav   = vaultUsdcBeforeSale + SALE_PRICE + LOAN_VALUATION_A
    //   correct_lastNav = vaultUsdcBeforeSale + SALE_PRICE + LOAN_VALUATION_B
    //
    //   The difference (LOAN_VALUATION_A - LOAN_VALUATION_B = 70_000e6) is
    //   the per-share misprice that would harm shareholders on the next
    //   approveDeposit / approveRedemption.
    // ------------------------------------------------------------------

    // With the fix, the next batch detects the nonce mismatch, resets cursor
    // and pendingNav, and re-emits NavComputationStarted before iterating
    // over the post-sale set [loanIdB].
    mockCalculator.setNextValuation(LOAN_VALUATION_B);

    vm.prank(manager);
    vm.expectEmit(true, true, true, true);
    emit IPortfolioVault.NavComputationStarted(timeNow);
    vault.updateNav(NAV_BATCH_SIZE);

    uint256 buggyNav = vaultUsdcBeforeSale + uint256(SALE_PRICE) + LOAN_VALUATION_A;
    uint256 correctNav = vaultUsdcBeforeSale + uint256(SALE_PRICE) + LOAN_VALUATION_B;

    assertEq(vault.lastNav(), correctNav, "NAV must reflect the surviving loanIdB, not the sold loanIdA");
    assertTrue(vault.lastNav() != buggyNav, "fix must produce a different NAV than the buggy implementation would");
    assertEq(vault.navCursor(), 0, "cursor reset on finalize");
    assertEq(vault.navStart(), 0, "navStart reset on finalize");
    assertEq(vault.pendingNav(), 0, "pendingNav reset on finalize");
  }
}
