// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";
import {LoansExchange} from "contracts/LoansExchange.sol";
import {ILoansExchange, SaleOffer} from "contracts/interfaces/ILoansExchange.sol";
import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {ILoans, Roles} from "contracts/interfaces/ILoans.sol";

/// @notice Shared setup for all LoansExchange unit tests.
abstract contract LoansExchangeTestBase is LoansTestBase {
  LoansExchange public exchange;

  address public buyer = makeAddr("buyer");
  address public seller;

  uint128 internal constant OFFER_PRICE = 45_000e6;
  int128 internal constant LOAN_PRINCIPAL = 50_000e6;
  uint48 internal constant DEADLINE_OFFSET = 1 days;

  bytes32 internal exchangeGuardianRole;
  bytes32 internal exchangeAdminRole;

  function setUp() public virtual override {
    super.setUp();

    seller = investor;
    exchange = new LoansExchange(ILoansNFT(address(loansNFT)), ILoans(address(loans)), guardian, recoveryAddress);

    exchangeGuardianRole = exchange.GUARDIAN_ROLE();
    exchangeAdminRole = exchange.ADMIN_ROLE();

    vm.prank(guardian);
    exchange.grantRole(exchangeAdminRole, admin);

    // Register buyer in the seller's address book for the Investor role
    vm.prank(seller);
    loans.registerAddress(Roles.Investor, buyer);

    // Register seller in the buyer's address book for the Investor role
    vm.prank(buyer);
    loans.registerAddress(Roles.Investor, seller);

    // Seller approves exchange to transfer all NFTs
    vm.prank(seller);
    loansNFT.setApprovalForAll(address(exchange), true);

    // Fund buyer with USDC and approve exchange
    usdc.mint(buyer, uint256(OFFER_PRICE) * 100);
    vm.prank(buyer);
    usdc.approve(address(exchange), type(uint256).max);
  }

  /// @notice Helper — creates an active loan and a default offer for it.
  function _createOfferWithActiveLoan() internal returns (uint64 offerId, uint64 loanId_) {
    loanId_ = _createActiveLoan(LOAN_PRINCIPAL);
    uint64[] memory loanIds = new uint64[](1);
    loanIds[0] = loanId_;

    vm.prank(seller);
    offerId = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }

  /// @notice Helper — returns a default future deadline.
  function _deadline() internal view returns (uint48) {
    return timeNow + DEADLINE_OFFSET;
  }

  /// @notice Helper — creates multiple active loans and a single offer containing all of them.
  function _createOfferWithMultipleActiveLoans(
    uint256 count
  ) internal returns (uint64 offerId, uint64[] memory loanIds) {
    loanIds = new uint64[](count);
    for (uint256 i = 0; i < count; i++) {
      loanIds[i] = _createActiveLoan(10_000e6);
    }

    vm.prank(seller);
    offerId = exchange.createOffer(buyer, OFFER_PRICE, _deadline(), loanIds);
  }

  /// @notice Helper — builds a single-element loanIds array.
  function _singleLoanArray(uint64 id) internal pure returns (uint64[] memory) {
    uint64[] memory ids = new uint64[](1);
    ids[0] = id;
    return ids;
  }
}
