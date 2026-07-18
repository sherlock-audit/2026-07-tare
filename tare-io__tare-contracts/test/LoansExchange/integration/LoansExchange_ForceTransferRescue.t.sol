// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansExchangeTestBase} from "../setup/LoansExchange_TestBase.t.sol";
import {ILoansExchange, SaleOffer} from "contracts/interfaces/ILoansExchange.sol";
import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";
import {Roles} from "contracts/interfaces/ILoans.sol";

/// @notice End-to-end rescue path: a loan listed for sale is force-transferred
/// to a new investor after the stale offer has been cleared, and the new
/// investor is then able to list the same loan in a fresh offer.
contract LoansExchange_ForceTransferRescueTest is LoansExchangeTestBase {
  address internal newOwner = makeAddr("newOwner");
  address internal newBuyer = makeAddr("newBuyer");

  function test_ForceTransferRescue_AfterForceCancel_NewOwnerCanRelist() public {
    // 1. Seller creates offer A — loan becomes locked by the exchange.
    (uint64 offerId, uint64 loanId) = _createOfferWithActiveLoan();
    assertEq(loansNFT.ownerOf(loanId), seller);
    assertEq(loansNFT.getLocked(uint256(loanId)), address(exchange));

    // 2. Guardian's first forceTransfer attempt reverts: the exchange lock
    //    must be cleared before the rescue can proceed.
    vm.prank(guardian);
    vm.expectRevert(ILockable.TokenLocked.selector);
    loansNFT.forceTransfer(seller, newOwner, uint256(loanId));

    // 3. Guardian force-cancels the offer; the exchange unlocks the loan.
    vm.prank(guardian);
    exchange.forceCancelOffer(offerId);
    assertEq(loansNFT.getLocked(uint256(loanId)), address(0));
    SaleOffer memory cancelled = exchange.getOffer(offerId);
    assertEq(cancelled.seller, address(0));

    // 4. Guardian force-transfers the unlocked NFT to the new owner.
    vm.prank(guardian);
    loansNFT.forceTransfer(seller, newOwner, uint256(loanId));
    assertEq(loansNFT.ownerOf(loanId), newOwner);

    // 5. The new owner registers a buyer and lists the same loan in a fresh
    //    offer, proving that no stale state from offer A blocks relisting.
    vm.prank(newOwner);
    loans.registerAddress(Roles.Investor, newBuyer);
    vm.prank(newOwner);
    loansNFT.setApprovalForAll(address(exchange), true);

    uint64[] memory loanIds = _singleLoanArray(loanId);
    vm.prank(newOwner);
    uint64 newOfferId = exchange.createOffer(newBuyer, OFFER_PRICE, _deadline(), loanIds);

    assertGt(newOfferId, offerId);
    SaleOffer memory relisted = exchange.getOffer(newOfferId);
    assertEq(relisted.seller, newOwner);
    assertEq(relisted.buyer, newBuyer);
    assertEq(relisted.loanIds.length, 1);
    assertEq(relisted.loanIds[0], loanId);
    assertEq(loansNFT.getLocked(uint256(loanId)), address(exchange));
  }
}
