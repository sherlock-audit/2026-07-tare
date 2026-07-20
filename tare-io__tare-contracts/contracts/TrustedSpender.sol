// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Allowance, ITrustedSpender, NFTAllowance} from "contracts/interfaces/ITrustedSpender.sol";
import {Rescuable} from "contracts/misc/Rescuable.sol";

/**
 * @title TrustedSpender
 * @notice Lets per-safe delegates move tokens (ERC20 and ERC721) out of Safe accounts to
 *         pre-approved recipient routes, capped by per-route allowances.
 * @dev Safes must approve this contract beforehand (`approve` for ERC20,
 *      `setApprovalForAll` for ERC721); this contract does not hold custody.
 */
contract TrustedSpender is ITrustedSpender, Rescuable {
  using SafeERC20 for IERC20;

  /// @inheritdoc ITrustedSpender
  mapping(address safe => mapping(address delegate => bool authorized)) public delegates;

  /** @dev `(token, safe, recipient) => allowance`. Internal; queried via `getAllowance`. */
  mapping(address token => mapping(address from => mapping(address to => Allowance allowance))) internal _allowances;

  /** @dev `(collection, safe, recipient) => NFT allowance`. Internal; queried via `getNFTAllowance`. */
  mapping(address collection => mapping(address from => mapping(address to => NFTAllowance allowance)))
    internal _nftAllowances;

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

  /// @inheritdoc ITrustedSpender
  function addDelegate(address safe, address delegate) external safeOrGuardian(safe) {
    require(safe != address(0) && delegate != address(0), ZeroAddress());

    delegates[safe][delegate] = true;
    emit DelegateAdded(safe, delegate);
  }

  /// @inheritdoc ITrustedSpender
  function removeDelegate(address safe, address delegate) external safeOrAdmin(safe) {
    delegates[safe][delegate] = false;
    emit DelegateRemoved(safe, delegate);
  }

  /// @inheritdoc ITrustedSpender
  function setAllowance(
    address token,
    address from,
    address to,
    uint208 amount,
    uint48 validUntil
  ) external safeOrGuardian(from) {
    require(token != address(0) && from != address(0) && to != address(0), ZeroAddress());
    require(validUntil > block.timestamp, InvalidAllowanceDeadline());

    _allowances[token][from][to] = Allowance({amount: amount, validUntil: validUntil});
    emit AllowanceSet(token, from, to, amount, validUntil);
  }

  /// @inheritdoc ITrustedSpender
  function executeTransfer(address token, address from, address to, uint256 amount) external whenNotPaused {
    // Verify sender is a delegate
    require(delegates[from][msg.sender], NotADelegate());

    // Check allowance exists, is sufficient, and has not expired
    Allowance storage allowance = _allowances[token][from][to];
    require(allowance.amount >= amount, InsufficientAllowance());
    require(block.timestamp <= allowance.validUntil, AllowanceExpired());

    // Update allowance if not infinite
    if (allowance.amount != type(uint208).max) {
      allowance.amount -= uint208(amount);
    }

    IERC20(token).safeTransferFrom(from, to, amount);
  }

  /// @inheritdoc ITrustedSpender
  function getAllowance(
    address token,
    address from,
    address to
  ) external view returns (uint256 amount, uint48 validUntil) {
    Allowance storage allowance = _allowances[token][from][to];
    return (uint256(allowance.amount), allowance.validUntil);
  }

  /// @inheritdoc ITrustedSpender
  function isDelegate(address safe, address delegate) external view returns (bool) {
    return delegates[safe][delegate];
  }

  /// @inheritdoc ITrustedSpender
  function setNFTAllowance(
    address collection,
    address from,
    address to,
    bool allowed,
    uint48 validUntil
  ) external safeOrGuardian(from) {
    require(collection != address(0) && from != address(0) && to != address(0), ZeroAddress());
    require(validUntil > block.timestamp, InvalidAllowanceDeadline());

    _nftAllowances[collection][from][to] = NFTAllowance({allowed: allowed, validUntil: validUntil});
    emit NFTAllowanceSet(collection, from, to, allowed, validUntil);
  }

  /// @inheritdoc ITrustedSpender
  function executeNFTTransfer(address collection, address from, address to, uint256 tokenId) external whenNotPaused {
    require(delegates[from][msg.sender], NotADelegate());

    NFTAllowance storage allowance = _nftAllowances[collection][from][to];
    require(allowance.allowed, NFTTransferNotAllowed());
    require(block.timestamp <= allowance.validUntil, AllowanceExpired());

    IERC721(collection).safeTransferFrom(from, to, tokenId);
    emit NFTTransferExecuted(collection, from, to, tokenId, msg.sender);
  }

  /// @inheritdoc ITrustedSpender
  function getNFTAllowance(
    address collection,
    address from,
    address to
  ) external view returns (bool allowed, uint48 validUntil) {
    NFTAllowance storage allowance = _nftAllowances[collection][from][to];
    return (allowance.allowed, allowance.validUntil);
  }

  /// @inheritdoc ITrustedSpender
  function isNFTTransferAllowed(address collection, address from, address to) external view returns (bool) {
    NFTAllowance storage allowance = _nftAllowances[collection][from][to];
    return allowance.allowed && block.timestamp <= allowance.validUntil;
  }
}
