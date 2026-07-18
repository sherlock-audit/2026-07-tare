// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployerTestBase} from "./DeployerTestBase.t.sol";
import {DeployLoans} from "../../script/DeployLoans.s.sol";
import {Loans} from "../../contracts/Loans.sol";
import {LoansExchange} from "../../contracts/LoansExchange.sol";

/**
 * @title TestableDeployer
 * @notice Extended Deployer with test helpers for setting internal state
 */
contract TestableDeployer is DeployLoans {
  address public testUsdc;
  address public testAdmin;
  address public testGuardian;

  /// @dev Override parent setUp to prevent Foundry from running it
  function setUp() public override {}

  function setTestConfig(address _usdc, address _admin, address _guardian, address _deployer) external {
    testUsdc = _usdc;
    testAdmin = _admin;
    testGuardian = _guardian;
    deployer = _deployer;
  }

  /**
   * @notice Initialize CreateX factory for testing
   * @dev Exposes setUpCreateXFactory from CreateXScript
   */
  function initCreateX() external {
    setUpCreateXFactory();
  }

  /**
   * @notice Run deployment with broadcast context (mirrors run() behavior)
   * @dev This runs deployLoans() inside vm.startBroadcast/stopBroadcast like the real script
   */
  function runDeploy() external {
    vm.startBroadcast(deployer);
    deployLoans(
      LoansParams({
        usdc: IERC20(testUsdc),
        admin: testAdmin,
        guardian: testGuardian,
        recoveryAddress: testGuardian,
        baseURI: ""
      })
    );
    vm.stopBroadcast();
  }
}

/**
 * @title DeployerTest
 * @notice Tests for the Deployer script deployment flow
 * @dev Tests call the actual script's deploy() function to ensure test/script parity
 */
contract DeployerTest is DeployerTestBase {
  TestableDeployer public deployerScript;
  Loans public loans;
  LoansExchange public loansExchange;
  address public timelock = makeAddr("timelock");

  function setUp() public override {
    super.setUp();
    vm.stopPrank();

    deployerScript = new TestableDeployer();

    deployerScript.setTestConfig(address(usdc), admin, timelock, deployer);

    deployerScript.initCreateX();

    // Run deploy() with broadcast context inside the script
    // This mirrors how the actual run() function works
    deployerScript.runDeploy();

    loans = deployerScript.loans();
    loansExchange = deployerScript.loansExchange();
  }

  function test_Deploy_LoansContractDeployed() public view {
    assertTrue(address(loans) != address(0), "Loans should have non-zero address");
    assertTrue(hasCode(address(loans)), "Loans should have deployed code");
  }

  function test_Deploy_DeployerLosesGuardianRoleInScript() public view {
    assertFalse(loans.hasRole(loans.ADMIN_ROLE(), deployer), "Deployer should not be admin after deployment");
    assertFalse(loans.hasRole(loans.GUARDIAN_ROLE(), deployer), "Deployer should not be guardian after deployment");
    assertFalse(
      loansExchange.hasRole(loansExchange.ADMIN_ROLE(), deployer),
      "Deployer should not be admin on LoansExchange after deployment"
    );
    assertFalse(
      loansExchange.hasRole(loansExchange.GUARDIAN_ROLE(), deployer),
      "Deployer should not be guardian on LoansExchange after deployment"
    );
  }

  function test_Deploy_AdminGainsAdminRights() public view {
    assertTrue(loans.hasRole(loans.ADMIN_ROLE(), admin), "Config admin should be admin after deployment");
    assertTrue(
      loansExchange.hasRole(loansExchange.ADMIN_ROLE(), admin),
      "Config admin should be admin on LoansExchange after deployment"
    );
  }

  function test_Deploy_GuardianSetToTimelock() public view {
    assertTrue(loans.hasRole(loans.GUARDIAN_ROLE(), timelock), "Timelock should be guardian after deployment");
    assertTrue(
      loansExchange.hasRole(loansExchange.GUARDIAN_ROLE(), timelock),
      "Timelock should be guardian on LoansExchange after deployment"
    );
  }

  function test_Deploy_CurrencySetCorrectly() public view {
    assertEq(address(loans.currency()), address(usdc), "Currency should be set to USDC");
  }
}
