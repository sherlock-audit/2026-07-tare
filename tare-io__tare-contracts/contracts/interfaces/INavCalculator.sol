// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {ILoans} from "contracts/interfaces/ILoans.sol";

/**
 * @notice Valuation buckets used to derive a loan's NAV contribution.
 * @dev The first five entries classify Active loans by Days Past Due; the last
 *      three correspond to terminal loan statuses.
 */
enum ValuationBucket {
  Current, // 0–30 DPD
  DQ30, // 31–60 DPD
  DQ60, // 61–90 DPD
  DQ90, // 91–120 DPD
  DQ120, // 121+ DPD
  ChargedOff, // Status == ChargedOff (regardless of DPD)
  Closed, // Status == Closed
  Cancelled // Status == Cancelled
}

/**
 * @title INavCalculator
 * @notice Interface for loan valuation strategies used during NAV computation.
 * Implementations fetch loan data internally and apply delinquency-based
 * discount factors to loan face values.
 *
 * All value inputs and outputs are denominated in the underlying asset's native
 * decimals (e.g. 6 for USDC). Discount and portfolio factors are dimensionless
 * WAD-scaled percentages (1e18 = 100%) used only as intermediate multipliers.
 */
interface INavCalculator {
  // ──────────────────────────── Errors ────────────────────────────

  error FactorExceedsWad();
  error FactorExceedsCap();
  error ZeroAddress();

  // ──────────────────────────── Events ────────────────────────────

  event DiscountFactorUpdated(ValuationBucket indexed bucket, uint256 factor);
  event PortfolioFactorUpdated(uint256 factor);
  event MaxPortfolioFactorUpdated(uint256 newMax);

  /// @notice Emitted whenever a state change affects loan valuation outputs.
  event ConfigurationVersionBumped(uint256 newVersion);

  // ──────────────────────────── Functions ─────────────────────────

  /**
   * @notice Computes the total value of a batch of loans by fetching their data from the provided
   * Loans contract and applying discount factors based on delinquency status.
   * @dev The caller passes the `ILoans` instance to guarantee the calculator and the caller agree
   * on the ledger source for this valuation.
   * @param loans The Loans contract to read loan state from
   * @param loanIds Array of loan IDs to value
   * @return totalValue Sum of all adjusted loan values (in asset decimals)
   */
  function getLoansValue(ILoans loans, uint64[] calldata loanIds) external view returns (uint256 totalValue);

  /**
   * @notice Updates the discount factor for a specific valuation bucket
   * @param bucket The valuation bucket to update
   * @param factor The new discount factor in WAD (1e18 = 100%)
   */
  function setDiscountFactor(ValuationBucket bucket, uint256 factor) external;

  /**
   * @notice Applies the portfolio-level adjustment factor to an aggregated NAV calculation
   * @param rawValue The raw aggregated value from per-loan valuation (in asset decimals)
   * @return adjustedValue The adjusted value (in asset decimals)
   */
  function applyPortfolioAdjustment(uint256 rawValue) external view returns (uint256 adjustedValue);

  /**
   * @notice Updates the portfolio-level adjustment factor
   * @param factor The new factor in WAD (1e18 = 100%)
   */
  function setPortfolioFactor(uint256 factor) external;

  // ─────────────────────── Guardian Functions ─────────────────────

  /**
   * @notice Updates the maximum allowed value for `portfolioFactor`
   * @dev If the current `portfolioFactor` exceeds `newMax`, it is clamped down to `newMax`
   * and a `PortfolioFactorUpdated` event is emitted.
   * @param newMax The new cap in WAD (1e18 = 100%)
   */
  function setMaxPortfolioFactor(uint256 newMax) external;

  // ────────────────────────── View Functions ──────────────────────

  /**
   * @notice Returns the discount factor for a specific valuation bucket
   * @param bucket The valuation bucket to query
   * @return factor The current discount factor in WAD (1e18 = 100%)
   */
  function getDiscountFactor(ValuationBucket bucket) external view returns (uint256 factor);

  /// @notice The portfolio-level adjustment factor in WAD
  function portfolioFactor() external view returns (uint256);

  /// @notice The maximum allowed value for `portfolioFactor`, in WAD
  function maxPortfolioFactor() external view returns (uint256);

  /**
   * @notice Monotonic counter bumped on any state change that affects loan valuation.
   * @dev Consumers (e.g. PortfolioVault) snapshot this value to detect stale NAV after factor updates.
   */
  function configurationVersion() external view returns (uint256);
}
