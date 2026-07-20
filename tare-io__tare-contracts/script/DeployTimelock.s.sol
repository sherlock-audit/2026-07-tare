// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeployTimelockLibrary} from "./lib/DeployTimelockLibrary.sol";

import {console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title Deploy TimelockController
 * @notice Run this before DeployLoans and DeploySmartAccounts to be able to set TimelockController
 *         guardian on all target contracts.
 *
 * Required environment variables:
 *   DEPLOY_TIMELOCK_PROPOSERS  — comma-separated PROPOSER_ROLE holders (e.g. the Proposer Safe)
 *   DEPLOY_TIMELOCK_CANCELLERS — comma-separated CANCELLER_ROLE holders (e.g. the Admin Safe);
 *                                must be disjoint from the proposer set — the script reverts on overlap
 *
 * Optional environment variables:
 *   DEPLOY_TIMELOCK_MIN_DELAY  — minimum delay in seconds (default: 0)
 *   DEPLOY_TIMELOCK_EXECUTORS  — comma-separated EXECUTOR_ROLE holders
 *                                (default: the zero address, i.e. open execution)
 *   DEPLOYMENT_NAME            — Deployment name (default: "dev")
 */
contract DeployTimelock is DeployTimelockLibrary {
  /// @notice Initialises manifest paths for the `timelock` component.
  function setUp() public withCreateX {
    string memory _deploymentName = vm.envOr("DEPLOYMENT_NAME", string("dev"));
    initializeBase("timelock", _deploymentName);
  }

  /// @notice Deploys the timelock, fail-fast asserts its role wiring, and writes the manifest.
  function run() public withCreateX {
    address[] memory defaultExecutors = new address[](1);
    defaultExecutors[0] = address(0);

    TimelockParams memory params = TimelockParams({
      minDelay: vm.envOr("DEPLOY_TIMELOCK_MIN_DELAY", uint256(0)),
      proposers: vm.envAddress("DEPLOY_TIMELOCK_PROPOSERS", ","),
      cancellers: vm.envAddress("DEPLOY_TIMELOCK_CANCELLERS", ","),
      executors: vm.envOr("DEPLOY_TIMELOCK_EXECUTORS", ",", defaultExecutors)
    });

    vm.startBroadcast();
    TimelockController _timelock = deployTimelock(params);
    vm.stopBroadcast();

    _assertTimelockConfiguration(_timelock, params);

    writeTimelockDeployment();
  }

  /**
   * @notice Post-deploy assertions — fail-fast on misconfiguration.
   * @dev TimelockController is not AccessControlEnumerable, so exact-set is asserted by
   *      construction instead: the contract is freshly deployed and this script performed
   *      every grant/revoke, so checking each intended holder positively and every other
   *      involved address negatively proves the sets exactly.
   */
  function _assertTimelockConfiguration(TimelockController _timelock, TimelockParams memory params) internal view {
    bytes32 proposerRole = _timelock.PROPOSER_ROLE();
    bytes32 cancellerRole = _timelock.CANCELLER_ROLE();
    bytes32 executorRole = _timelock.EXECUTOR_ROLE();
    bytes32 defaultAdminRole = _timelock.DEFAULT_ADMIN_ROLE();

    // 1. Verify minDelay is set correctly
    require(_timelock.getMinDelay() == params.minDelay, "DeployTimelock: minDelay mismatch");

    // 2. Verify each proposer has their role set correctly
    for (uint256 index; index < params.proposers.length; index++) {
      require(_timelock.hasRole(proposerRole, params.proposers[index]), "DeployTimelock: proposer not set");
      // The constructor auto-grants CANCELLER_ROLE to proposers; the sets are disjoint, so
      // every proposer must have had it revoked.
      require(
        !_timelock.hasRole(cancellerRole, params.proposers[index]),
        "DeployTimelock: proposer kept canceller role"
      );
    }

    // 3. Verify each canceller has their role set correctly
    for (uint256 index; index < params.cancellers.length; index++) {
      require(_timelock.hasRole(cancellerRole, params.cancellers[index]), "DeployTimelock: canceller not set");
      // And no canceller has the proposer role (the sets are disjoint)
      require(
        !_timelock.hasRole(proposerRole, params.cancellers[index]),
        "DeployTimelock: canceller has proposer role"
      );
    }

    // 4. Verify each executor has their role set correctly
    for (uint256 index; index < params.executors.length; index++) {
      require(_timelock.hasRole(executorRole, params.executors[index]), "DeployTimelock: executor not set");
    }

    // The deployer must have renounced its transient setup-admin role, and must hold no
    // operational role it was not explicitly given.
    require(!_timelock.hasRole(defaultAdminRole, deployer), "DeployTimelock: deployer still admin");
    if (!_contains(params.proposers, deployer)) {
      require(!_timelock.hasRole(proposerRole, deployer), "DeployTimelock: deployer has proposer role");
    }
    if (!_contains(params.cancellers, deployer)) {
      require(!_timelock.hasRole(cancellerRole, deployer), "DeployTimelock: deployer has canceller role");
    }
    if (!_contains(params.executors, deployer)) {
      require(!_timelock.hasRole(executorRole, deployer), "DeployTimelock: deployer has executor role");
    }

    // Self-administered: the timelock itself is the only DEFAULT_ADMIN_ROLE holder (the
    // constructor grants it to the timelock and msg.sender only, and msg.sender renounced).
    require(_timelock.hasRole(defaultAdminRole, address(_timelock)), "DeployTimelock: timelock is not self-admin");
  }
}
