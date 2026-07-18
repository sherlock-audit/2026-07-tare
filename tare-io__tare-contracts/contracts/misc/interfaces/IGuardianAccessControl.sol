// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IGuardianAccessControl
 * @notice Interface for the `GuardianAccessControl` base contract — a two-tier guardian/admin
 *         role model on top of OpenZeppelin AccessControl.
 */
interface IGuardianAccessControl is IAccessControl {
  /** @notice Thrown when an attempt is made to change the role admin of `GUARDIAN_ROLE`. */
  error CannotChangeGuardianAdmin();
  /** @notice Thrown when `_initGuardian` is called with the zero address. */
  error InvalidGuardian();
  /** @notice Thrown when `renounceRole` is called — self-renouncing roles is disabled. */
  error RenounceRoleDisabled();
  /** @notice Thrown when revoking a role would leave the contract without any guardian. */
  error LastGuardian();

  /** @notice Returns the role identifier for guardians (super-admins of the role hierarchy). */
  function GUARDIAN_ROLE() external view returns (bytes32);

  /** @notice Returns the role identifier for protocol admins. */
  function ADMIN_ROLE() external view returns (bytes32);

  /** @notice Returns the role identifier for pausers (least-privilege, pause-only role). */
  function PAUSER_ROLE() external view returns (bytes32);
}
