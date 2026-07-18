// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Rescuable} from "contracts/misc/Rescuable.sol";
import {ILoansExchange, SaleOffer} from "contracts/interfaces/ILoansExchange.sol";
import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {ILoans, Roles} from "contracts/interfaces/ILoans.sol";
import {ILoansAuth} from "contracts/misc/interfaces/ILoansAuth.sol";

/**
 * @title LoansExchange
 * @notice Peer-to-peer marketplace for transferring Loan NFTs between registered
 *         investors against an ERC20 payment.
 * @dev Sellers create directed offers naming a specific buyer, locking the Loan
 *      NFTs to the exchange for the offer's lifetime. The named buyer atomically
 *      pays the seller and receives the NFTs by calling `acceptOffer`. Sellers
 *      can `cancelOffer` to unlock their NFTs; the guardian can `forceCancelOffer`
 *      as a recovery action. Both buyer and seller must be registered as
 *      `Investor` for each other under the loans contract's auth registry.
 */
contract LoansExchange is ILoansExchange, Rescuable, ReentrancyGuardTransient {
  using SafeERC20 for IERC20;

  /// @notice The `Loans` contract whose NFTs are tradable here.
  ILoans public immutable LOANS;

  /// @notice The `LoansNFT` contract that tokenises loan ownership.
  ILoansNFT public immutable LOANS_NFT;

  /// @notice The ERC20 used to settle offers (matches `LOANS.currency()`).
  IERC20 public immutable CURRENCY;

  /// @notice Monotonic counter of created offers. The next offer's id is `offerCount + 1`.
  uint64 public offerCount;

  /// @inheritdoc ILoansExchange
  uint64 public maxLoansPerOffer = 100;

  mapping(uint64 offerId => SaleOffer offer) internal _offers;

  constructor(ILoansNFT _loansNFT, ILoans _loans, address initialGuardian, address initialRecoveryAddress) {
    require(address(_loansNFT) != address(0), ZeroAddress());
    require(address(_loans) != address(0), ZeroAddress());
    _initGuardian(initialGuardian);
    _initRecoveryAddress(initialRecoveryAddress);
    LOANS_NFT = _loansNFT;
    LOANS = _loans;
    CURRENCY = _loans.currency();
  }

  /// @inheritdoc ILoansExchange
  function setMaxLoansPerOffer(uint64 newMax) external onlyAdminOrGuardian {
    require(newMax > 0, InvalidMaxLoansPerOffer());
    maxLoansPerOffer = newMax;
    emit MaxLoansPerOfferUpdated(newMax);
  }

  /// @inheritdoc ILoansExchange
  function getOffer(uint64 offerId) external view returns (SaleOffer memory) {
    return _offers[offerId];
  }

  /// @inheritdoc ILoansExchange
  function createOffer(
    address buyer,
    uint128 price,
    uint48 deadline,
    uint64[] calldata loanIds
  ) external whenNotPaused nonReentrant returns (uint64 offerId) {
    uint256 loanIdsLength = loanIds.length;
    require(loanIdsLength > 0 && loanIdsLength <= maxLoansPerOffer, InvalidLoanIdsLength());
    require(msg.sender != buyer && buyer != address(0), InvalidBuyer());
    require(deadline > block.timestamp, InvalidDeadline());
    require(ILoansAuth(address(LOANS)).isRegisteredForRole(msg.sender, Roles.Investor, buyer), BuyerNotRegistered());

    offerId = ++offerCount;

    for (uint256 i = 0; i < loanIdsLength; ++i) {
      uint64 loanId = loanIds[i];
      require(LOANS_NFT.ownerOf(uint256(loanId)) == msg.sender, NotLoanOwner());
      require(LOANS_NFT.getLocked(uint256(loanId)) == address(0), LoanLocked());

      LOANS_NFT.lock(address(this), uint256(loanId));
    }

    _offers[offerId] = SaleOffer({
      seller: msg.sender,
      buyer: buyer,
      price: price,
      deadline: deadline,
      loanIds: loanIds
    });

    emit OfferCreated(offerId, msg.sender, buyer, price, deadline, loanIds);
  }

  /// @inheritdoc ILoansExchange
  function acceptOffer(uint64 offerId) external whenNotPaused nonReentrant {
    SaleOffer storage offer = _offers[offerId];

    // An inactive offer has `buyer == address(0)`, which `msg.sender` can never equal.
    require(msg.sender == offer.buyer, NotOfferRecipient());
    require(block.timestamp <= offer.deadline, OfferExpired());

    address seller = offer.seller;
    uint128 price = offer.price;

    require(ILoansAuth(address(LOANS)).isRegisteredForRole(seller, Roles.Investor, msg.sender), BuyerNotRegistered());
    require(ILoansAuth(address(LOANS)).isRegisteredForRole(msg.sender, Roles.Investor, seller), SellerNotRegistered());

    uint64[] memory loanIds = _removeOffer(offerId);

    // Send Loan NFTs to the buyer first, before any cash moves.
    uint256 loanIdsLength = loanIds.length;
    for (uint256 i = 0; i < loanIdsLength; ++i) {
      LOANS_NFT.transferFrom(seller, msg.sender, uint256(loanIds[i]));
    }

    // Pull currency from the buyer to the seller last.
    if (price > 0) {
      CURRENCY.safeTransferFrom(msg.sender, seller, uint256(price));
    }

    emit OfferAccepted(offerId, seller, msg.sender, price);
  }

  /// @inheritdoc ILoansExchange
  function forceCancelOffer(uint64 offerId) external onlyRole(GUARDIAN_ROLE) nonReentrant {
    address seller = _offers[offerId].seller;
    uint64[] memory loanIds = _removeOffer(offerId);

    _unlockLoans(loanIds);

    emit OfferForceCancelled(offerId, seller);
  }

  /// @inheritdoc ILoansExchange
  function cancelOffer(uint64 offerId) external whenNotPaused nonReentrant {
    require(_offers[offerId].seller == msg.sender, NotSeller());

    uint64[] memory loanIds = _removeOffer(offerId);
    _unlockLoans(loanIds);

    emit OfferCancelled(offerId);
  }

  /**
   * @dev Validates an offer is active, reads its fields, then deletes the offer struct.
   *      Does not perform caller authorization — each call site handles its own auth
   *      before calling this helper. Does not unlock loans — callers handle the unlock
   *      strategy (explicit unlock for cancellation, implicit via transfer for acceptance).
   */
  function _removeOffer(uint64 offerId) internal returns (uint64[] memory loanIds) {
    SaleOffer storage offer = _offers[offerId];

    require(offer.buyer != address(0), OfferInactive());

    loanIds = offer.loanIds;

    delete _offers[offerId];
  }

  /**
   * @dev Unlocks every loan in `loanIds` from the exchange. Assumes the caller has
   *      already removed the offer from storage; while an offer is active every listed
   *      loan is locked with the exchange as unlocker, so the unlock cannot revert.
   */
  function _unlockLoans(uint64[] memory loanIds) internal {
    uint256 loanIdsLength = loanIds.length;

    for (uint256 i = 0; i < loanIdsLength; ++i) {
      LOANS_NFT.unlock(uint256(loanIds[i]));
    }
  }
}
