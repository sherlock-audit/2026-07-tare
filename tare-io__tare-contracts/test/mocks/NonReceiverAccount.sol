// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/**
 * @notice A contract account that does NOT implement `IERC721Receiver`, standing in for the
 *         Safe accounts this system actually uses. `safeTransferFrom` reverts on the receiver
 *         check when sending here; `transferFrom` succeeds.
 */
contract NonReceiverAccount {}
