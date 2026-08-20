// SPDX-License-Identifier: MIT
// Vendored from smartcontractkit/chainlink-brownie-contracts tag 1.3.0
// (contracts/src/v0.8/operatorforwarder/interfaces/IAuthorizedReceiver.sol).
// Byte-for-byte copy; no changes.
pragma solidity ^0.8.0;

interface IAuthorizedReceiver {
  function isAuthorizedSender(address sender) external view returns (bool);

  function getAuthorizedSenders() external returns (address[] memory);

  function setAuthorizedSenders(address[] calldata senders) external;
}
