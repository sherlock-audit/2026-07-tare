// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Enum} from "safe-smart-account/common/Enum.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITrustedCalls} from "contracts/interfaces/ITrustedCalls.sol";
import {IModuleManager} from "contracts/misc/interfaces/IModuleManager.sol";
import {Rescuable} from "contracts/misc/Rescuable.sol";

/**
 * @title TrustedCalls
 * @notice Safe module that lets per-safe delegates execute a globally whitelisted set of
 *         function calls on behalf of Safe accounts.
 * @dev A single deployment serves multiple Safes: the trusted call registry is global
 *      while the delegate set is per-Safe.
 */
contract TrustedCalls is ITrustedCalls, Rescuable {
  using SafeERC20 for IERC20;

  /// @inheritdoc ITrustedCalls
  mapping(bytes32 trustKey => bool isTrusted) public trustedCalls;

  /// @inheritdoc ITrustedCalls
  mapping(address safe => mapping(address delegate => bool authorized)) public delegates;

  /**
   * @notice Restricts function to Safe itself or an admin/guardian.
   * @param safe The Safe address that must match `msg.sender` (or `msg.sender` must be admin/guardian).
   */
  modifier safeOrAdmin(address safe) {
    require(msg.sender == safe || _isAdminOrGuardian(msg.sender), UnauthorizedCaller());
    _;
  }

  /**
   * @notice Restricts function to Safe itself or a guardian (excludes admin).
   * @param safe The Safe address that must match `msg.sender` (or `msg.sender` must be a guardian).
   */
  modifier safeOrGuardian(address safe) {
    require(msg.sender == safe || hasRole(GUARDIAN_ROLE, msg.sender), UnauthorizedCaller());
    _;
  }

  constructor(address initialGuardian, address initialRecoveryAddress) {
    _initGuardian(initialGuardian);
    _initRecoveryAddress(initialRecoveryAddress);
  }

  /// @inheritdoc ITrustedCalls
  function addTrustedCall(address target, bytes4 selector) external whenNotPaused onlyRole(GUARDIAN_ROLE) {
    require(selector != bytes4(0), InvalidSelector());

    bytes32 key = getTrustKey(target, selector);
    trustedCalls[key] = true;

    emit TrustedCallAdded(target, selector);
  }

  /// @inheritdoc ITrustedCalls
  function addTrustedCalls(
    address[] calldata targets,
    bytes4[] calldata selectors
  ) external whenNotPaused onlyRole(GUARDIAN_ROLE) {
    uint256 length = targets.length;
    require(length == selectors.length, LengthMismatch());
    require(length > 0, EmptyBatch());

    for (uint256 i = 0; i < length; ++i) {
      require(selectors[i] != bytes4(0), InvalidSelector());

      bytes32 key = getTrustKey(targets[i], selectors[i]);
      trustedCalls[key] = true;

      emit TrustedCallAdded(targets[i], selectors[i]);
    }
  }

  /// @inheritdoc ITrustedCalls
  function removeTrustedCall(address target, bytes4 selector) external onlyAdminOrGuardian {
    bytes32 key = getTrustKey(target, selector);
    trustedCalls[key] = false;

    emit TrustedCallRemoved(target, selector);
  }

  /// @inheritdoc ITrustedCalls
  function addDelegate(address safe, address delegate) external safeOrGuardian(safe) {
    delegates[safe][delegate] = true;
    emit DelegateAdded(safe, delegate);
  }

  /// @inheritdoc ITrustedCalls
  function removeDelegate(address safe, address delegate) external safeOrAdmin(safe) {
    delegates[safe][delegate] = false;
    emit DelegateRemoved(safe, delegate);
  }

  /// @inheritdoc ITrustedCalls
  function executeTrustedCall(
    address safe,
    address target,
    bytes calldata data
  ) external whenNotPaused returns (bool success, bytes memory returnData) {
    // Verify sender is delegate for this Safe
    require(delegates[safe][msg.sender], NotADelegate());

    // Extract function selector (first 4 bytes)
    require(data.length >= 4, InvalidSelector());
    bytes4 selector = bytes4(data[:4]);

    // Verify call is trusted
    bytes32 key = getTrustKey(target, selector);
    require(trustedCalls[key], CallNotTrusted());

    // Execute call via Safe
    (success, returnData) = IModuleManager(payable(safe)).execTransactionFromModuleReturnData(
      target,
      0, // value: no ETH sent
      data,
      Enum.Operation.Call
    );

    require(success, ExecutionFailed());
  }

  /// @inheritdoc ITrustedCalls
  function executeTrustedCallBatch(
    address safe,
    address[] calldata targets,
    bytes[] calldata data
  ) external whenNotPaused returns (bytes[] memory results) {
    uint256 targetsLength = targets.length;

    require(delegates[safe][msg.sender], NotADelegate());
    require(targetsLength == data.length, LengthMismatch());
    require(targetsLength > 0, EmptyBatch());

    results = new bytes[](targetsLength);

    for (uint256 i = 0; i < targetsLength; ++i) {
      require(data[i].length >= 4, InvalidSelector());
      bytes4 selector = bytes4(data[i][:4]);

      bytes32 key = getTrustKey(targets[i], selector);
      require(trustedCalls[key], CallNotTrusted());

      (bool success, bytes memory returnData) = IModuleManager(payable(safe)).execTransactionFromModuleReturnData(
        targets[i],
        0,
        data[i],
        Enum.Operation.Call
      );

      require(success, ExecutionFailed());
      results[i] = returnData;
    }
  }

  /// @inheritdoc ITrustedCalls
  function isTrustedCall(address target, bytes4 selector) external view returns (bool) {
    return trustedCalls[getTrustKey(target, selector)];
  }

  /// @inheritdoc ITrustedCalls
  function isDelegate(address safe, address delegate) external view returns (bool) {
    return delegates[safe][delegate];
  }

  /// @inheritdoc ITrustedCalls
  function getTrustKey(address target, bytes4 selector) public pure returns (bytes32) {
    return keccak256(abi.encodePacked(target, selector));
  }
}
