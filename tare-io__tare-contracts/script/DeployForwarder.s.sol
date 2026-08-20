// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploymentBase} from "./lib/DeploymentBase.sol";
import {Forwarder} from "contracts/Forwarder.sol";

/**
 * @title Deploy Forwarder
 * @notice Deploys the relay every role smart account authorizes. `DeployLocal` deploys one as part
 *         of the accounts component for local dev; everywhere else it is deployed on its own, which
 *         is what this script is for. Run it before `setup-smart-accounts`, which registers the
 *         Forwarder as each SA's delegate and owner.
 *
 * Required environment variables:
 *   DEPLOY_FORWARDER_CURRENCY      — the protocol currency; the one target the Forwarder refuses to
 *                                    forward calls to, so a bare token transfer can never be relayed
 *   DEPLOY_FORWARDER_INITIAL_OWNER — the address that may rotate authorized senders, set at
 *                                    construction. Mandatory so a deployment can never silently keep
 *                                    the deployer as owner.
 *
 * Optional environment variables:
 *   DEPLOY_FORWARDER_SENDERS       — comma-separated authorized senders (the LMS relayer EOAs).
 *                                    Without them the Forwarder relays nothing. Only accepted when
 *                                    the initial owner is the deployer, since `setAuthorizedSenders`
 *                                    is owner-only; any other owner sets them itself afterwards.
 *   DEPLOYMENT_NAME                — Deployment name (default: "dev")
 */
contract DeployForwarder is DeploymentBase {
  /// @notice Initialises manifest paths for the `forwarder` component.
  function setUp() public withCreateX {
    initializeBase("forwarder", vm.envOr("DEPLOYMENT_NAME", string("dev")));
  }

  /// @notice Deploys the Forwarder, authorizes senders, fail-fast asserts, and writes the manifest.
  function run() public withCreateX {
    address currency = vm.envAddress("DEPLOY_FORWARDER_CURRENCY");
    address initialOwner = vm.envAddress("DEPLOY_FORWARDER_INITIAL_OWNER");
    address[] memory senders = vm.envOr("DEPLOY_FORWARDER_SENDERS", ",", new address[](0));

    // A well-formed but wrong currency (an EOA typo) would leave the guard pointed at nothing,
    // making the protocol currency forwardable.
    require(currency.code.length > 0, "DeployForwarder: currency is not a contract");
    require(initialOwner != address(0), "DeployForwarder: initial owner is the zero address");
    // Sender rotation is a standing privilege, so on a live chain it belongs to a Safe; only the
    // local path owns the Forwarder from the deploying EOA.
    require(
      initialOwner.code.length > 0 || initialOwner == deployer,
      "DeployForwarder: initial owner is neither a contract nor the deployer"
    );
    // `setAuthorizedSenders` is owner-only, so the deployer can seed senders here only while it
    // holds the slot. Refusing is what stops an operator believing a relayer was authorized.
    require(
      senders.length == 0 || initialOwner == deployer,
      "DeployForwarder: senders must be set by the initial owner"
    );

    vm.startBroadcast();
    Forwarder forwarder = Forwarder(
      create3(
        generateSalt("Forwarder"),
        abi.encodePacked(type(Forwarder).creationCode, abi.encode(currency, initialOwner))
      )
    );
    if (senders.length > 0) {
      forwarder.setAuthorizedSenders(senders);
    }
    vm.stopBroadcast();

    _assertForwarderConfiguration(forwarder, currency, initialOwner, senders);

    addDeployedContract("Forwarder", address(forwarder));
    writeDeploymentInfo(buildDeploymentJson());
  }

  /**
   * @notice Post-deploy assertions — an unauthorized sender set means every relayed call reverts,
   *         a mis-set guard means the protocol currency is forwardable, and a wrong owner means
   *         sender rotation sits with the wrong key.
   */
  function _assertForwarderConfiguration(
    Forwarder forwarder,
    address currency,
    address initialOwner,
    address[] memory senders
  ) internal view {
    require(forwarder.linkToken() == currency, "DeployForwarder: currency mismatch");
    require(forwarder.owner() == initialOwner, "DeployForwarder: owner mismatch");
    for (uint256 index; index < senders.length; ++index) {
      require(forwarder.isAuthorizedSender(senders[index]), "DeployForwarder: sender not authorized");
    }
  }
}
