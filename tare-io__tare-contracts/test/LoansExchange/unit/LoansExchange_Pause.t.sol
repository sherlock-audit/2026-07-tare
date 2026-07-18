// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansExchangeTestBase} from "../setup/LoansExchange_TestBase.t.sol";
import {ILoansExchange, SaleOffer} from "contracts/interfaces/ILoansExchange.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LoansExchange_PauseTest is LoansExchangeTestBase {
  // ──────── createOffer ────────

  function test_CreateOffer_Reverts_WhenPaused() public {
    uint64 loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = _singleLoanArray(loanId_);

    vm.prank(guardian);
    exchange.pause();

    vm.prank(seller);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }

  // ──────── acceptOffer ────────

  function test_AcceptOffer_Reverts_WhenPaused() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(guardian);
    exchange.pause();

    vm.prank(buyer);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    exchange.acceptOffer(offerId);
  }

  // ──────── cancelOffer ────────

  function test_CancelOffer_Reverts_WhenPaused() public {
    (uint64 offerId, ) = _createOfferWithActiveLoan();

    vm.prank(guardian);
    exchange.pause();

    vm.prank(seller);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    exchange.cancelOffer(offerId);
  }

  // ──────── forceCancelOffer ────────

  function test_ForceCancelOffer_Works_WhenPaused() public {
    (uint64 offerId, uint64 loanId_) = _createOfferWithActiveLoan();

    vm.prank(guardian);
    exchange.pause();

    vm.prank(guardian);
    exchange.forceCancelOffer(offerId);

    assertEq(loansNFT.ownerOf(loanId_), seller);
    assertEq(loansNFT.getLocked(uint256(loanId_)), address(0));
  }

  // ──────── rescueERC20Tokens ────────

  function test_RescueERC20Tokens_Reverts_WhenPaused() public {
    vm.prank(guardian);
    exchange.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    exchange.rescueERC20Tokens(address(1), 1);
  }

  // ──────── rescueERC721Tokens ────────

  function test_RescueERC721Tokens_Reverts_WhenPaused() public {
    vm.prank(guardian);
    exchange.pause();

    vm.prank(guardian);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    exchange.rescueERC721Tokens(address(1), 1);
  }
}
