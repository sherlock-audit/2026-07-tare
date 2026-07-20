// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeployLoansExchangeLibrary} from "./lib/DeployLoansExchangeLibrary.sol";
import {LoansExchange} from "../contracts/LoansExchange.sol";
import {console} from "forge-std/Script.sol";

/**
 * @title Deployer for the LoansExchange contract
 * @notice Standalone deployment of LoansExchange against an existing Loans + LoansNFT pair.
 *         Useful for redeploying only the exchange against a previously deployed Loans manifest.
 *
 * Required environment variables:
 *   DEPLOY_ADMIN                — ADMIN_ROLE grantee (must be non-zero and distinct from deployer)
 *   DEPLOY_GUARDIAN             — Guardian / timelock address (must be non-zero and distinct from deployer)
 *
 * Optional environment variables:
 *   DEPLOYMENT_NAME             — Deployment name (default: "dev")
 *   DEPLOY_RECOVERY_ADDRESS     — Rescue recipient baked into LoansExchange (default: DEPLOY_GUARDIAN)
 *
 * Reads from:
 *   deployments/{chain}/{name}/loans/latest.json — Loans, LoansNFT addresses
 *
 * Writes to:
 *   deployments/{chain}/{name}/exchange/latest.json
 */
contract DeployLoansExchange is DeployLoansExchangeLibrary {
  function setUp() public withCreateX {
    string memory _deploymentName = vm.envOr("DEPLOYMENT_NAME", string("dev"));
    initializeBase("exchange", _deploymentName);
  }

  function run() public withCreateX {
    string memory loansDeploymentPath = string(
      abi.encodePacked("deployments/", chainName, "/", deploymentName, "/loans/latest.json")
    );
    // forge-lint: disable-next-line(unsafe-cheatcode)
    string memory loansDeploymentJson = vm.readFile(loansDeploymentPath);
    address _loans = vm.parseJsonAddress(loansDeploymentJson, ".contracts.Loans");
    address _loansNFT = vm.parseJsonAddress(loansDeploymentJson, ".contracts.LoansNFT");
    console.log("Loans contract loaded from deployment:", _loans);
    console.log("LoansNFT contract loaded from deployment:", _loansNFT);

    address _admin = vm.envAddress("DEPLOY_ADMIN");
    address _guardian = vm.envAddress("DEPLOY_GUARDIAN");
    LoansExchangeParams memory params = LoansExchangeParams({
      loans: _loans,
      loansNFT: _loansNFT,
      admin: _admin,
      guardian: _guardian,
      recoveryAddress: vm.envOr("DEPLOY_RECOVERY_ADDRESS", _guardian)
    });

    vm.startBroadcast();
    LoansExchange _exchange = deployLoansExchange(params);
    vm.stopBroadcast();

    writeLoansExchangeDeployment();
    console.log("LoansExchange deployed at:", address(_exchange));
  }
}
