// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploySmartAccountsLibrary} from "./lib/DeploySmartAccountsLibrary.sol";
import {console} from "forge-std/Script.sol";

// To deploy the Safe dependency use the following code:
// import {Safe} from "safe-smart-account/Safe.sol";
// import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";
// safeProxyFactory = address(new SafeProxyFactory());
// safeSingleton = address(new Safe());

/**
 * @title Deployer for SmartAccountFactory, TrustedCalls, and TrustedSpender contracts
 * @notice Script to deploy the SmartAccountFactory and related contracts
 * @dev !! Verify that the values in deploymentConfig.toml are correct before running this script !!
 *
 * Required environment variables:
 *   DEPLOY_SAFE_SINGLETON   — Safe singleton address
 *   DEPLOY_SAFE_PROXY_FACTORY — SafeProxyFactory address
 *   DEPLOY_MULTISEND        — MultiSend address
 *   DEPLOY_ADMIN            — ADMIN_ROLE grantee (must be non-zero and distinct from deployer)
 *   DEPLOY_GUARDIAN         — Guardian / timelock address (must be non-zero and distinct from deployer)
 *
 * Optional environment variables:
 *   DEPLOYMENT_NAME         — Deployment name (default: "dev")
 *   DEPLOY_RECOVERY_ADDRESS — Rescue recipient baked into TrustedCalls/TrustedSpender (default: DEPLOY_GUARDIAN)
 *   DEPLOY_PORTFOLIO_VAULT  — PortfolioVault address override (defaults to vault/latest.json).
 *
 * Reads from:
 *   deployments/{chain}/{name}/loans/latest.json — Loans, LoansExchange addresses
 *   deployments/{chain}/{name}/vault/latest.json — PortfolioVault address (if env var not set)
 */
contract DeploySmartAccounts is DeploySmartAccountsLibrary {
  function setUp() public withCreateX {
    string memory _deploymentName = vm.envOr("DEPLOYMENT_NAME", string("dev"));
    initializeBase("accounts", _deploymentName);
  }

  function run() public withCreateX {
    string memory _deploymentName = vm.envOr("DEPLOYMENT_NAME", string("dev"));
    string memory loansDeploymentPath = string(
      abi.encodePacked("deployments/", chainName, "/", _deploymentName, "/loans/latest.json")
    );
    // forge-lint: disable-next-line(unsafe-cheatcode)
    string memory loansDeploymentJson = vm.readFile(loansDeploymentPath);
    address _loansContract = vm.parseJsonAddress(loansDeploymentJson, ".contracts.Loans");
    address _loansExchange = vm.parseJsonAddress(loansDeploymentJson, ".contracts.LoansExchange");
    console.log("Loans contract loaded from deployment:", _loansContract);
    console.log("LoansExchange contract loaded from deployment:", _loansExchange);

    address _portfolioVault;
    if (vm.envExists("DEPLOY_PORTFOLIO_VAULT")) {
      _portfolioVault = vm.envAddress("DEPLOY_PORTFOLIO_VAULT");
    } else {
      string memory vaultDeploymentPath = string(
        abi.encodePacked("deployments/", chainName, "/", _deploymentName, "/vault/latest.json")
      );
      string memory vaultJson = vm.readFile(vaultDeploymentPath);
      _portfolioVault = vm.parseJsonAddress(vaultJson, ".contracts.PortfolioVault");
    }
    require(_portfolioVault != address(0), "DeploySmartAccounts: PortfolioVault address is zero");

    address _admin = vm.envAddress("DEPLOY_ADMIN");
    address _guardian = vm.envAddress("DEPLOY_GUARDIAN");
    AccountsParams memory params = AccountsParams({
      safeSingleton: vm.envAddress("DEPLOY_SAFE_SINGLETON"),
      safeProxyFactory: vm.envAddress("DEPLOY_SAFE_PROXY_FACTORY"),
      multisend: vm.envAddress("DEPLOY_MULTISEND"),
      admin: _admin,
      guardian: _guardian,
      recoveryAddress: vm.envOr("DEPLOY_RECOVERY_ADDRESS", _guardian),
      loansContract: _loansContract,
      loansExchange: _loansExchange,
      portfolioVault: _portfolioVault
    });

    vm.startBroadcast();
    AccountsResult memory result = deployAccounts(params);
    vm.stopBroadcast();

    writeAccountsDeployment(params, result);
  }
}
