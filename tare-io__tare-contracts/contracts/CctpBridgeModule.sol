// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Enum} from "safe-smart-account/common/Enum.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICctpBridgeModule} from "contracts/interfaces/ICctpBridgeModule.sol";
import {ITokenMessengerV2} from "contracts/interfaces/ITokenMessengerV2.sol";
import {IModuleManager} from "contracts/misc/interfaces/IModuleManager.sol";
import {ISafe} from "contracts/misc/interfaces/ISafe.sol";

/**
 * @title CctpBridgeModule
 * @notice Single-purpose Safe module that bridges the Safe's USDC to one hardcoded recipient
 *         on one hardcoded destination chain via Circle's CCTP v2 Forwarding Service.
 * @dev The route (Base mainnet USDC → Avalanche via Circle's TokenMessenger) is fixed at
 *      compile time; only the Safe and the recipient are set at deployment, as immutables.
 *      Changing any of them means deploying a new module and swapping it on the Safe.
 *      The Safe's `disableModule` is the kill switch.
 */
contract CctpBridgeModule is ICctpBridgeModule {
  /**
   * @notice Circle's reserved "cctp-forward" magic bytes (+ zero version/length). Presence in
   *         `hookData` tells the Forwarding Service to attest AND mint on the destination.
   */
  bytes public constant FORWARDING_HOOK_DATA = hex"636374702d666f72776172640000000000000000000000000000000000000000";

  /// @notice Finality thresholds:
  /// Standard: Attested once the burn block is finalized.
  /// Fast: Attested at "confirmed" rather than "finalized".
  uint32 public constant FINALITY_THRESHOLD_STANDARD = 2000;
  uint32 public constant FINALITY_THRESHOLD_FAST = 1000;

  /// @notice USDC on Base mainnet.
  address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

  /// @notice Circle's CCTP v2 TokenMessenger on Base mainnet.
  address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

  /// @notice CCTP domain of the destination chain
  uint32 public constant DESTINATION_DOMAIN = 1; // Avalanche

  /// @notice Flat fee allowance (0.50 USDC) covering the Forwarding Service's destination gas.
  uint256 public constant FLAT_FEE = 0.5e6;

  /**
   * @notice Fast-transfer protocol fee as a fraction of the amount: 13 / 100_000 = 1.3 bps,
   */
  uint256 public constant FAST_FEE_NUMERATOR = 13;
  uint256 public constant FAST_FEE_DENOMINATOR = 100_000;

  /// @inheritdoc ICctpBridgeModule
  address public immutable safe;

  /// @inheritdoc ICctpBridgeModule
  bytes32 public immutable mintRecipient;

  /**
   * @notice Configures the module's per-deployment parameters; the route itself is fixed
   *         at compile time.
   * @param _safe The Safe whose USDC this module bridges.
   * @param _mintRecipient The destination recipient address, as bytes32.
   */
  constructor(address _safe, bytes32 _mintRecipient) {
    require(_safe != address(0), ZeroAddress());
    require(_mintRecipient != bytes32(0), ZeroAddress());

    safe = _safe;
    mintRecipient = _mintRecipient;
  }

  /// @inheritdoc ICctpBridgeModule
  function bridge(uint256 amount) external returns (uint256 bridgedAmount) {
    return _bridge(amount, false);
  }

  /// @inheritdoc ICctpBridgeModule
  function bridgeFast(uint256 amount) external returns (uint256 bridgedAmount) {
    return _bridge(amount, true);
  }

  /**
   * @notice Shared bridge flow: resolves the amount, computes the mode's fee allowance, and
   *         submits the approve + burn from the Safe's context.
   * @param amount The USDC amount to bridge, or 0 to bridge the Safe's entire balance.
   * @param fastMode True for Fast finality (flat + 1.3 bps fee), false for Standard (flat only).
   * @return bridgedAmount The amount actually burned.
   */
  function _bridge(uint256 amount, bool fastMode) internal returns (uint256 bridgedAmount) {
    require(ISafe(safe).isOwner(msg.sender), NotSafeOwner());

    // Sweep the Safe's entire balance if 0 is supplied; otherwise bridge the requested amount.
    bridgedAmount = amount == 0 ? IERC20(USDC).balanceOf(safe) : amount;

    uint256 maxFee = FLAT_FEE;
    uint32 minFinalityThreshold = FINALITY_THRESHOLD_STANDARD;
    if (fastMode) {
      maxFee += (bridgedAmount * FAST_FEE_NUMERATOR) / FAST_FEE_DENOMINATOR;
      minFinalityThreshold = FINALITY_THRESHOLD_FAST;
    }
    // Fees are deducted from the burn amount; Require a greater amount.
    require(bridgedAmount > maxFee, AmountTooSmall());

    bytes memory approveReturn = _execFromSafe(USDC, abi.encodeCall(IERC20.approve, (TOKEN_MESSENGER, bridgedAmount)));
    require(approveReturn.length == 0 || abi.decode(approveReturn, (bool)), UsdcApprovalFailed());

    _execFromSafe(
      TOKEN_MESSENGER,
      abi.encodeCall(
        ITokenMessengerV2.depositForBurnWithHook,
        (
          bridgedAmount,
          DESTINATION_DOMAIN,
          mintRecipient,
          USDC,
          bytes32(0), // destinationCaller: 0 required by the Forwarding Service
          maxFee,
          minFinalityThreshold,
          FORWARDING_HOOK_DATA
        )
      )
    );

    emit Bridged(msg.sender, bridgedAmount, maxFee, fastMode, mintRecipient);
  }

  /**
   * @notice Executes `data` on `target` from the Safe's context, reverting on failure.
   * @param target The contract to call.
   * @param data The calldata to execute.
   * @return returnData The raw return data of the call.
   */
  function _execFromSafe(address target, bytes memory data) internal returns (bytes memory returnData) {
    bool success;
    (success, returnData) = IModuleManager(safe).execTransactionFromModuleReturnData(
      target,
      0,
      data,
      Enum.Operation.Call
    );
    require(success, ModuleCallFailed());
  }
}
