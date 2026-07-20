// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

/**
 * @notice ERC20 spending limit for a `(token, safe, recipient)` route.
 * @dev `amount = type(uint208).max` is treated as unlimited and is not decremented per transfer.
 *      `validUntil = type(uint48).max` means no expiry.
 */
struct Allowance {
  uint208 amount;
  uint48 validUntil;
}

/**
 * @notice Blanket ERC721 transfer authorization for a `(collection, safe, recipient)` route.
 * @dev Mirrors `setApprovalForAll` semantics: a single boolean covers any tokenId of `collection`.
 */
struct NFTAllowance {
  bool allowed;
  uint48 validUntil;
}

/**
 * @title ITrustedSpender
 * @notice Lets per-safe delegates move tokens (ERC20 and ERC721) out of Safe accounts to
 *         pre-approved recipient routes, capped by per-route allowances.
 * @dev Safes must approve this contract beforehand (`approve` for ERC20,
 *      `setApprovalForAll` for ERC721); this contract does not hold custody.
 */
interface ITrustedSpender {
  /** @notice Emitted when `delegate` is authorized to spend on behalf of `safe`. */
  event DelegateAdded(address indexed safe, address indexed delegate);
  /** @notice Emitted when `delegate`'s authorization for `safe` is revoked. */
  event DelegateRemoved(address indexed safe, address indexed delegate);

  /**
   * @notice Emitted when an ERC20 allowance is set for the `(token, from, to)` route.
   * @param token ERC20 token address.
   * @param from Safe account that holds the funds.
   * @param to Authorized recipient.
   * @param amount New allowance amount (in token base units).
   * @param validUntil Timestamp until which the allowance is valid.
   */
  event AllowanceSet(
    address indexed token,
    address indexed from,
    address indexed to,
    uint256 amount,
    uint48 validUntil
  );

  /**
   * @notice Emitted when an ERC721 blanket allowance is set for the `(collection, from, to)` route.
   * @param collection ERC721 collection address.
   * @param from Safe account that holds the NFTs.
   * @param to Authorized recipient.
   * @param allowed Whether transfers along the route are currently permitted.
   * @param validUntil Timestamp until which the allowance is valid.
   */
  event NFTAllowanceSet(
    address indexed collection,
    address indexed from,
    address indexed to,
    bool allowed,
    uint48 validUntil
  );

  /**
   * @notice Emitted when an ERC721 transfer is executed through this contract.
   * @param collection ERC721 collection address.
   * @param from Safe account the NFT was transferred from.
   * @param to Recipient that received the NFT.
   * @param tokenId Token id that was transferred.
   * @param delegate Delegate that triggered the transfer.
   */
  event NFTTransferExecuted(
    address indexed collection,
    address indexed from,
    address indexed to,
    uint256 tokenId,
    address delegate
  );

  /** @notice Thrown when the caller is not an authorized delegate for the Safe. */
  error NotADelegate();
  /** @notice Thrown when a zero address is supplied where one is not permitted. */
  error ZeroAddress();
  /** @notice Thrown when the ERC20 allowance is below the requested transfer amount. */
  error InsufficientAllowance();
  /** @notice Thrown when an allowance has expired. */
  error AllowanceExpired();
  /** @notice Thrown when `validUntil` is not strictly in the future. */
  error InvalidAllowanceDeadline();
  /** @notice Thrown when the caller is not the Safe itself nor an authorized admin/guardian. */
  error UnauthorizedCaller();
  /** @notice Thrown when an NFT transfer is attempted along a route that is not allowed. */
  error NFTTransferNotAllowed();

  /**
   * @notice Authorize `delegate` to spend on behalf of `safe`.
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
   * @notice Set the ERC20 spending limit for a `(token, from, to)` route.
   * @dev Callable by the Safe itself or by a guardian. Pass `type(uint208).max` for unlimited
   *      and `type(uint48).max` for no expiry.
   * @param token ERC20 token address.
   * @param from Safe account that holds the funds.
   * @param to Authorized recipient.
   * @param amount Maximum spendable amount.
   * @param validUntil Timestamp until which the allowance is valid. Must be strictly greater
   *        than `block.timestamp`.
   */
  function setAllowance(address token, address from, address to, uint208 amount, uint48 validUntil) external;

  /**
   * @notice Transfer `amount` of `token` from `from` to `to` using an existing allowance.
   * @dev Caller must be an authorized delegate of `from`. Allowance is decremented unless infinite.
   * @param token ERC20 token to transfer.
   * @param from Safe account to transfer from.
   * @param to Recipient address.
   * @param amount Amount to transfer.
   */
  function executeTransfer(address token, address from, address to, uint256 amount) external;

  /**
   * @notice Returns the ERC20 allowance for a `(token, from, to)` route.
   * @param token ERC20 token address.
   * @param from Safe account.
   * @param to Recipient address.
   * @return amount Remaining allowance amount.
   * @return validUntil Timestamp until which the allowance is valid.
   */
  function getAllowance(
    address token,
    address from,
    address to
  ) external view returns (uint256 amount, uint48 validUntil);

  /**
   * @notice Returns whether `delegate` is currently authorized for `safe`.
   * @param safe Safe account address.
   * @param delegate Potential delegate address.
   */
  function isDelegate(address safe, address delegate) external view returns (bool);

  /**
   * @notice Set a blanket ERC721 transfer authorization for a `(collection, from, to)` route.
   * @dev Callable by the Safe itself or by a guardian. The authorization covers any tokenId.
   * @param collection ERC721 collection address.
   * @param from Safe account that holds the NFTs.
   * @param to Authorized recipient.
   * @param allowed Whether delegates may move any tokenId along the route.
   * @param validUntil Timestamp until which the allowance is valid (`type(uint48).max` for no
   *        expiry). Must be strictly greater than `block.timestamp`.
   */
  function setNFTAllowance(address collection, address from, address to, bool allowed, uint48 validUntil) external;

  /**
   * @notice Transfer `tokenId` of `collection` from `from` to `to`.
   * @dev Caller must be an authorized delegate of `from`. Uses `safeTransferFrom`, so recipient
   *      contracts must implement `IERC721Receiver`.
   * @param collection ERC721 collection address.
   * @param from Safe account to transfer from.
   * @param to Recipient address.
   * @param tokenId Token id to transfer.
   */
  function executeNFTTransfer(address collection, address from, address to, uint256 tokenId) external;

  /**
   * @notice Returns the stored NFT allowance for a `(collection, from, to)` route.
   * @param collection ERC721 collection address.
   * @param from Safe account.
   * @param to Recipient address.
   * @return allowed Whether the route is flagged as allowed.
   * @return validUntil Timestamp until which the allowance is valid.
   */
  function getNFTAllowance(
    address collection,
    address from,
    address to
  ) external view returns (bool allowed, uint48 validUntil);

  /**
   * @notice Returns whether `(collection, from, to)` is currently authorized for NFT transfers.
   * @dev Returns `true` only if the route is flagged allowed AND the allowance has not expired.
   * @param collection ERC721 collection address.
   * @param from Safe account.
   * @param to Recipient address.
   */
  function isNFTTransferAllowed(address collection, address from, address to) external view returns (bool);

  /** @notice Returns whether `delegate` is currently authorized for `safe`. */
  function delegates(address safe, address delegate) external view returns (bool authorized);
}
