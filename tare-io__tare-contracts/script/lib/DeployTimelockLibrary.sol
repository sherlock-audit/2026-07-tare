// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploymentBase} from "./DeploymentBase.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployTimelockLibrary
 * @notice Deploys an OZ TimelockController with explicit proposer / canceller / executor sets.
 */
abstract contract DeployTimelockLibrary is DeploymentBase {
  TimelockController public timelock;

  struct TimelockParams {
    /// @notice The minimum delay (in seconds) before a scheduled operation can be executed
    uint256 minDelay;
    /// @notice Addresses granted PROPOSER_ROLE
    address[] proposers;
    /// @notice Addresses granted CANCELLER_ROLE — must be disjoint from the proposer set
    address[] cancellers;
    /// @notice Addresses granted EXECUTOR_ROLE — pass [address(0)] for open execution
    address[] executors;
  }

  /**
   * @notice Deploy the TimelockController and configure the exact canceller set.
   * @dev Proposers and cancellers must be two disjoint sets — the function reverts on any
   *      overlap. OZ's constructor auto-grants CANCELLER_ROLE to every proposer, so the
   *      deployer EOA is passed as the constructor admin, transiently holds
   *      DEFAULT_ADMIN_ROLE while it revokes CANCELLER_ROLE from every proposer and grants
   *      it to every canceller, then renounces it — the OZ-recommended "setup admin then
   *      renounce" pattern. After this function the timelock is self-administered: only the
   *      timelock itself holds DEFAULT_ADMIN_ROLE, so any further role change must flow
   *      through a timelocked proposal.
   */
  function deployTimelock(TimelockParams memory p) internal returns (TimelockController) {
    require(p.minDelay <= 30 days, "DeployTimelockLibrary: minDelay too large");
    require(p.proposers.length > 0, "DeployTimelockLibrary: no proposers");
    require(p.cancellers.length > 0, "DeployTimelockLibrary: no cancellers");
    require(p.executors.length > 0, "DeployTimelockLibrary: no executors");
    for (uint256 index; index < p.proposers.length; index++) {
      require(!_contains(p.cancellers, p.proposers[index]), "DeployTimelockLibrary: proposer/canceller overlap");
    }

    timelock = TimelockController(
      payable(
        create3(
          generateSalt("TimelockController"),
          abi.encodePacked(
            type(TimelockController).creationCode,
            abi.encode(p.minDelay, p.proposers, p.executors, deployer)
          )
        )
      )
    );

    bytes32 cancellerRole = timelock.CANCELLER_ROLE();
    bytes32 defaultAdminRole = timelock.DEFAULT_ADMIN_ROLE();

    // Revoke the auto-granted CANCELLER_ROLE from every proposer (the sets are disjoint).
    for (uint256 index; index < p.proposers.length; index++) {
      timelock.revokeRole(cancellerRole, p.proposers[index]);
    }
    // Grant CANCELLER_ROLE to every canceller.
    for (uint256 index; index < p.cancellers.length; index++) {
      timelock.grantRole(cancellerRole, p.cancellers[index]);
    }
    // Renounce the transient setup-admin role: the timelock becomes self-administered.
    timelock.renounceRole(defaultAdminRole, deployer);

    return timelock;
  }

  /** @notice Writes the timelock deployment manifest. */
  function writeTimelockDeployment() internal {
    addDeployedContract("TimelockController", address(timelock));
    writeDeploymentInfo(buildDeploymentJson());
  }
}
