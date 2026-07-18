// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Minimal contract that does NOT implement IERC721Receiver.
///         Used to test that safeTransferFrom reverts while transferFrom succeeds.
contract NonReceiverContract {
  // Intentionally empty — no onERC721Received
}
