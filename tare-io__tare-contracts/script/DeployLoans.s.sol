// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeployLoansLibrary} from "./lib/DeployLoansLibrary.sol";
import {Loans} from "../contracts/Loans.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/**
 * @title Deployer for Loans (and USDC) contracts
 * @notice Script to deploy the Loans contract and its dependencies
 *
 * Required environment variables:
 *   DEPLOY_USDC            — USDC token address
 *   DEPLOY_LOANS_BASE_URI  — Base URI for loan NFT metadata
 *   DEPLOY_ADMIN           — ADMIN_ROLE grantee (must be non-zero and distinct from deployer)
 *   DEPLOY_GUARDIAN        — Guardian / timelock address (must be non-zero and distinct from deployer)
 *
 * Optional environment variables:
 *   DEPLOYMENT_NAME             — Deployment name (default: "dev")
 *   DEPLOY_RECOVERY_ADDRESS     — Rescue recipient baked into Loans/LoansExchange (default: DEPLOY_GUARDIAN)
 */
contract DeployLoans is DeployLoansLibrary {
  constructor() {}

  function setUp() public virtual withCreateX {
    string memory _deploymentName = vm.envOr("DEPLOYMENT_NAME", string("dev"));
    initializeBase("loans", _deploymentName);
  }

  function run() public withCreateX {
    address _guardian = vm.envAddress("DEPLOY_GUARDIAN");
    LoansParams memory p = LoansParams({
      usdc: IERC20(vm.envAddress("DEPLOY_USDC")),
      admin: vm.envAddress("DEPLOY_ADMIN"),
      guardian: _guardian,
      recoveryAddress: vm.envOr("DEPLOY_RECOVERY_ADDRESS", _guardian),
      baseURI: vm.envString("DEPLOY_LOANS_BASE_URI")
    });

    vm.startBroadcast();
    Loans _loans = deployLoans(p);
    vm.stopBroadcast();

    writeLoansDeployment(address(_loans), address(p.usdc));
  }
}
