// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../mocks/USDC.sol";
import {DeploySafeSingleton} from "../helpers/DeploySafeSingleton.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";

/**
 * @title DeployerTestBase
 * @notice Base test contract for deployment script tests
 * @dev Provides common setup for testing Deployer.s.sol and DeploySmartAccounts.s.sol
 */
abstract contract DeployerTestBase is Test {
  // Test addresses
  address public admin;
  address public deployer;

  // Mock contracts
  MockUSDC public usdc;
  address public safeSingleton;
  SafeProxyFactory public safeProxyFactory;

  // Network simulation
  // Use 31337 (Anvil local) so CreateX can be etched
  uint256 public constant TEST_CHAIN_ID = 31337;

  function setUp() public virtual {
    // Set up test addresses
    admin = makeAddr("admin");
    deployer = makeAddr("deployer");

    // Set chain ID to Anvil local for CreateX etching support
    vm.chainId(TEST_CHAIN_ID);

    // Deploy mock USDC
    usdc = new MockUSDC();

    // Deploy Safe infrastructure for SmartAccounts tests
    safeSingleton = DeploySafeSingleton.deployFromCreationCode();
    safeProxyFactory = new SafeProxyFactory();

    // Set msg.sender for deployment scripts
    vm.startPrank(deployer);
  }

  /**
   * @notice Helper to check if an address has deployed code
   */
  function hasCode(address addr) internal view returns (bool) {
    return addr.code.length > 0;
  }
}
