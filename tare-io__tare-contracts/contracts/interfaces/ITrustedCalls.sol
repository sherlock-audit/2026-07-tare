// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

/**
 * @title ITrustedCalls
 * @notice Safe module interface that lets per-safe delegates execute a globally whitelisted
 *         set of function calls on behalf of their Safe accounts.
 * @dev A single deployment serves multiple Safes: the trusted call registry is global
 *      (keyed by `(target, selector)`), while the delegate set is per-Safe.
 */
interface ITrustedCalls {
  /** @notice Emitted when admins add `(target, selector)` to the global trusted call registry. */
  event TrustedCallAdded(address indexed target, bytes4 selector);
  /** @notice Emitted when admins remove `(target, selector)` from the global trusted call registry. */
  event TrustedCallRemoved(address indexed target, bytes4 selector);
  /** @notice Emitted when `delegate` is authorized to execute trusted calls on behalf of `safe`. */
  event DelegateAdded(address indexed safe, address indexed delegate);
  /** @notice Emitted when `delegate`'s authorization for `safe` is revoked. */
  event DelegateRemoved(address indexed safe, address indexed delegate);

  /** @notice Thrown when the caller is not an authorized delegate for the target Safe. */
  error NotADelegate();
  /** @notice Thrown when `(target, selector)` is not present in the trusted call registry. */
  error CallNotTrusted();
  /** @notice Thrown when the underlying `execTransactionFromModule` call reverts. */
  error ExecutionFailed();
  /** @notice Thrown when the supplied calldata is shorter than 4 bytes or the selector is zero. */
  error InvalidSelector();
  /** @notice Thrown when the caller is not the Safe itself nor an authorized admin/guardian. */
  error UnauthorizedCaller();
  /** @notice Thrown when an ERC20 transfer attempted by the module fails. */
  error TransferFailed();
  /** @notice Thrown when batch input arrays have mismatched lengths. */
  error LengthMismatch();
  /** @notice Thrown when a batch operation is called with zero entries. */
  error EmptyBatch();

  /**
   * @notice Add a single function to the global trusted call registry. Guardian only.
   * @param target Contract address containing the function.
   * @param selector 4-byte function selector to whitelist.
   */
  function addTrustedCall(address target, bytes4 selector) external;

  /**
   * @notice Add multiple functions to the global trusted call registry in a single transaction.
   * @dev Guardian only. `targets` and `selectors` must be the same length and non-empty.
   * @param targets Contract addresses containing the functions.
   * @param selectors 4-byte function selectors, one per `targets` entry.
   */
  function addTrustedCalls(address[] calldata targets, bytes4[] calldata selectors) external;

  /**
   * @notice Remove a function from the global trusted call registry. Admin or guardian only.
   * @param target Contract address.
   * @param selector Function selector to remove.
   */
  function removeTrustedCall(address target, bytes4 selector) external;

  /**
   * @notice Authorize `delegate` to execute trusted calls on behalf of `safe`.
   * @dev Callable by the Safe itself or by a guardian.
   * @param safe The Safe account address.
   * @param delegate Address to authorize as delegate.
   */
  function addDelegate(address safe, address delegate) external;

  /**
   * @notice Revoke `delegate`'s authorization for `safe`.
   * @dev Callable by the Safe itself or by an admin/guardian.
   * @param safe The Safe account address.
   * @param delegate Address to remove as delegate.
   */
  function removeDelegate(address safe, address delegate) external;

  /**
   * @notice Execute a single trusted call on behalf of `safe`.
   * @dev Caller must be a delegate of `safe`. `data` must begin with a selector that, together
   *      with `target`, is present in the trusted call registry.
   * @param safe Safe account to execute from.
   * @param target Target contract address.
   * @param data Complete calldata, including the 4-byte selector.
   * @return success Whether the underlying call succeeded.
   * @return returnData Raw return data from the underlying call.
   */
  function executeTrustedCall(
    address safe,
    address target,
    bytes calldata data
  ) external returns (bool success, bytes memory returnData);

  /**
   * @notice Execute a batch of trusted calls on behalf of `safe` in a single transaction.
   * @dev Caller must be a delegate of `safe`. Every `(targets[i], selector)` pair must be trusted.
   *      Reverts if any underlying call reverts; nothing is committed unless every call succeeds.
   * @param safe Safe account to execute from.
   * @param targets Per-call target contract addresses.
   * @param data Per-call calldata; `data[i]` must begin with a 4-byte selector.
   * @return results Raw return data from each underlying call, in input order.
   */
  function executeTrustedCallBatch(
    address safe,
    address[] calldata targets,
    bytes[] calldata data
  ) external returns (bytes[] memory results);

  /**
   * @notice Returns whether `(target, selector)` is in the global trusted call registry.
   * @param target Contract address.
   * @param selector Function selector.
   */
  function isTrustedCall(address target, bytes4 selector) external view returns (bool);

  /**
   * @notice Returns whether `delegate` is currently authorized to act on behalf of `safe`.
   * @param safe Safe account address.
   * @param delegate Potential delegate address.
   */
  function isDelegate(address safe, address delegate) external view returns (bool);

  /**
   * @notice Returns the registry key derived from `(target, selector)`.
   * @param target Contract address.
   * @param selector Function selector.
   * @return The `bytes32` key used in `trustedCalls`.
   */
  function getTrustKey(address target, bytes4 selector) external pure returns (bytes32);

  /** @notice Returns whether the trust key is whitelisted in the global registry. */
  function trustedCalls(bytes32 trustKey) external view returns (bool isTrusted);

  /** @notice Returns whether `delegate` is currently authorized for `safe`. */
  function delegates(address safe, address delegate) external view returns (bool authorized);
}
