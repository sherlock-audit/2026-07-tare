// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {INavCalculator} from "contracts/interfaces/INavCalculator.sol";
import {InvestorWithdrawalResult} from "contracts/interfaces/ILoans.sol";
import {IERC7540} from "contracts/misc/interfaces/IERC7540.sol";

/**
 * @title IPortfolioVault
 * @notice Interface for the Portfolio Vault — a loan portfolio manager that holds loan NFTs,
 * computes on-chain NAV via paginated enumeration, and delegates loan valuation to an
 * external INavCalculator contract. Implements ERC-7540 async deposit/redeem flows.
 */
interface IPortfolioVault is IERC7540 {
  // ──────────────────────────── Errors ────────────────────────────

  /// @notice Thrown when the NAV is stale (age exceeds maxNavAge)
  error StaleNav();

  /// @notice Thrown when calculator factors changed since the last NAV finalization
  error CalculatorConfigurationChanged();

  /// @notice Thrown when the vault's loan NFT ownership set changed since the last NAV finalization
  error PortfolioHoldingsChanged();

  /// @notice Thrown when the NAV is zero (vault not yet bootstrapped)
  error ZeroNav();

  /// @notice Thrown when an operation requires idle NAV state but a computation is in progress
  error NavComputationInProgress();

  /// @notice Thrown when onERC721Received is called by a contract other than loansNFT
  error OnlyLoansNFT();

  /// @notice Thrown when a zero address is provided where a non-zero address is required
  error ZeroAddress();

  /// @notice Thrown when the caller is not the controller or an approved operator
  error Unauthorized();

  /// @notice Thrown when a zero amount is provided
  error ZeroAmount();

  /// @notice Thrown when the controller does not hold the SHAREHOLDER_ROLE on the share token
  error NotShareholder();

  /// @notice Thrown when no pending deposit exists for the controller
  error NoPendingDeposit();

  /// @notice Thrown when no claimable deposit exists for the controller
  error NoClaimableDeposit();

  /// @notice Thrown when no pending redeem exists for the controller
  error NoPendingRedeem();

  /// @notice Thrown when no claimable redeem exists for the controller
  error NoClaimableRedeem();

  /// @notice Thrown when the requested claim exceeds claimable amount
  error ExceedsClaimable();

  /// @notice Thrown when the requested approval exceeds the pending amount
  error ExceedsPending();

  /// @notice Thrown when an operation requires more liquidity than is available
  error InsufficientLiquidity();

  /// @notice Thrown when a function that must revert unconditionally is called
  error MustRevert();

  /// @notice Thrown when the vault itself is passed as an async request controller
  error InvalidController();

  /// @notice Thrown when the vault itself is passed as a claim or cancellation receiver
  error InvalidReceiver();

  /// @notice Thrown when `addLoansToNav` is called for a loan the vault does not own
  error LoanNotOwned();

  /// @notice Thrown when `setMaxNavAge` or the constructor is called with a zero `maxNavAge`.
  error InvalidMaxNavAge();

  /// @notice Thrown when `setMaxNavComputationTime` or the constructor is called with a zero `maxNavComputationTime`.
  error InvalidMaxNavComputationTime();

  /// @notice Thrown when `setExchange` is called with an exchange whose immutable `LOANS` / `LOANS_NFT` pointers don't match the vault's current dependencies
  error InvalidExchange();

  /// @notice Thrown when two parallel input arrays have different lengths
  error LengthMismatch();

  /// @notice Thrown when `collectCashflows` is called for a loan not currently in the NAV valuation set
  error LoanNotInNav();

  /// @notice Thrown when the constructor or `setLoans` is given a Loans contract whose `currency()` does not match the vault's `assetToken`
  error AssetMismatch();

  /// @notice Thrown when the constructor or `setLoans` is given a (`loans`, `loansNFT`) pair where `loansNFT.LOANS_CONTRACT() != loans`
  error ReversePointerMismatch();

  // ──────────────────────────── Events ────────────────────────────

  /**
   * @notice Emitted when a paginated NAV computation completes
   * @param nav The finalized NAV value
   * @param timestamp The block timestamp at finalization
   */
  event NavUpdated(uint256 nav, uint256 timestamp);

  /**
   * @notice Emitted when a new NAV computation begins (first batch or restart after timeout)
   * @param timestamp The block timestamp at computation start
   */
  event NavComputationStarted(uint256 timestamp);

  /**
   * @notice Emitted when the calculator contract is updated
   * @param calculator The new calculator contract address
   */
  event CalculatorUpdated(address calculator);

  /// @notice Emitted when the cached NAV is invalidated and a fresh `updateNav` is required.
  event NavInvalidated();

  /**
   * @notice Emitted when the Loans and LoansNFT contracts are repointed atomically via `setLoans`.
   * @param loans The new Loans contract address
   * @param loansNFT The new LoansNFT contract address
   */
  event LoansUpdated(address loans, address loansNFT);

  /// @notice Emitted when a loan is added to the curated loan list
  event LoanAddedToNav(uint64 indexed loanId);

  /// @notice Emitted when a loan is removed from the curated loan list
  event LoanRemovedFromNav(uint64 indexed loanId);

  /**
   * @notice Emitted when a manager approves a pending deposit
   * @param controller The controller whose deposit was approved
   * @param assets The amount of assets approved
   * @param shares The number of shares allocated at the current share price
   */
  event DepositApproved(address indexed controller, uint256 assets, uint256 shares);

  /**
   * @notice Emitted when a pending deposit request is cancelled
   * @param controller The controller whose deposit was cancelled
   * @param receiver The address that received the returned assets
   * @param assets The amount of assets returned
   */
  event DepositRequestCancelled(address indexed controller, address indexed receiver, uint256 assets);

  /**
   * @notice Emitted when a manager approves a pending redemption
   * @param controller The controller whose redemption was approved
   * @param shares The amount of shares approved
   * @param assets The amount of assets allocated at the current share price
   */
  event RedeemApproved(address indexed controller, uint256 shares, uint256 assets);

  /**
   * @notice Emitted when a pending redeem request is cancelled
   * @param controller The controller whose redeem was cancelled
   * @param receiver The address that received the unlocked shares
   * @param shares The amount of shares returned
   */
  event RedeemRequestCancelled(address indexed controller, address indexed receiver, uint256 shares);
  /**
   * @notice Emitted when the LoansExchange contract is updated
   * @param exchange The new LoansExchange contract address
   */
  event ExchangeUpdated(address exchange);

  /**
   * @notice Emitted when maxNavAge is updated
   * @param maxNavAge The new maximum NAV age in seconds
   */
  event MaxNavAgeUpdated(uint256 maxNavAge);

  /**
   * @notice Emitted when maxNavComputationTime is updated
   * @param maxNavComputationTime The new maximum NAV computation time in seconds
   */
  event MaxNavComputationTimeUpdated(uint256 maxNavComputationTime);

  /**
   * @notice Emitted when cashflows are collected from loans via investorWithdraw
   * @param loanWithdrawals The withdrawal results for each loan
   */
  event CashflowsCollected(InvestorWithdrawalResult[] loanWithdrawals);

  /**
   * @notice Emitted when the vault funds a loan in the Loans contract
   * @param loanId The loan being funded
   * @param amount The funded principal amount
   * @param entryIndex The Loans ledger entry index returned by fund()
   * @param ref Off-chain reference forwarded to Loans.fund
   */
  event LoanFunded(uint64 indexed loanId, int128 amount, uint128 entryIndex, bytes32 ref);

  // ─────────────────────── Manager Functions ──────────────────────

  /**
   * @notice Paginated NAV computation. Call repeatedly until the full portfolio is processed.
   * Restarts automatically if the previous computation timed out.
   * @param batchSize Number of loans to process in this batch
   */
  function updateNav(uint256 batchSize) external;

  /**
   * @notice Approves a pending deposit request for a controller. Calculates shares at
   * the current share price and makes them claimable.
   * @param controller The controller whose deposit to approve
   * @param assets The amount of assets to approve (must be <= pending amount)
   * @return shares The number of shares minted to the vault and made claimable for `controller`.
   */
  function approveDeposit(address controller, uint256 assets) external returns (uint256 shares);

  /**
   * @notice Approves a pending redemption request for a controller. Calculates assets at
   * the current share price and makes them claimable. Supports partial approvals.
   * @param controller The controller whose redemption to approve
   * @param shares The number of shares to approve (must be <= pending amount)
   * @return assets The amount of assets reserved against idle liquidity and made claimable for `controller`.
   */
  function approveRedemption(address controller, uint256 shares) external returns (uint256 assets);

  // ────────────────── Portfolio Manager Functions ─────────────────

  /**
   * @notice Purchases a loan bundle by accepting an offer on the exchange.
   * Reads the offer, approves USDC spend, and calls exchange.acceptOffer.
   * @dev After the exchange call, verifies the vault owns each loan NFT listed in the offer.
   * Reverts with `LoanNotOwned` if any NFT was not delivered, protecting the vault against
   * a malicious or buggy exchange that takes payment without transferring every NFT.
   * @param offerId The exchange offer to accept
   */
  function acceptSaleOffer(uint64 offerId) external;

  /**
   * @notice Creates a sale offer on the exchange for one or more loan NFTs held by the vault.
   * Approves each NFT to the exchange, which then locks them during offer creation.
   * @param buyer Designated buyer address
   * @param price Lump sum price for the bundle in asset token units
   * @param deadline Acceptance deadline (timestamp)
   * @param loanIds Array of loan IDs to sell
   * @return offerId The ID of the created offer
   */
  function createSaleOffer(
    address buyer,
    uint128 price,
    uint48 deadline,
    uint64[] calldata loanIds
  ) external returns (uint64 offerId);

  /**
   * @notice Cancels a sale offer previously created by the vault, unlocking the listed NFTs in place.
   * @param offerId The exchange offer to cancel
   */
  function cancelSaleOffer(uint64 offerId) external;

  /**
   * @notice Transfers loan NFTs out of the vault without USDC settlement (uses transferFrom).
   * @param loanIds Array of loan IDs to transfer
   * @param recipient The address to receive the loan NFTs
   */
  function transferLoans(uint64[] calldata loanIds, address recipient) external;

  /**
   * @notice Registers a counterparty as an investor in the vault's address book so it can trade loans with the vault
   * @dev Callable by `PORTFOLIO_MANAGER`, `ADMIN_ROLE`, or `GUARDIAN_ROLE`. `Roles.Investor` is the only role
   *      the vault's own address book is ever read for (both buyers and sellers on the exchange).
   * @param addr The counterparty address to register
   */
  function registerAddress(address addr) external;

  /**
   * @notice Unregisters a counterparty from the investor role in the vault's address book
   * @dev Callable by `PORTFOLIO_MANAGER`, `ADMIN_ROLE`, or `GUARDIAN_ROLE`.
   * @param addr The counterparty address to unregister
   */
  function unregisterAddress(address addr) external;

  /**
   * @notice Withdraws accumulated interest and principal from loans the vault owns.
   * Calls Loans.investorWithdraw and receives USDC.
   * @dev Reverts with `LoanNotInNav` if any loanId is not currently in the NAV valuation set,
   * to prevent cash from excluded loans silently re-entering NAV via `idleLiquidity`.
   * @param loanIds Array of loan IDs to collect cashflows from
   * @param ref Off-chain reference for the withdrawal entries
   * @return loanWithdrawals Per-loan breakdown of principal and interest withdrawn
   */
  function collectCashflows(
    uint64[] calldata loanIds,
    bytes32 ref
  ) external returns (InvestorWithdrawalResult[] memory loanWithdrawals);

  /**
   * @notice Funds a single loan where the vault is the current investor (loan NFT owner).
   * @dev Thin wrapper around `fundLoans` for the single-loan case.
   * @param loanId The loan to fund
   * @param amount The principal amount to fund (must be positive)
   * @param timestamp Timestamp recorded in the Loans ledger update
   * @param ref Off-chain reference for the Loans funding entry
   */
  function fundLoan(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external;

  /**
   * @notice Funds a batch of loans where the vault is the current investor (loan NFT owner).
   * @dev Atomic: all loans fund or the whole batch reverts. Emits one `LoanFunded` per element.
   * `loanIds` and `amounts` must have the same non-zero length; each amount must be positive;
   * the sum must fit within `idleLiquidity()`. Each funded loan is auto-admitted to the curated NAV list.
   * @param loanIds Loans to fund
   * @param amounts Principal amount to fund per loan (each must be positive)
   * @param timestamp Timestamp recorded in the Loans ledger update (shared across the batch)
   * @param ref Off-chain reference for the Loans funding entries (shared across the batch)
   */
  function fundLoans(uint64[] calldata loanIds, int128[] calldata amounts, uint48 timestamp, bytes32 ref) external;

  /**
   * @notice Admits a batch of vault-owned loans into the curated loan list. Idempotent per loan.
   * @dev Use to back-fill loans the vault acquired outside `fundLoans`/`acceptSaleOffer`
   * (e.g. an NFT minted directly to the vault, or transferred in via `transferLoans`).
   * Reverts with `LoanNotOwned` if the vault does not currently own any one of the NFTs.
   * @param loanIds The loan IDs to admit into NAV
   */
  function addLoansToNav(uint64[] calldata loanIds) external;

  /**
   * @notice Removes a batch of loans from the curated loan list without transferring the NFTs. Idempotent per loan.
   * @dev Use to exclude vault-owned loans from valuation (e.g. impaired loans valued off-chain).
   * The NFTs remain in the vault; only the NAV computation set shrinks.
   * @param loanIds The loan IDs to remove from NAV
   */
  function removeLoansFromNav(uint64[] calldata loanIds) external;

  // ─────────────────────── Guardian Functions ─────────────────────

  /**
   * @notice Sets the NAV calculator contract used during NAV computation
   * @param _calculator Address of the new INavCalculator implementation
   */
  function setCalculator(address _calculator) external;

  /**
   * @notice Atomically repoints the Loans ledger and LoansNFT contract used by the vault.
   * @dev Combined into a single call so the two pointers can never diverge.
   * Reverts with `AssetMismatch` if `ILoans(_loans).currency() != assetToken`,
   * or `ReversePointerMismatch` if `ILoansNFT(_loansNFT).LOANS_CONTRACT() != _loans`.
   * Invalidates the cached NAV; the existing exchange likely becomes incompatible and must be re-pointed via `setExchange`.
   * @param _loans Address of the new ILoans contract
   * @param _loansNFT Address of the new ILoansNFT contract
   */
  function setLoans(address _loans, address _loansNFT) external;

  // ──────────────── Shareholder Functions (ERC-7540) ─────────────

  /**
   * @notice Cancels a pending deposit request and returns assets to the receiver
   * @param controller The controller whose deposit request to cancel
   * @param receiver The address to receive the returned assets
   * @return assets The amount of assets returned
   */
  function cancelDepositRequest(address controller, address receiver) external returns (uint256 assets);

  /**
   * @notice Cancels a pending redeem request and returns shares to the receiver
   * @param controller The controller whose redeem request to cancel
   * @param receiver The address to receive the unlocked shares
   * @return shares The amount of shares returned
   */
  function cancelRedeemRequest(address controller, address receiver) external returns (uint256 shares);

  /**
   * @notice Sets the exchange contract used for atomic loan purchases and sales.
   * @param _exchange Address of the new ILoansExchange contract
   */
  function setExchange(address _exchange) external;

  // ──────────────────────── Admin Functions ───────────────────────

  /**
   * @notice Sets the maximum allowed age of NAV for share-price-sensitive operations
   * @param _maxNavAge New maximum NAV age in seconds
   */
  function setMaxNavAge(uint256 _maxNavAge) external;

  /**
   * @notice Sets the maximum allowed duration for a NAV computation
   * @param _maxNavComputationTime New maximum computation time in seconds
   */
  function setMaxNavComputationTime(uint256 _maxNavComputationTime) external;

  // ────────────────────────── View Functions ──────────────────────

  /// @notice Returns the most recently finalized NAV value
  function nav() external view returns (uint256);

  /**
   * @notice Returns the current share price as `lastNav * 1e18 / shareToken.totalSupply()`.
   * @dev Because share tokens use 18 decimals, the result inherits the asset token's decimals
   * (e.g. 1e6 precision for an asset with 6 decimals like USDC, 1e18 for an 18-decimal asset).
   * @return price Share price denominated in the asset token's smallest unit per 1e18 shares
   */
  function sharePrice() external view returns (uint256 price);

  /// @notice Maximum allowed age (seconds) of NAV for share-price-sensitive operations
  function maxNavAge() external view returns (uint256);

  /// @notice Maximum allowed duration (seconds) for a NAV computation before it is restarted
  function maxNavComputationTime() external view returns (uint256);

  /// @notice Timestamp when the current NAV computation started (0 when idle)
  function navStart() external view returns (uint256);

  /// @notice Timestamp of the most recent completed NAV computation
  function lastNavUpdate() external view returns (uint256);

  /// @notice The current NAV calculator contract
  function calculator() external view returns (INavCalculator);

  /// @notice Number of loans currently included in NAV computation
  function navLoanCount() external view returns (uint256);

  /// @notice Returns the loan ID at the given position in the curated loan list
  function navLoanIdAt(uint256 index) external view returns (uint64);

  /// @notice Returns whether the given loan is currently in the curated loan list
  function isInNav(uint64 loanId) external view returns (bool);
}
