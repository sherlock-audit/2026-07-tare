// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeployerTestBase} from "./DeployerTestBase.t.sol";
import {DeployTimelockLibrary} from "../../script/lib/DeployTimelockLibrary.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AddressArrays} from "../helpers/AddressArrays.sol";

/**
 * @title TestableDeployTimelock
 * @notice Extended DeployTimelockLibrary with test helpers
 */
contract TestableDeployTimelock is DeployTimelockLibrary {
  /// @notice Etches the CreateX factory for CREATE3 deployments in tests.
  function initCreateX() external {
    setUpCreateXFactory();
  }

  /// @notice Overrides the deployer used as the timelock's transient setup admin.
  function setTestDeployer(address _deployer) external {
    deployer = _deployer;
  }

  /// @notice Overrides the deployment name so repeated deploys get distinct CREATE3 salts.
  function setTestDeploymentName(string memory _deploymentName) external {
    deploymentName = _deploymentName;
  }

  /**
   * @notice Run deployment with broadcast context (mirrors run() behavior)
   */
  function runDeploy(
    uint256 minDelay,
    address[] memory proposers,
    address[] memory cancellers,
    address[] memory executors
  ) external {
    vm.startBroadcast(deployer);
    deployTimelock(
      TimelockParams({minDelay: minDelay, proposers: proposers, cancellers: cancellers, executors: executors})
    );
    vm.stopBroadcast();
  }
}

/**
 * @title DeployTimelockTest
 * @notice Tests for the DeployTimelock deployment flow
 */
contract DeployTimelockTest is DeployerTestBase {
  TestableDeployTimelock public deployerScript;
  TimelockController public timelock;

  /// @notice Stand-in for the single-purpose Proposer Safe (sole PROPOSER_ROLE holder).
  address public proposerSafe;
  /// @notice Open execution sentinel: anyone may execute matured operations.
  address public constant OPEN_EXECUTOR = address(0);

  uint256 public constant MIN_DELAY = 172800; // 48 hours

  function setUp() public override {
    super.setUp();
    vm.stopPrank();

    proposerSafe = makeAddr("proposerSafe");

    deployerScript = new TestableDeployTimelock();
    deployerScript.setTestDeployer(deployer);
    deployerScript.initCreateX();
    // Production-shaped role split: proposer ≠ canceller (admin Safe), open executor.
    deployerScript.runDeploy(
      MIN_DELAY,
      AddressArrays.make(proposerSafe),
      AddressArrays.make(admin),
      AddressArrays.make(OPEN_EXECUTOR)
    );

    timelock = deployerScript.timelock();
  }

  function test_Deploy_TimelockDeployed() public view {
    assertTrue(address(timelock) != address(0), "Timelock should have non-zero address");
    assertTrue(hasCode(address(timelock)), "Timelock should have deployed code");
  }

  function test_Deploy_MinDelayIsCorrect() public view {
    assertEq(timelock.getMinDelay(), MIN_DELAY, "Min delay should match configured value");
  }

  function test_Deploy_ProposerHasOnlyProposerRole() public view {
    assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposerSafe), "Proposer should have PROPOSER_ROLE");
    assertFalse(
      timelock.hasRole(timelock.CANCELLER_ROLE(), proposerSafe),
      "Auto-granted CANCELLER_ROLE should be revoked from proposer"
    );
    assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), proposerSafe), "Proposer should not have EXECUTOR_ROLE");
  }

  function test_Deploy_CancellerHasOnlyCancellerRole() public view {
    assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), admin), "Canceller should have CANCELLER_ROLE");
    assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), admin), "Canceller should not have PROPOSER_ROLE");
    assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), admin), "Canceller should not have EXECUTOR_ROLE");
  }

  function test_Deploy_ExecutionIsOpen() public view {
    assertTrue(
      timelock.hasRole(timelock.EXECUTOR_ROLE(), OPEN_EXECUTOR),
      "address(0) should have EXECUTOR_ROLE (open execution)"
    );
  }

  function test_Deploy_TimelockIsSelfAdministered() public view {
    assertTrue(
      timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)),
      "Timelock should hold DEFAULT_ADMIN_ROLE (self-administered)"
    );
  }

  function test_Deploy_NoExternalDefaultAdmin() public view {
    assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin), "Admin should not have DEFAULT_ADMIN_ROLE");
    assertFalse(
      timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), proposerSafe),
      "Proposer should not have DEFAULT_ADMIN_ROLE"
    );
    assertFalse(
      timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer),
      "Deployer should not have DEFAULT_ADMIN_ROLE"
    );
  }

  function test_Deploy_DeployerHasNoRoles() public view {
    assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer), "Deployer should not have PROPOSER_ROLE");
    assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer), "Deployer should not have EXECUTOR_ROLE");
    assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), deployer), "Deployer should not have CANCELLER_ROLE");
  }

  function test_RevertWhen_ProposerCancellerOverlap() public {
    TestableDeployTimelock overlapScript = _freshScript("overlap");
    vm.expectRevert(bytes("DeployTimelockLibrary: proposer/canceller overlap"));
    overlapScript.runDeploy(
      MIN_DELAY,
      AddressArrays.make(admin),
      AddressArrays.make(admin),
      AddressArrays.make(OPEN_EXECUTOR)
    );
  }

  function test_Deploy_MultipleProposersAndCancellers() public {
    address secondProposer = makeAddr("secondProposer");
    address secondCanceller = makeAddr("secondCanceller");
    address[] memory proposers = new address[](2);
    proposers[0] = proposerSafe;
    proposers[1] = secondProposer;
    address[] memory cancellers = new address[](2);
    cancellers[0] = admin;
    cancellers[1] = secondCanceller;

    TestableDeployTimelock multiScript = _freshScript("multi");
    multiScript.runDeploy(0, proposers, cancellers, AddressArrays.make(OPEN_EXECUTOR));
    TimelockController multiTimelock = multiScript.timelock();

    assertTrue(multiTimelock.hasRole(multiTimelock.PROPOSER_ROLE(), secondProposer), "Second proposer set");
    assertFalse(
      multiTimelock.hasRole(multiTimelock.CANCELLER_ROLE(), secondProposer),
      "Second proposer should not keep CANCELLER_ROLE"
    );
    assertTrue(multiTimelock.hasRole(multiTimelock.CANCELLER_ROLE(), secondCanceller), "Second canceller set");
  }

  function test_RevertWhen_MinDelayTooLarge() public {
    TestableDeployTimelock revertScript = _freshScript("revert-delay");
    vm.expectRevert(bytes("DeployTimelockLibrary: minDelay too large"));
    revertScript.runDeploy(
      30 days + 1,
      AddressArrays.make(proposerSafe),
      AddressArrays.make(admin),
      AddressArrays.make(OPEN_EXECUTOR)
    );
  }

  function test_RevertWhen_NoProposers() public {
    TestableDeployTimelock revertScript = _freshScript("revert-proposers");
    vm.expectRevert(bytes("DeployTimelockLibrary: no proposers"));
    revertScript.runDeploy(MIN_DELAY, new address[](0), AddressArrays.make(admin), AddressArrays.make(OPEN_EXECUTOR));
  }

  function test_RevertWhen_NoCancellers() public {
    TestableDeployTimelock revertScript = _freshScript("revert-cancellers");
    vm.expectRevert(bytes("DeployTimelockLibrary: no cancellers"));
    revertScript.runDeploy(
      MIN_DELAY,
      AddressArrays.make(proposerSafe),
      new address[](0),
      AddressArrays.make(OPEN_EXECUTOR)
    );
  }

  function test_RevertWhen_NoExecutors() public {
    TestableDeployTimelock revertScript = _freshScript("revert-executors");
    vm.expectRevert(bytes("DeployTimelockLibrary: no executors"));
    revertScript.runDeploy(MIN_DELAY, AddressArrays.make(proposerSafe), AddressArrays.make(admin), new address[](0));
  }

  /**
   * @notice Builds a fresh script instance with a distinct deployment name.
   * @dev Distinct names give distinct CREATE3 salts so a second deploy in the same test
   *      does not collide with the one from setUp.
   */
  function _freshScript(string memory name) internal returns (TestableDeployTimelock) {
    TestableDeployTimelock script = new TestableDeployTimelock();
    script.setTestDeployer(deployer);
    script.initCreateX();
    script.setTestDeploymentName(name);
    return script;
  }
}
