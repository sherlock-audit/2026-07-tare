// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {GuardianAccessControl} from "contracts/misc/GuardianAccessControl.sol";
import {ILoans, LoanValue, LoanStatus} from "contracts/interfaces/ILoans.sol";
import {INavCalculator, ValuationBucket} from "contracts/interfaces/INavCalculator.sol";

/**
 * @title NavCalculator
 * @notice Default loan valuation strategy for the Portfolio Vault.
 * Fetches loan data from the Loans contract and applies configurable
 * DPD-based discount factors to loan face values. Each of 6 buckets
 * (Current, DQ30, DQ60, DQ90, DQ120, ChargedOff) has an independently
 * configurable factor in WAD (1e18 = 100%).
 * Additionally, it supports a portfolio-level adjustment factor that can be applied to
 * the aggregated NAV after summing individual loan values, allowing for manual adjustments
 * to the overall portfolio valuation.
 */
contract NavCalculator is INavCalculator, GuardianAccessControl {
  uint256 internal constant WAD_UNIT = 1e18; // 100% in WAD
  uint256 internal constant INITIAL_MAX_PORTFOLIO_FACTOR = 2e18;

  bytes32 public constant CALCULATING_AGENT = keccak256("CALCULATING_AGENT");

  mapping(ValuationBucket bucket => uint256 factor) public discountFactors;
  uint256 public portfolioFactor;
  uint256 public maxPortfolioFactor;

  /// @inheritdoc INavCalculator
  uint256 public configurationVersion;

  // ─────────────────────── Modifiers ────────────────

  /**
   * @dev Bumps `configurationVersion` after the decorated function runs so external
   *      consumers (e.g. `PortfolioVault`) detect that any cached NAV computed
   *      against the previous configuration is now stale.
   */
  modifier bumpsConfigurationVersion() {
    _;
    _bumpConfigurationVersion();
  }

  /**
   * @notice Deploys the NavCalculator with initial discount factors
   * @param initialGuardian Address that receives GUARDIAN_ROLE
   * @param initialFactors Array of 8 discount factors ordered by ValuationBucket enum:
   *   [Current, DQ30, DQ60, DQ90, DQ120, ChargedOff, Closed, Cancelled]
   */
  constructor(address initialGuardian, uint256[8] memory initialFactors) {
    require(initialGuardian != address(0), ZeroAddress());

    _initGuardian(initialGuardian);
    _setRoleAdmin(CALCULATING_AGENT, GUARDIAN_ROLE);

    for (uint256 i; i < 8; ++i) {
      require(initialFactors[i] <= WAD_UNIT, FactorExceedsWad());
      discountFactors[ValuationBucket(i)] = initialFactors[i];
    }

    portfolioFactor = WAD_UNIT; // default to 1.0 (no adjustment)
    maxPortfolioFactor = INITIAL_MAX_PORTFOLIO_FACTOR;
    configurationVersion = 1;
  }

  // ──────────────────────── External Functions ────────────────────

  /// @inheritdoc INavCalculator
  function getLoansValue(ILoans loans, uint64[] calldata loanIds) external view returns (uint256 totalValue) {
    LoanValue[] memory loanValues = loans.getLoanValues(loanIds);
    uint256 len = loanValues.length;

    for (uint256 i; i < len; ++i) {
      LoanValue memory loanData = loanValues[i];

      if (loanData.status == LoanStatus.DoesNotExist) continue;

      // Cash already collected for the investor — principal and waterfall-allocated interest sitting
      // in Loans.sol awaiting withdrawal — has no credit risk and contributes at par.
      int256 collectedCash = int256(loanData.investorPrincipalWithdrawable) +
        int256(loanData.investorInterestWithdrawable);
      if (collectedCash < 0) collectedCash = 0;

      // Investor principal still out with the borrower — the only portion exposed to credit risk
      // and the only portion the bucket factor applies to.
      int256 unreturnedInvestorPrincipal = int256(loanData.outstandingInvestorPrincipal) -
        int256(loanData.investorPrincipalWithdrawable);
      if (unreturnedInvestorPrincipal < 0) unreturnedInvestorPrincipal = 0;

      uint256 factoredPrincipal = (uint256(unreturnedInvestorPrincipal) *
        _bucketFactor(loanData.status, loanData.nextDueDate)) / WAD_UNIT;

      totalValue += factoredPrincipal + uint256(collectedCash);
    }
  }

  /// @inheritdoc INavCalculator
  function applyPortfolioAdjustment(uint256 rawValue) external view returns (uint256) {
    return (rawValue * portfolioFactor) / WAD_UNIT;
  }

  /// @inheritdoc INavCalculator
  function setPortfolioFactor(uint256 factor) external onlyRole(CALCULATING_AGENT) bumpsConfigurationVersion {
    require(factor <= maxPortfolioFactor, FactorExceedsCap());
    portfolioFactor = factor;
    emit PortfolioFactorUpdated(factor);
  }

  /// @inheritdoc INavCalculator
  function setMaxPortfolioFactor(uint256 newMax) external onlyRole(GUARDIAN_ROLE) {
    maxPortfolioFactor = newMax;
    emit MaxPortfolioFactorUpdated(newMax);

    // Clamp current portfolio factor if it now exceeds the new cap.
    if (portfolioFactor > newMax) {
      portfolioFactor = newMax;
      _bumpConfigurationVersion();
      emit PortfolioFactorUpdated(newMax);
    }
  }

  /// @inheritdoc INavCalculator
  function setDiscountFactor(
    ValuationBucket bucket,
    uint256 factor
  ) external onlyRole(CALCULATING_AGENT) bumpsConfigurationVersion {
    require(factor <= WAD_UNIT, FactorExceedsWad());
    discountFactors[bucket] = factor;
    emit DiscountFactorUpdated(bucket, factor);
  }

  // ─────────────────────── View Functions ─────────────────────────

  /// @inheritdoc INavCalculator
  function getDiscountFactor(ValuationBucket bucket) external view returns (uint256) {
    return discountFactors[bucket];
  }

  // ───────────────────── Internal Functions ─────────────────────

  /**
   * @dev Returns the discount factor for a given loan status and next-due date.
   *      Active loans use a DPD-based bucket (Current, or DQ30 through DQ120 when
   *      overdue); ChargedOff, Closed and Cancelled loans use their matching status
   *      bucket; all other statuses (Created, FullyFunded, FullyPaid) are valued at
   *      par (1.0 in WAD).
   */
  function _bucketFactor(LoanStatus status, uint48 nextDueDate) internal view returns (uint256) {
    if (status == LoanStatus.Active) {
      ValuationBucket bucket = ValuationBucket.Current;
      if (nextDueDate != 0 && block.timestamp > nextDueDate) {
        uint256 dpd = (block.timestamp - nextDueDate) / 1 days;
        if (dpd > 120) bucket = ValuationBucket.DQ120;
        else if (dpd > 90) bucket = ValuationBucket.DQ90;
        else if (dpd > 60) bucket = ValuationBucket.DQ60;
        else if (dpd > 30) bucket = ValuationBucket.DQ30;
      }
      return discountFactors[bucket];
    }
    if (status == LoanStatus.ChargedOff) return discountFactors[ValuationBucket.ChargedOff];
    if (status == LoanStatus.Closed) return discountFactors[ValuationBucket.Closed];
    if (status == LoanStatus.Cancelled) return discountFactors[ValuationBucket.Cancelled];
    return WAD_UNIT;
  }

  /**
   * @dev Increments `configurationVersion` and emits `ConfigurationVersionBumped`.
   *      Called by `bumpsConfigurationVersion` and directly by `setMaxPortfolioFactor`
   *      when clamping forces a factor change.
   */
  function _bumpConfigurationVersion() internal {
    unchecked {
      ++configurationVersion;
    }
    emit ConfigurationVersionBumped(configurationVersion);
  }
}
