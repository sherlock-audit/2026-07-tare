// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {INavCalculator, ValuationBucket} from "contracts/interfaces/INavCalculator.sol";
import {ILoans} from "contracts/interfaces/ILoans.sol";

contract MockNavCalculator is INavCalculator {
  uint256 public nextValuation;
  uint256 public portfolioFactor = 1e18;
  uint256 public maxPortfolioFactor = 2e18;
  uint256 public configurationVersion = 1;

  function setNextValuation(uint256 value) external {
    nextValuation = value;
  }

  function bumpConfigurationVersion() external {
    unchecked {
      ++configurationVersion;
    }
    emit ConfigurationVersionBumped(configurationVersion);
  }

  function getLoansValue(ILoans, uint64[] calldata) external view returns (uint256) {
    return nextValuation;
  }

  function setDiscountFactor(ValuationBucket, uint256) external {}

  function getDiscountFactor(ValuationBucket) external pure returns (uint256) {
    return 1e18;
  }

  function applyPortfolioAdjustment(uint256 rawValue) external view returns (uint256) {
    return (rawValue * portfolioFactor) / 1e18;
  }

  function setPortfolioFactor(uint256 factor) external {
    portfolioFactor = factor;
  }

  function setMaxPortfolioFactor(uint256 newMax) external {
    maxPortfolioFactor = newMax;
    if (portfolioFactor > newMax) portfolioFactor = newMax;
  }
}
