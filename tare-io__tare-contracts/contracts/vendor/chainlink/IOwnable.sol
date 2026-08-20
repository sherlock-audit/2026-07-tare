// SPDX-License-Identifier: MIT
// Vendored from smartcontractkit/chainlink-brownie-contracts tag 1.3.0
// (contracts/src/v0.8/shared/interfaces/IOwnable.sol).
// Byte-for-byte copy; no changes.
pragma solidity ^0.8.0;

interface IOwnable {
  function owner() external returns (address);

  function transferOwnership(address recipient) external;

  function acceptOwnership() external;
}
