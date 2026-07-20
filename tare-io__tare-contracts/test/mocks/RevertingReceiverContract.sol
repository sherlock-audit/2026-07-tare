// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Contract that implements `IERC721Receiver` but reverts inside the
///         callback. Used to prove that a code path uses plain `transferFrom`
///         and therefore never invokes `onERC721Received` on the recipient.
contract RevertingReceiverContract is IERC721Receiver {
  error ReceiverHookInvoked();

  function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    revert ReceiverHookInvoked();
  }
}
