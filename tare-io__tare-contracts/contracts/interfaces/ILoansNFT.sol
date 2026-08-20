// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

/**
 * @title ILockable
 * @notice ERC-5753 lock surface for ERC721 tokens.
 */
interface ILockable {
  error Unauthorized();
  error AlreadyLocked();
  error InvalidUnlocker();
  error NotUnlocker();
  error TokenLocked();

  /**
   * @notice Emitted when a token is locked to an unlocker.
   * @param unlocker Address permitted to unlock or settle the token while locked
   * @param id Token identifier
   */
  event Lock(address indexed unlocker, uint256 indexed id);

  /**
   * @notice Emitted when a token lock is cleared.
   * @param id Token identifier
   */
  event Unlock(uint256 indexed id);

  /**
   * @notice Locks a token to a designated unlocker.
   * @param unlocker Address permitted to unlock or settle the token
   * @param id Token identifier
   */
  function lock(address unlocker, uint256 id) external;

  /**
   * @notice Clears the lock on a token.
   * @param id Token identifier
   */
  function unlock(uint256 id) external;

  /**
   * @notice Returns the current unlocker for a token.
   * @param tokenId Token identifier
   * @return unlocker Address(0) when unlocked, otherwise the current unlocker
   */
  function getLocked(uint256 tokenId) external view returns (address unlocker);
}

/**
 * @title ILoansNFT
 * @notice Loan NFT interface with ERC-5753-compatible locking support.
 */
interface ILoansNFT is IERC721, IERC721Enumerable, ILockable {
  error InvalidFrom();
  error InvalidTo();

  event BaseURIUpdated(string newBaseURI);

  /**
   * @notice Emitted when the guardian performs a privileged transfer that
   * bypasses ERC721 approvals for an unlocked token.
   * @param from Address the token was transferred from
   * @param to Address the token was transferred to
   * @param tokenId Token identifier
   */
  event ForceTransfer(address indexed from, address indexed to, uint256 indexed tokenId);

  /**
   * @notice Returns the Loans contract authorized to mint new loan NFTs.
   * @return loansContract Loans contract address
   */
  function LOANS_CONTRACT() external view returns (address loansContract);

  /**
   * @notice Mints a new loan NFT.
   * @param to Recipient address
   * @param tokenId Token identifier
   */
  function mint(address to, uint256 tokenId) external;

  /**
   * @notice Returns the owner and unlocker of a token in a single call.
   * @dev Combines `ownerOf` and `getLocked` so callers iterating over many
   *      tokens only pay one external-call.
   * @param tokenId Token identifier
   * @return owner Current token owner
   * @return unlocker Current unlocker address (zero if the token is unlocked)
   */
  function ownerAndUnlocker(uint256 tokenId) external view returns (address owner, address unlocker);

  /**
   * @notice Updates the collection base URI.
   * @param newBaseURI New base URI prefix
   */
  function setBaseURI(string calldata newBaseURI) external;

  /**
   * @notice Guardian-only transfer that bypasses ERC721 approvals. Intended as
   * a rescue path for NFTs stranded in a stuck receiver after settlement.
   * @dev Reverts while the token is locked; protocol-specific locks must be
   * cleared by the lock owner first. Invokes `onERC721Received` on contract
   * recipients (reverts `ERC721InvalidReceiver` on a non-compliant receiver).
   * Emits the standard ERC721 `Transfer` event in addition to `ForceTransfer`.
   * @param from Current owner of the token
   * @param to Recipient address
   * @param tokenId Token identifier
   */
  function forceTransfer(address from, address to, uint256 tokenId) external;

  /**
   * @notice Monotonic per-address counter incremented on every mint, transfer,
   * and burn that touches `account` (as either sender or receiver).
   * @dev Used by integrators to detect any change to the NFT ownership set of
   * a given address across multiple transactions, regardless of which contract
   * initiated the transfer. The zero address is never bumped.
   * @param account Address whose nonce to read
   * @return nonce Current ownership nonce for `account`
   */
  function ownershipNonce(address account) external view returns (uint256 nonce);
}
