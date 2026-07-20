// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Enum} from "safe-smart-account/common/Enum.sol";

/**
 * @title IModuleManager
 * @notice Minimal Gnosis Safe ModuleManager surface used by Tare contracts to enable
 *         modules and execute calls from enabled modules.
 */
interface IModuleManager {
  /**
   * @notice Enables a module on the Safe so it may execute transactions via
   *         `execTransactionFromModule*` without owner signatures.
   * @param module The address of the module contract to enable.
   */
  function enableModule(address module) external;

  /**
   * @notice Executes a transaction from an enabled module and returns the raw return data.
   * @param to The destination address of the call.
   * @param value The amount of native currency (wei) to send with the call.
   * @param data The calldata to send.
   * @param operation The operation type (Call or DelegateCall).
   * @return success Whether the underlying call succeeded.
   * @return returnData The raw return data from the call.
   */
  function execTransactionFromModuleReturnData(
    address to,
    uint256 value,
    bytes memory data,
    Enum.Operation operation
  ) external returns (bool success, bytes memory returnData);
}
