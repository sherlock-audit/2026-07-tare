// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {ILoans} from "contracts/interfaces/ILoans.sol";
import {ILoansNFT} from "contracts/interfaces/ILoansNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Bundle of loans offered by `seller` to `buyer` at a fixed `price` until `deadline`.
 * @dev Stored per `offerId` and consumed atomically when `buyer` calls `acceptOffer`.
 */
struct SaleOffer {
  address seller;
  address buyer;
  uint128 price;
  uint48 deadline;
  uint64[] loanIds;
}

/**
 * @title ILoansExchange
 * @notice Bilateral exchange for transferring loan NFTs between two pre-registered counterparties
 *         in a single atomic settlement: USDC moves from buyer to seller while the loan NFTs
 *         move from seller to buyer. Offers are seller-initiated and buyer-accepted.
 */
interface ILoansExchange {
  /**
   * @notice Emitted when `seller` creates a new sale offer addressed to `buyer`.
   * @param offerId The new offer identifier.
   * @param seller The seller (current loan owner) creating the offer.
   * @param buyer The buyer authorized to accept the offer.
   * @param price The settlement price in currency base units.
   * @param deadline The unix timestamp after which the offer can no longer be accepted.
   * @param loanIds The loan NFTs included in the offer.
   */
  event OfferCreated(
    uint64 indexed offerId,
    address indexed seller,
    address indexed buyer,
    uint128 price,
    uint48 deadline,
    uint64[] loanIds
  );

  /**
   * @notice Emitted when `buyer` accepts an offer and settlement completes.
   * @param offerId The accepted offer identifier.
   * @param seller The seller that received `price`.
   * @param buyer The buyer that received the loan NFTs.
   * @param price The settlement price paid in currency base units.
   */
  event OfferAccepted(uint64 indexed offerId, address indexed seller, address indexed buyer, uint128 price);

  /** @notice Emitted when the seller cancels their own outstanding offer. */
  event OfferCancelled(uint64 indexed offerId);

  /** @notice Emitted when an admin or guardian force-cancels `seller`'s offer. */
  event OfferForceCancelled(uint64 indexed offerId, address indexed seller);

  /** @notice Emitted when the admin updates the maximum number of loans allowed per offer. */
  event MaxLoansPerOfferUpdated(uint64 newMax);

  /** @notice Thrown when `acceptOffer` is called after the offer's deadline. */
  error OfferExpired();
  /** @notice Thrown when the offer has been cancelled, accepted, or never existed. */
  error OfferInactive();
  /** @notice Thrown when the caller is not the designated buyer for the offer. */
  error NotOfferRecipient();
  /** @notice Thrown when the caller is not the seller of the offer. */
  error NotSeller();
  /** @notice Thrown when the seller no longer owns a loan included in the offer. */
  error NotLoanOwner();
  /** @notice Thrown when a loan included in the offer is currently locked and cannot be transferred. */
  error LoanLocked();
  /** @notice Thrown when the buyer address provided is invalid (e.g. zero or equal to seller). */
  error InvalidBuyer();
  /** @notice Thrown when the buyer is not registered in the seller's address book as an Investor. */
  error BuyerNotRegistered();
  /** @notice Thrown when the seller is not registered in the buyer's address book as an Investor. */
  error SellerNotRegistered();
  /** @notice Thrown when the loan list is empty or exceeds `maxLoansPerOffer`. */
  error InvalidLoanIdsLength();
  /** @notice Thrown when the supplied deadline is in the past. */
  error InvalidDeadline();
  /** @notice Thrown when the admin sets `maxLoansPerOffer` to zero. */
  error InvalidMaxLoansPerOffer();
  /** @notice Thrown when a zero address is supplied where one is not permitted. */
  error ZeroAddress();

  /**
   * @notice Create a sale offer for one or more loan NFTs.
   * @dev The caller must own every loan in `loanIds`. The buyer and seller must each be
   *      registered as `Investor` in the other's address book.
   * @param buyer The address authorized to accept the offer.
   * @param price The settlement price in currency base units.
   * @param deadline The unix timestamp after which the offer can no longer be accepted.
   * @param loanIds The loan NFTs included in the offer.
   * @return offerId The identifier of the newly created offer.
   */
  function createOffer(
    address buyer,
    uint128 price,
    uint48 deadline,
    uint64[] calldata loanIds
  ) external returns (uint64 offerId);

  /**
   * @notice Accept and atomically settle an offer addressed to the caller.
   * @dev Transfers `price` in currency from buyer to seller and transfers every loan NFT
   *      from seller to buyer in a single transaction.
   * @param offerId The offer identifier to accept.
   */
  function acceptOffer(uint64 offerId) external;

  /**
   * @notice Cancel an offer previously created by the caller.
   * @param offerId The offer identifier to cancel.
   */
  function cancelOffer(uint64 offerId) external;

  /**
   * @notice Force-cancel an offer regardless of seller. Admin or guardian only.
   * @param offerId The offer identifier to cancel.
   */
  function forceCancelOffer(uint64 offerId) external;

  /**
   * @notice Update the maximum number of loans allowed per offer. Admin only.
   * @param newMax The new maximum (must be greater than zero).
   */
  function setMaxLoansPerOffer(uint64 newMax) external;

  /** @notice Returns the current maximum number of loans allowed per offer. */
  function maxLoansPerOffer() external view returns (uint64);

  /**
   * @notice Returns the stored offer for `offerId`.
   * @param offerId The offer identifier to look up.
   * @return The stored `SaleOffer` (zeroed fields if the offer was cancelled or accepted).
   */
  function getOffer(uint64 offerId) external view returns (SaleOffer memory);

  /** @notice Returns the `Loans` contract whose loan NFTs are traded on this exchange. */
  function LOANS() external view returns (ILoans);

  /** @notice Returns the `LoansNFT` contract that custodies the loan NFTs traded on this exchange. */
  function LOANS_NFT() external view returns (ILoansNFT);

  /** @notice Returns the ERC-20 currency in which offers are denominated and settled. */
  function CURRENCY() external view returns (IERC20);
}
