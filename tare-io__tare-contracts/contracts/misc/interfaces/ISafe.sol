// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Enum} from "safe-smart-account/common/Enum.sol";

/**
 * @title Matching interface for Safe contract version 1.4.1-3
 */
interface ISafe {
  function nonce() external view returns (uint256);

  function isModuleEnabled(address module) external view returns (bool);

  function getThreshold() external view returns (uint256);

  function isOwner(address owner) external view returns (bool);
  /**
   * @dev Sets up the Safe with initial owners, threshold, and other configuration.
   * @param _owners List of owner addresses.
   * @param _threshold Number of required confirmations for a transaction.
   * @param to Address for optional delegate call.
   * @param data Data for optional delegate call.
   * @param fallbackHandler Handler for fallback calls.
   * @param paymentToken Token address for payment (0 for ETH).
   * @param payment Amount for payment.
   * @param paymentReceiver Address to receive payment.
   */
  function setup(
    address[] memory _owners,
    uint256 _threshold,
    address to,
    bytes memory data,
    address fallbackHandler,
    address paymentToken,
    uint256 payment,
    address payable paymentReceiver
  ) external;

  function execTransactionFromModuleReturnData(
    address to,
    uint256 value,
    bytes memory data,
    uint8 operation
  ) external returns (bool success, bytes memory returnData);

  function execTransaction(
    address to,
    uint256 value,
    bytes calldata data,
    Enum.Operation operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address payable refundReceiver,
    bytes memory signatures
  ) external payable returns (bool success);

  function approveHash(bytes32 hashToApprove) external;

  function getTransactionHash(
    address to,
    uint256 value,
    bytes calldata data,
    Enum.Operation operation,
    uint256 safeTxGas,
    uint256 baseGas,
    uint256 gasPrice,
    address gasToken,
    address refundReceiver,
    uint256 _nonce
  ) external view returns (bytes32);
}
