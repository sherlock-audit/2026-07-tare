// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

/**
 * @title IRescuable
 * @notice Interface for contracts that allow a guardian to rescue ERC20 and ERC721 tokens
 *         accidentally sent to the contract.
 */
interface IRescuable {
  /** @notice Emitted when the recovery address (destination for rescued tokens) is updated. */
  event RecoveryAddressSet(address indexed recoveryAddress);
  /** @notice Emitted when ERC20 tokens are rescued and forwarded to the recovery address. */
  event ERC20TokensRescued(address indexed token, uint256 amount, address indexed to);
  /** @notice Emitted when an ERC721 token is rescued and forwarded to the recovery address. */
  event ERC721TokensRescued(address indexed token, uint256 tokenId, address indexed to);

  /** @notice Thrown when a rescue is attempted before a recovery address has been set. */
  error RecoveryAddressNotSet();
  /** @notice Thrown when the recovery address is set to the zero address. */
  error InvalidRecoveryAddress();

  /** @notice Returns the address that rescued tokens are sent to. */
  function recoveryAddress() external view returns (address);

  /**
   * @notice Set the recovery address for rescued tokens.
   * @param recoveryAddress_ The new recovery address (must be non-zero).
   */
  function setRecoveryAddress(address recoveryAddress_) external;

  /**
   * @notice Rescue ERC20 tokens accidentally sent to this contract.
   * @param token The ERC20 token address to rescue.
   * @param amount The maximum amount to rescue (actual rescued amount is capped at balance).
   * @return rescued The actual amount rescued.
   */
  function rescueERC20Tokens(address token, uint256 amount) external returns (uint256 rescued);

  /**
   * @notice Rescue an ERC721 token accidentally sent to this contract.
   * @param token The ERC721 token contract address.
   * @param tokenId The token ID to rescue.
   */
  function rescueERC721Tokens(address token, uint256 tokenId) external;
}
