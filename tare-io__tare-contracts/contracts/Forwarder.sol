// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {AuthorizedForwarder} from "contracts/vendor/chainlink/AuthorizedForwarder.sol";

/**
 * @title Forwarder
 * @notice Nonce-free relay for hot-wallet operations, replacing the threshold-1 HotProxy Safe.
 *         Any authorized sender EOA can `forward()` calls to `TrustedCalls`/`TrustedSpender`
 *         concurrently, each as an independent top-level transaction with no shared nonce.
 * @dev Zero-logic wrapper over Chainlink's audited `AuthorizedForwarder`; it only pins the
 *      upstream constructor's ownership-handoff args (`recipient`, `message`) to zero so a
 *      deployment can never carry a standing ownership offer. The Forwarder can also hold a
 *      Safe owner slot in lieu of the HotProxy, confirmed with `v = 1` approved-hash
 *      signatures: an authorized sender either wraps `Safe.execTransaction` itself in
 *      `forward()` (the Safe sees the owner Forwarder as `msg.sender`, an implicit approval),
 *      or pre-approves via `forward(safe, abi.encodeCall(Safe.approveHash, (txHash)))` so
 *      anyone can execute later.
 */
contract Forwarder is AuthorizedForwarder {
  /**
   * @param token Token address this forwarder refuses to forward calls to (upstream's
   *              `linkToken` guard; pass the protocol currency).
   * @param initialOwner Address allowed to rotate authorized senders via `setAuthorizedSenders`.
   */
  constructor(address token, address initialOwner) AuthorizedForwarder(token, initialOwner, address(0), "") {}
}
