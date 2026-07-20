// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploymentBase} from "./lib/DeploymentBase.sol";
import {DeploySafeSingleton} from "../test/helpers/DeploySafeSingleton.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";
import {MultiSendCallOnly} from "safe-smart-account/libraries/MultiSendCallOnly.sol";

/**
 * @title Stand-in Safe infrastructure bootstrap for local chains
 * @notice Lands the Safe singleton, proxy factory, and MultiSendCallOnly at the
 *         same fixed-salt CREATE3 addresses `DeployLocal` uses, so `deploy-safe`
 *         can create governance stand-in Safes *before* the protocol deploy — the
 *         production order (Safes -> Timelock -> protocol). `DeployLocal` later
 *         reuses these via `create3IfAbsent` instead of redeploying.
 */
contract DeploySafeInfra is DeploymentBase {
  function setUp() public withCreateX {
    initializeBase("accounts", vm.envOr("DEPLOYMENT_NAME", string("dev")));
  }

  function run() public withCreateX {
    vm.startBroadcast();
    address safeSingleton = create3IfAbsent(
      keccak256("tareio-SafeSingleton-1"),
      DeploySafeSingleton.SAFE_CREATION_CODE
    );
    address safeProxyFactory = create3IfAbsent(
      keccak256("tareio-SafeProxyFactory-1"),
      abi.encodePacked(type(SafeProxyFactory).creationCode)
    );
    address multisend = create3IfAbsent(
      keccak256("tareio-MultiSendCallOnly-1"),
      abi.encodePacked(type(MultiSendCallOnly).creationCode)
    );
    vm.stopBroadcast();

    addDeployedContract("SafeSingleton", safeSingleton);
    addDeployedContract("SafeProxyFactory", safeProxyFactory);
    addDeployedContract("MultiSendCallOnly", multisend);
    // Writes the accounts manifest with just the Safe infra, making the
    // bootstrap self-contained: deploy-safe's manifest fallback works even on
    // a repo with no committed manifests. DeployLocal rewrites the full
    // accounts manifest later in the same bake.
    writeDeploymentInfo(buildDeploymentJson());
  }
}
