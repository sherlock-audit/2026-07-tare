// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Token whose `approve` returns false, to exercise the approve-return check.
contract FalseApproveToken {
  function approve(address, uint256) external pure returns (bool) {
    return false;
  }

  function balanceOf(address) external pure returns (uint256) {
    return type(uint128).max;
  }
}
