// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansExchangeTestBase} from "../setup/LoansExchange_TestBase.t.sol";
import {ILoansExchange, SaleOffer} from "contracts/interfaces/ILoansExchange.sol";
import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";
import {Roles} from "contracts/interfaces/ILoans.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {NonReceiverContract} from "test/mocks/NonReceiverContract.sol";
import {RevertingReceiverContract} from "test/mocks/RevertingReceiverContract.sol";

// ============================================================================
// getOffer
// ============================================================================

contract LoansExchange_GetOfferTest is LoansExchangeTestBase {
  function test_GetOffer_ReturnsStoredOffer() public {
    (uint64 offerId, uint64 loanId_) = _createOfferWithActiveLoan();
    SaleOffer memory offer = exchange.getOffer(offerId);

    assertEq(offer.seller, seller);
    assertEq(offer.buyer, buyer);
    assertEq(offer.price, OFFER_PRICE);
    assertEq(offer.loanIds.length, 1);
    assertEq(offer.loanIds[0], loanId_);
  }

  function test_GetOffer_ReturnsEmpty_WhenNonExistent() public view {
    SaleOffer memory offer = exchange.getOffer(999);
    assertEq(offer.seller, address(0));
    assertEq(offer.buyer, address(0));
    assertEq(offer.price, 0);
    assertEq(offer.loanIds.length, 0);
  }
}

// ============================================================================
// createOffer
// ============================================================================

contract LoansExchange_CreateOfferTest is LoansExchangeTestBase {
  function test_CreateOffer_Success() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);

    assertEq(offerId, 1);
    assertEq(exchange.offerCount(), 1);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.loanIds[0], loanId_);
  }

  function test_CreateOffer_EmitsEvent() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);
    uint48 deadline = _deadline();

    vm.prank(seller);
    vm.expectEmit(true, true, true, true, address(exchange));
    emit ILoansExchange.OfferCreated(1, seller, buyer, OFFER_PRICE, deadline, loanIds);
    exchange.createOffer(buyer, OFFER_PRICE, deadline, loanIds);
  }

  function test_CreateOffer_LocksNFTs() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    assertEq(loansNFT.ownerOf(loanId_), seller);

    vm.prank(seller);
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);

    // NFT stays with seller but is locked to the exchange
    assertEq(loansNFT.ownerOf(loanId_), seller);
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(exchange));
  }

  function test_CreateOffer_MultipleLoanIds() public {
    uint64 loanId1 = _createActiveLoan(25_000e6);
    uint64 loanId2 = _createActiveLoan(25_000e6);
    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanId1;
    loanIds[1] = loanId2;

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.loanIds.length, 2);
    assertEq(loansNFT.ownerOf(loanId1), seller);
    assertEq(loansNFT.ownerOf(loanId2), seller);
    assertEq(loansNFT.getLocked(uint256(loanId1)), address(exchange));
    assertEq(loansNFT.getLocked(uint256(loanId2)), address(exchange));
  }

  function test_CreateOffer_ZeroPrice() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(buyer, 0, _deadline(), loanIds);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.price, 0);
  }

  function test_CreateOffer_IncrementsOfferCount() public {
    uint64 loanId1 = _createActiveLoan(25_000e6);
    uint64 loanId2 = _createActiveLoan(25_000e6);

    vm.startPrank(seller);
    uint64 offerId1 = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), _singleLoanArray(loanId1));
    uint64 offerId2 = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), _singleLoanArray(loanId2));
    vm.stopPrank();

    assertEq(offerId1, 1);
    assertEq(offerId2, 2);
    assertEq(exchange.offerCount(), 2);
  }

  function test_CreateOffer_Reverts_WhenEmptyLoanIds() public {
    uint64[] memory empty = new uint64[](0);

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.InvalidLoanIdsLength.selector);
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), empty);
  }

  function test_CreateOffer_Reverts_WhenTooManyLoanIds() public {
    // Set max to 1 so we can test with just 2 loans
    vm.prank(admin);
    exchange.setMaxLoansPerOffer(1);

    uint64 loanId1 = _createActiveLoan(25_000e6);
    uint64 loanId2 = _createActiveLoan(25_000e6);
    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanId1;
    loanIds[1] = loanId2;

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.InvalidLoanIdsLength.selector);
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }

  function test_CreateOffer_Reverts_WhenBuyerIsSelf() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.InvalidBuyer.selector);
    exchange.createOffer(seller, OFFER_PRICE, _deadline(), loanIds);
  }

  function test_CreateOffer_Reverts_WhenBuyerIsZeroAddress() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.InvalidBuyer.selector);
    exchange.createOffer(address(0), OFFER_PRICE, _deadline(), loanIds);
  }

  function test_CreateOffer_Reverts_WhenDeadlineInPast() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.InvalidDeadline.selector);
    exchange.createOffer(buyer, OFFER_PRICE, uint48(block.timestamp - 1), loanIds);
  }

  function test_CreateOffer_Reverts_WhenDeadlineIsNow() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.InvalidDeadline.selector);
    exchange.createOffer(buyer, OFFER_PRICE, timeNow, loanIds);
  }

  function test_CreateOffer_Reverts_WhenBuyerNotRegistered() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    address unregisteredBuyer = makeAddr("unregistered");

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.BuyerNotRegistered.selector);
    exchange.createOffer(unregisteredBuyer, OFFER_PRICE, _deadline(), loanIds);
  }

  function test_CreateOffer_Succeeds_WhenSellerNotInBuyersAddressBook() public {
    // Buyer has not whitelisted seller; this is fine at create-time. The
    // reverse-direction check is only enforced at acceptOffer.
    vm.prank(buyer);
    loans.unregisterAddress(Roles.Investor, seller);

    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);

    assertEq(exchange.getOffer(offerId).buyer, buyer);
  }

  function test_CreateOffer_Reverts_WhenCallerDoesNotOwnNFT() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    // Register buyer in randomUser's address book so the registration check passes
    vm.prank(randomUser);
    loans.registerAddress(Roles.Investor, buyer);

    vm.prank(randomUser);
    vm.expectRevert(ILoansExchange.NotLoanOwner.selector);
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }

  function test_CreateOffer_Reverts_WhenLoanAlreadyInActiveOffer() public {
    (, uint64 loanId_) = _createOfferWithActiveLoan();
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.LoanLocked.selector);
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }

  function test_CreateOffer_Reverts_WhenLoanIsAlreadyLocked() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    address externalUnlocker = makeAddr("externalUnlocker");

    vm.prank(seller);
    loansNFT.lock(externalUnlocker, uint256(loanId_));

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.LoanLocked.selector);
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }

  function test_CreateOffer_Reverts_WhenDuplicateLoanIdInSameCall() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = new uint64[](2);
    loanIds[0] = loanId_;
    loanIds[1] = loanId_;

    vm.prank(seller);
    vm.expectRevert(); // second lock() reverts with AlreadyLocked
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }
}

// ============================================================================
// acceptOffer — shared tests live in the abstract base, concrete tests below
// ============================================================================

abstract contract LoansExchange_AcceptOfferTestBase is LoansExchangeTestBase {
  function _doAcceptOffer(uint64 offerId) internal virtual;

  // --------------------------------------------------------------------------
  // Settlement success cases
  // --------------------------------------------------------------------------

  function test_AcceptOffer_TransfersNFTsAndPayment() public {
    (uint64 offerId, uint64 loanId_) = _createOfferWithActiveLoan();

    uint256 sellerBalanceBefore = usdc.balanceOf(seller);
    uint256 buyerBalanceBefore = usdc.balanceOf(buyer);

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), buyer);
    assertEq(usdc.balanceOf(seller), sellerBalanceBefore + OFFER_PRICE);
    assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - OFFER_PRICE);
  }

  function test_AcceptOffer_TransfersAllNFTs_WhenMultipleLoans() public {
    (uint64 offerId, uint64[] memory loanIds) = _createOfferWithMultipleActiveLoans(3);

    uint256 sellerBalanceBefore = usdc.balanceOf(seller);
    uint256 buyerBalanceBefore = usdc.balanceOf(buyer);

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    for (uint256 i = 0; i < loanIds.length; i++) {
      assertEq(loansNFT.ownerOf(loanIds[i]), buyer);
      assertEq(loansNFT.getLocked(uint256(loanIds[i])), address(0));
    }
    assertEq(usdc.balanceOf(seller), sellerBalanceBefore + OFFER_PRICE);
    assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - OFFER_PRICE);
  }

  function test_AcceptOffer_ClearsLock() public {
    (uint64 offerId, uint64 loanId_) = _createOfferWithActiveLoan();
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(exchange));

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    assertEq(loansNFT.getLocked(uint256(loanId_)), address(0));
    assertEq(loansNFT.ownerOf(loanId_), buyer);
  }

  function test_AcceptOffer_EmitsEvent() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(buyer);
    vm.expectEmit(true, true, true, true, address(exchange));
    emit ILoansExchange.OfferAccepted(offerId, seller, buyer, OFFER_PRICE);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_DeletesOffer() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.buyer, address(0));
    assertEq(offer.seller, address(0));
    assertEq(offer.price, 0);
    assertEq(offer.loanIds.length, 0);
  }

  function test_AcceptOffer_ZeroPrice() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(buyer, 0, _deadline(), loanIds);

    uint256 sellerBalanceBefore = usdc.balanceOf(seller);
    uint256 buyerBalanceBefore = usdc.balanceOf(buyer);

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), buyer);
    assertEq(usdc.balanceOf(seller), sellerBalanceBefore);
    assertEq(usdc.balanceOf(buyer), buyerBalanceBefore);
  }

  function test_AcceptOffer_AtDeadline() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);
    uint48 deadline = _deadline();

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(buyer, OFFER_PRICE, deadline, loanIds);

    vm.warp(deadline);

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), buyer);
  }

  // --------------------------------------------------------------------------
  // General access / state / timing reverts
  // --------------------------------------------------------------------------

  function test_AcceptOffer_Reverts_WhenOfferInactive() public {
    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.NotOfferRecipient.selector);
    _doAcceptOffer(999);
  }

  function test_AcceptOffer_Reverts_WhenNotBuyer() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(randomUser);
    vm.expectRevert(ILoansExchange.NotOfferRecipient.selector);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_Reverts_WhenExpired() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);
    uint48 deadline = _deadline();

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(buyer, OFFER_PRICE, deadline, loanIds);

    vm.warp(uint256(deadline) + 1);

    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.OfferExpired.selector);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_Reverts_WhenAlreadyAccepted() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.NotOfferRecipient.selector);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_Reverts_WhenBuyerHasInsufficientFunds() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    deal(address(usdc), buyer, 0);

    vm.prank(buyer);
    vm.expectRevert();
    _doAcceptOffer(offerId);
  }

  // --------------------------------------------------------------------------
  // Mutual address-book whitelist enforcement
  // --------------------------------------------------------------------------

  function test_AcceptOffer_Reverts_WhenBuyerNoLongerInSellersAddressBook() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    // Seller removes buyer from their address book after the offer was created.
    vm.prank(seller);
    loans.unregisterAddress(Roles.Investor, buyer);

    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.BuyerNotRegistered.selector);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_Reverts_WhenSellerNotInBuyersAddressBook() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    // Buyer removes the seller from their own address book before accepting.
    vm.prank(buyer);
    loans.unregisterAddress(Roles.Investor, seller);

    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.SellerNotRegistered.selector);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_Reverts_BuyerCheckedBeforeSeller_WhenBothMissing() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    // Remove both directions; buyer-side check is performed first so we expect that error.
    vm.prank(seller);
    loans.unregisterAddress(Roles.Investor, buyer);
    vm.prank(buyer);
    loans.unregisterAddress(Roles.Investor, seller);

    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.BuyerNotRegistered.selector);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_Succeeds_AfterBuyerReRegisteredBySeller() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    // Remove then re-add buyer in seller's address book.
    vm.prank(seller);
    loans.unregisterAddress(Roles.Investor, buyer);
    vm.prank(seller);
    loans.registerAddress(Roles.Investor, buyer);

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.buyer, address(0));
  }

  function test_AcceptOffer_Succeeds_WhenSellerAddedToBuyersBookAfterOfferCreated() public {
    // Drop the auto-registration done in setUp so we control timing precisely.
    vm.prank(buyer);
    loans.unregisterAddress(Roles.Investor, seller);

    (uint64 offerId, ) = _createOfferWithActiveLoan();

    // Buyer adds the seller only after the offer was created, just before accepting.
    vm.prank(buyer);
    loans.registerAddress(Roles.Investor, seller);

    vm.prank(buyer);
    _doAcceptOffer(offerId);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.buyer, address(0));
  }

  function test_AcceptOffer_Reverts_WhenBuyerRegisteredUnderWrongRoleBySeller() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    // Seller swaps buyer's registration to a non-Investor role.
    vm.prank(seller);
    loans.unregisterAddress(Roles.Investor, buyer);
    vm.prank(seller);
    loans.registerAddress(Roles.Borrower, buyer);

    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.BuyerNotRegistered.selector);
    _doAcceptOffer(offerId);
  }

  function test_AcceptOffer_Reverts_WhenSellerRegisteredUnderWrongRoleByBuyer() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    // Buyer swaps seller's registration to a non-Investor role.
    vm.prank(buyer);
    loans.unregisterAddress(Roles.Investor, seller);
    vm.prank(buyer);
    loans.registerAddress(Roles.Borrower, seller);

    vm.prank(buyer);
    vm.expectRevert(ILoansExchange.SellerNotRegistered.selector);
    _doAcceptOffer(offerId);
  }
}

// ============================================================================
// acceptOffer
// ============================================================================

contract LoansExchange_AcceptOfferTest is LoansExchange_AcceptOfferTestBase {
  function _doAcceptOffer(uint64 offerId) internal override {
    exchange.acceptOffer(offerId);
  }

  function test_AcceptOffer_SucceedsWhenBuyerIsNonReceiverContract() public {
    NonReceiverContract nonReceiver = new NonReceiverContract();
    address contractBuyer = address(nonReceiver);

    vm.prank(seller);
    loans.registerAddress(Roles.Investor, contractBuyer);
    vm.prank(contractBuyer);
    loans.registerAddress(Roles.Investor, seller);

    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(contractBuyer, OFFER_PRICE, _deadline(), loanIds);

    usdc.mint(contractBuyer, uint256(OFFER_PRICE));
    vm.prank(contractBuyer);
    usdc.approve(address(exchange), type(uint256).max);

    vm.prank(contractBuyer);
    exchange.acceptOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), contractBuyer);
  }

  /// @notice Proves that `acceptOffer` does not invoke `onERC721Received` on the
  /// buyer. If `safeTransferFrom` were used the callback would fire and revert
  /// the entire transaction.
  function test_AcceptOffer_DoesNotInvokeReceiverHook() public {
    RevertingReceiverContract revertingReceiver = new RevertingReceiverContract();
    address contractBuyer = address(revertingReceiver);

    vm.prank(seller);
    loans.registerAddress(Roles.Investor, contractBuyer);
    vm.prank(contractBuyer);
    loans.registerAddress(Roles.Investor, seller);

    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(seller);
    uint64 offerId = exchange.createOffer(contractBuyer, OFFER_PRICE, _deadline(), loanIds);

    usdc.mint(contractBuyer, uint256(OFFER_PRICE));
    vm.prank(contractBuyer);
    usdc.approve(address(exchange), type(uint256).max);

    vm.prank(contractBuyer);
    exchange.acceptOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), contractBuyer);
  }
}

// ============================================================================
// cancelOffer
// ============================================================================

contract LoansExchange_CancelOfferTest is LoansExchangeTestBase {
  function test_CancelOffer_UnlocksNFTs() public {
    (uint64 offerId, uint64 loanId_) = _createOfferWithActiveLoan();
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(exchange));

    vm.prank(seller);
    exchange.cancelOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), seller);
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(0));
  }

  function test_CancelOffer_EmitsEvent() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(seller);
    vm.expectEmit(true, false, false, false, address(exchange));
    emit ILoansExchange.OfferCancelled(offerId);
    exchange.cancelOffer(offerId);
  }

  function test_CancelOffer_DeletesOffer() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(seller);
    exchange.cancelOffer(offerId);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.buyer, address(0));
    assertEq(offer.seller, address(0));
    assertEq(offer.price, 0);
    assertEq(offer.loanIds.length, 0);
  }

  function test_CancelOffer_Reverts_WhenOfferInactive() public {
    vm.prank(seller);
    vm.expectRevert(ILoansExchange.NotSeller.selector);
    exchange.cancelOffer(999);
  }

  function test_CancelOffer_Reverts_WhenNotSeller() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(randomUser);
    vm.expectRevert(ILoansExchange.NotSeller.selector);
    exchange.cancelOffer(offerId);
  }

  function test_CancelOffer_Reverts_WhenAlreadyCancelled() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(seller);
    exchange.cancelOffer(offerId);

    vm.prank(seller);
    vm.expectRevert(ILoansExchange.NotSeller.selector);
    exchange.cancelOffer(offerId);
  }

  function test_CancelOffer_UnlocksAllNFTs_WhenMultipleLoans() public {
    (uint64 offerId, uint64[] memory loanIds) = _createOfferWithMultipleActiveLoans(3);

    for (uint256 i = 0; i < loanIds.length; i++) {
      assertEq(loansNFT.getLocked(uint256(loanIds[i])), address(exchange));
    }

    vm.prank(seller);
    exchange.cancelOffer(offerId);

    for (uint256 i = 0; i < loanIds.length; i++) {
      assertEq(loansNFT.ownerOf(loanIds[i]), seller);
      assertEq(loansNFT.getLocked(uint256(loanIds[i])), address(0));
    }
  }

  function test_CancelOffer_AllowsRelisting() public {
    (uint64 offerId, uint64 loanId_) = _createOfferWithActiveLoan();

    vm.prank(seller);
    exchange.cancelOffer(offerId);

    vm.prank(seller);
    uint64 newOfferId = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), _singleLoanArray(loanId_));
    assertGt(newOfferId, offerId);
  }
}

// ============================================================================
// forceCancelOffer (guardian)
// ============================================================================

contract LoansExchange_ForceCancelOfferTest is LoansExchangeTestBase {
  function test_ForceCancelOffer_UnlocksLoans() public {
    (uint64 offerId, uint64 loanId_) = _createOfferWithActiveLoan();
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(exchange));

    vm.prank(guardian);
    exchange.forceCancelOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), seller);
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(0));
  }

  function test_ForceCancelOffer_EmitsEvent() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(guardian);
    vm.expectEmit(true, true, false, false, address(exchange));
    emit ILoansExchange.OfferForceCancelled(offerId, seller);
    exchange.forceCancelOffer(offerId);
  }

  function test_ForceCancelOffer_DeletesOffer() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(guardian);
    exchange.forceCancelOffer(offerId);

    SaleOffer memory offer = exchange.getOffer(offerId);
    assertEq(offer.buyer, address(0));
    assertEq(offer.seller, address(0));
  }

  function test_ForceCancelOffer_Reverts_WhenNotGuardian() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, exchangeGuardianRole)
    );
    exchange.forceCancelOffer(offerId);

    vm.prank(seller);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, seller, exchangeGuardianRole)
    );
    exchange.forceCancelOffer(offerId);
  }

  function test_ForceCancelOffer_Reverts_WhenOfferInactive() public {
    vm.prank(guardian);
    vm.expectRevert(ILoansExchange.OfferInactive.selector);
    exchange.forceCancelOffer(999);
  }

  function test_ForceCancelOffer_UnlocksMultipleLoans() public {
    (uint64 offerId, uint64[] memory loanIds) = _createOfferWithMultipleActiveLoans(3);

    vm.prank(guardian);
    exchange.forceCancelOffer(offerId);

    for (uint256 i = 0; i < loanIds.length; i++) {
      assertEq(loansNFT.getLocked(uint256(loanIds[i])), address(0));
      assertEq(loansNFT.ownerOf(loanIds[i]), seller);
    }
  }
}
