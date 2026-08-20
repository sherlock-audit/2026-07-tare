// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Token whose `approve` reverts, to exercise the module-call failure on the approve leg.
contract RevertingApproveToken {
  function approve(address, uint256) external pure {
    revert("approve reverted");
  }
}
