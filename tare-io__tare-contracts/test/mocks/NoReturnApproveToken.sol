// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Token whose `approve` returns no data (USDT-style), to exercise the empty-return branch.
contract NoReturnApproveToken {
  function approve(address, uint256) external {}

  function transferFrom(address, address, uint256) external pure returns (bool) {
    return true;
  }
}
