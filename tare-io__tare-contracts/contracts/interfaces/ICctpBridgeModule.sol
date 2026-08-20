// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

/**
 * @title ICctpBridgeModule
 * @notice Single-purpose Safe module that bridges the Safe's USDC to one hardcoded recipient
 *         on one hardcoded destination chain via Circle's CCTP v2 Forwarding Service.
 * @dev Every routing parameter is fixed at deployment, so any single Safe owner can trigger a
 *      bridge without threshold signatures: funds can only ever move to the configured
 *      recipient. Disabling the module on the Safe is the kill switch.
 */
interface ICctpBridgeModule {
  /** @notice Thrown when the caller is not an owner of the configured Safe. */
  error NotSafeOwner();
  /** @notice Thrown when the amount to bridge does not exceed the mode's computed max fee. */
  error AmountTooSmall();
  /** @notice Thrown when an `execTransactionFromModule` call on the Safe fails. */
  error ModuleCallFailed();
  /** @notice Thrown when the USDC approval to the TokenMessenger returns false. */
  error UsdcApprovalFailed();
  /** @notice Thrown when a zero address or zero recipient is supplied at construction. */
  error ZeroAddress();

  /**
   * @notice Emitted when a bridge burn is submitted to CCTP.
   * @param caller The Safe owner that triggered the bridge.
   * @param amount The USDC amount burned (fees are deducted from it by Circle).
   * @param maxFee The fee allowance submitted with the burn, in USDC subunits.
   * @param fastMode True if Fast finality was requested, false for Standard.
   * @param mintRecipient The destination recipient address, as bytes32.
   */
  event Bridged(address indexed caller, uint256 amount, uint256 maxFee, bool fastMode, bytes32 mintRecipient);

  /** @notice Returns the Safe whose USDC this module bridges. */
  function safe() external view returns (address);

  /** @notice Returns the destination recipient address, as bytes32. */
  function mintRecipient() external view returns (bytes32);

  /**
   * @notice Bridge the Safe's USDC to the hardcoded recipient via CCTP at Standard finality.
   * @dev Caller must be an owner of the Safe. Approves the TokenMessenger for exactly
   *      `bridgedAmount` and burns it in the same transaction, so no allowance lingers.
   *      The fee allowance is the flat `FLAT_FEE` (Standard transfers carry no protocol fee);
   *      the amount must exceed it so a transfer can never be fully consumed by fees.
   * @param amount The USDC amount to bridge, or 0 to bridge the Safe's entire balance.
   * @return bridgedAmount The amount actually burned.
   */
  function bridge(uint256 amount) external returns (uint256 bridgedAmount);

  /**
   * @notice Bridge the Safe's USDC to the hardcoded recipient via CCTP at Fast finality.
   * @dev Same flow as `bridge`, with the fee allowance raised to
   *      `FLAT_FEE + amount * FAST_FEE_NUMERATOR / FAST_FEE_DENOMINATOR` to cover Circle's
   *      Fast protocol fee. Fast is best-effort: if Circle's live quote ever exceeds the
   *      allowance (e.g. a raised Fast rate), the transfer silently settles at Standard
   *      finality instead of reverting.
   * @param amount The USDC amount to bridge, or 0 to bridge the Safe's entire balance.
   * @return bridgedAmount The amount actually burned.
   */
  function bridgeFast(uint256 amount) external returns (uint256 bridgedAmount);
}
