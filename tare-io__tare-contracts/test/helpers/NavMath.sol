// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoanValue} from "contracts/interfaces/ILoans.sol";

/// @notice Decomposes a LoanValue into the two inputs the NAV formula consumes:
/// `principal` (credit-exposed, discounted by the bucket factor) and `cash`
/// (already collected for the investor, valued at par). Mirrors the
/// int256-intermediate + clamp pattern used in NavCalculator.sol.
function splitLoanValue(LoanValue memory value) pure returns (uint256 principal, uint256 cash) {
  int256 principalSigned = int256(value.outstandingInvestorPrincipal) - int256(value.investorPrincipalWithdrawable);
  principal = principalSigned > 0 ? uint256(principalSigned) : 0;

  int256 cashSigned = int256(value.investorPrincipalWithdrawable) + int256(value.investorInterestWithdrawable);
  cash = cashSigned > 0 ? uint256(cashSigned) : 0;
}
