// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DeploymentBase} from "./lib/DeploymentBase.sol";
import {CctpBridgeModule} from "contracts/CctpBridgeModule.sol";

/**
 * @title Deploy CctpBridgeModule
 * @notice Deploys the single-purpose CCTP bridge Safe module. The route (Base mainnet USDC →
 *         Avalanche) is hardcoded in the contract; only the Safe and the recipient are supplied.
 *         The target Safe is created separately (e.g. via the Safe UI); after this deploy,
 *         enable the module on the Safe and run a small canary bridge before real funds.
 *
 * Required environment variables:
 *   CCTP_BRIDGE_SAFE            — the Safe whose USDC the module bridges
 *   CCTP_BRIDGE_MINT_RECIPIENT  — destination recipient (EVM address on Avalanche)
 *
 * Optional environment variables:
 *   DEPLOYMENT_NAME             — deployment name (default: "dev")
 */
contract DeployCctpBridgeModule is DeploymentBase {
  /// @notice Initialises manifest paths for the `cctpBridge` component.
  function setUp() public withCreateX {
    initializeBase("cctpBridge", vm.envOr("DEPLOYMENT_NAME", string("dev")));
  }

  /// @notice Deploys the module, fail-fast asserts its configuration, and writes the manifest.
  function run() public withCreateX {
    // The hardcoded USDC/TokenMessenger addresses only exist on Base mainnet.
    require(block.chainid == 8453, "DeployCctpBridgeModule: Base mainnet only");

    address safe = vm.envAddress("CCTP_BRIDGE_SAFE");
    address mintRecipientAddress = vm.envAddress("CCTP_BRIDGE_MINT_RECIPIENT");
    bytes32 mintRecipient = bytes32(uint256(uint160(mintRecipientAddress)));

    // vm.envAddress already rejects malformed addresses; guard against a well-formed but wrong
    // Safe (e.g. an EOA typo) that would deploy a module the Safe can never execute.
    require(safe.code.length > 0, "DeployCctpBridgeModule: safe is not a contract");
    require(mintRecipientAddress != address(0), "DeployCctpBridgeModule: zero mintRecipient");

    vm.startBroadcast();
    address module = create3(
      generateSalt("CctpBridgeModule"),
      abi.encodePacked(type(CctpBridgeModule).creationCode, abi.encode(safe, mintRecipient))
    );
    vm.stopBroadcast();

    _assertModuleConfiguration(module, safe, mintRecipient);

    addDeployedContract("CctpBridgeModule", module);
    writeDeploymentInfo(buildDeploymentJson());
  }

  /**
   * @notice Post-deploy assertions — a wrong recipient burns funds irrecoverably, so the
   *         deployed configuration is read back and checked against the intended values.
   */
  function _assertModuleConfiguration(address module, address safe, bytes32 mintRecipient) internal view {
    CctpBridgeModule bridgeModule = CctpBridgeModule(module);
    require(bridgeModule.safe() == safe, "DeployCctpBridgeModule: safe mismatch");
    require(bridgeModule.mintRecipient() == mintRecipient, "DeployCctpBridgeModule: mintRecipient mismatch");
  }
}
