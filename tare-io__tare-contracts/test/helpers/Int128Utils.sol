// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

function asUint(int128 x) pure returns (uint256) {
  return uint256(int256(x));
}
