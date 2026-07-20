// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IGuardianAccessControl} from "contracts/misc/interfaces/IGuardianAccessControl.sol";

/**
 * @title GuardianAccessControl
 * @notice Base access-control contract providing a two-tier guardian / admin
 *         role model on top of OpenZeppelin AccessControl.
 *         Guardian is the role-admin for all roles.
 *         Includes OZ Pausable with pause() gated to admin/guardian and
 *         unpause() restricted to guardian only.
 */
abstract contract GuardianAccessControl is AccessControl, Pausable, IGuardianAccessControl {
  /// @inheritdoc IGuardianAccessControl
  bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

  /// @inheritdoc IGuardianAccessControl
  bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

  /// @inheritdoc IGuardianAccessControl
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  /// @dev Number of accounts holding `GUARDIAN_ROLE`. Used to enforce the
  ///      at-least-one-guardian invariant on role revocation.
  uint256 internal guardianCount;

  /// @notice Restricts access to `ADMIN_ROLE` or `GUARDIAN_ROLE` holders.
  modifier onlyAdminOrGuardian() {
    require(_isAdminOrGuardian(msg.sender), AccessControlUnauthorizedAccount(msg.sender, ADMIN_ROLE));
    _;
  }

  /**
   * @notice Allows a guardian to update the role-admin of any role except `GUARDIAN_ROLE`.
   * @param role The role whose admin is being changed.
   * @param adminRole The new admin role.
   */
  function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(GUARDIAN_ROLE) {
    if (role == GUARDIAN_ROLE) revert CannotChangeGuardianAdmin();
    _setRoleAdmin(role, adminRole);
  }

  /// @notice Pauses the contract. Callable by admin, guardian, or pauser.
  function pause() external virtual {
    require(
      _isAdminOrGuardian(msg.sender) || hasRole(PAUSER_ROLE, msg.sender),
      AccessControlUnauthorizedAccount(msg.sender, PAUSER_ROLE)
    );
    _pause();
  }

  /// @notice Unpauses the contract. Callable by guardian only.
  function unpause() external virtual onlyRole(GUARDIAN_ROLE) {
    _unpause();
  }

  /**
   * @notice Disabled. Roles are managed exclusively by the guardian via `revokeRole`;
   *         self-renouncing could permanently strip access (e.g. the guardian role,
   *         which administers all other roles).
   * @dev Always reverts with `RenounceRoleDisabled`.
   */
  function renounceRole(bytes32, address) public virtual override(AccessControl, IAccessControl) {
    revert RenounceRoleDisabled();
  }

  /**
   * @notice Initialises the role hierarchy and grants `GUARDIAN_ROLE`.
   * @dev Must be called exactly once from the concrete constructor.
   * @param initialGuardian Address that receives `GUARDIAN_ROLE`.
   */
  function _initGuardian(address initialGuardian) internal {
    if (initialGuardian == address(0)) revert InvalidGuardian();

    // Lock OpenZeppelin's DEFAULT_ADMIN_ROLE under guardian control.
    // Without this, DEFAULT_ADMIN_ROLE is its own role-admin (bytes32(0)),
    // meaning anyone granted it could escalate to any role.
    _setRoleAdmin(DEFAULT_ADMIN_ROLE, GUARDIAN_ROLE);

    _setRoleAdmin(GUARDIAN_ROLE, GUARDIAN_ROLE);
    _setRoleAdmin(ADMIN_ROLE, GUARDIAN_ROLE);
    _setRoleAdmin(PAUSER_ROLE, GUARDIAN_ROLE);
    _grantRole(GUARDIAN_ROLE, initialGuardian);
  }

  /**
   * @dev Returns true if the account holds `ADMIN_ROLE` or `GUARDIAN_ROLE`.
   */
  function _isAdminOrGuardian(address account) internal view returns (bool) {
    return hasRole(ADMIN_ROLE, account) || hasRole(GUARDIAN_ROLE, account);
  }

  /// @dev Tracks the guardian count so revocations can enforce the at-least-one-guardian invariant.
  function _grantRole(bytes32 role, address account) internal virtual override returns (bool granted) {
    granted = super._grantRole(role, account);
    if (granted && role == GUARDIAN_ROLE) guardianCount++;
  }

  /// @dev Reverts with `LastGuardian` when revoking would leave zero guardians.
  function _revokeRole(bytes32 role, address account) internal virtual override returns (bool revoked) {
    revoked = super._revokeRole(role, account);
    if (revoked && role == GUARDIAN_ROLE) {
      if (guardianCount == 1) revert LastGuardian();
      guardianCount--;
    }
  }
}
