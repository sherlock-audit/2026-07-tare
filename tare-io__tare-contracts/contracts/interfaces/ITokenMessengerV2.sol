// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

/**
 * @title ITokenMessengerV2
 * @notice Minimal surface of Circle's CCTP v2 TokenMessenger used by the bridge module.
 */
interface ITokenMessengerV2 {
  /**
   * @notice Burns `amount` of `burnToken` and emits a CCTP message minting to `mintRecipient`
   *         on `destinationDomain`.
   * @param amount The amount of `burnToken` to burn.
   * @param destinationDomain The CCTP domain of the destination chain.
   * @param mintRecipient The recipient address on the destination chain, as bytes32.
   * @param burnToken The token to burn on the source chain.
   * @param destinationCaller Address allowed to finalize on the destination (0 = anyone).
   * @param maxFee Ceiling on the fee deducted from `amount`; only the executed fee is charged.
   * @param minFinalityThreshold Source finality Circle waits for before attesting
   *        (1000 = confirmed/Fast, 2000 = finalized/Standard).
   * @param hookData Arbitrary hook payload delivered with the message.
   */
  function depositForBurnWithHook(
    uint256 amount,
    uint32 destinationDomain,
    bytes32 mintRecipient,
    address burnToken,
    bytes32 destinationCaller,
    uint256 maxFee,
    uint32 minFinalityThreshold,
    bytes calldata hookData
  ) external;
}
