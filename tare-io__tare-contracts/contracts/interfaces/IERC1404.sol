// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// Restriction code indicating the transfer is allowed.
uint8 constant SUCCESS_CODE = 0;
// Restriction code indicating the sender lacks `SHAREHOLDER_ROLE`.
uint8 constant SENDER_RESTRICTED_CODE = 1;
// Restriction code indicating the recipient lacks `SHAREHOLDER_ROLE`.
uint8 constant RECIPIENT_RESTRICTED_CODE = 2;

string constant SUCCESS_MESSAGE = "SUCCESS";
string constant SENDER_RESTRICTED_MESSAGE = "Sender is not whitelisted";
string constant RECIPIENT_RESTRICTED_MESSAGE = "Recipient is not whitelisted";
// Message returned for any unrecognized restriction code.
string constant UNKNOWN_MESSAGE = "UNKNOWN";

/**
 * @title IERC1404
 * @notice Simple Restricted Token Standard interface for surfacing transfer
 *         restrictions and their human-readable reasons.
 * @dev Restriction code `0` is reserved to indicate a successful (unrestricted)
 *      transfer.
 */
interface IERC1404 {
  /**
   * @notice Returns a restriction code for the proposed transfer.
   * @param from Sender address.
   * @param to Recipient address.
   * @param value Amount being transferred.
   * @return Restriction code, where `0` indicates the transfer is allowed.
   */
  function detectTransferRestriction(address from, address to, uint256 value) external view returns (uint8);

  /**
   * @notice Returns a human-readable message for a restriction code.
   * @param restrictionCode Code previously returned by `detectTransferRestriction`.
   * @return Human-readable explanation of the restriction.
   */
  function messageForTransferRestriction(uint8 restrictionCode) external view returns (string memory);
}
