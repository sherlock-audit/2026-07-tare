// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

/**
 * @title ISmartAccountFactory
 * @notice Deploys Gnosis Safe smart accounts with the `TrustedCalls` module enabled, the
 *         `TrustedSpender` contract pre-approved for the requested tokens, and per-route
 *         allowances set up so delegates can act on the Safe's behalf from day one.
 */
interface ISmartAccountFactory {
  /**
   * @notice Emitted when a smart account is deployed through the factory.
   * @param account The newly deployed Safe address.
   * @param deployer The caller that triggered the deployment.
   * @param owners The final owners of the Safe.
   * @param threshold The final signature threshold.
   */
  event SmartAccountDeployed(address indexed account, address indexed deployer, address[] owners, uint256 threshold);

  /** @notice Thrown when `threshold` is zero. */
  error InvalidThreshold();
  /** @notice Thrown when `owners` is empty. */
  error NoOwners();
  /** @notice Thrown when `threshold` exceeds `owners.length`. */
  error ThresholdTooHigh();
  /** @notice Thrown when `configureSmartAccount` is not called via delegatecall. */
  error NotDelegateCall();
  /** @notice Thrown when `configureSmartAccount` is invoked a second time on the same Safe. */
  error AlreadyConfigured();
  /** @notice Thrown when the supplied allowance deadline is not strictly in the future. */
  error InvalidAllowanceDeadline();

  /**
   * @notice Deploy a fully configured Safe smart account.
   * @dev `nftCollections` are pre-approved via `setApprovalForAll` to the `TrustedSpender`, but
   *      per-route NFT allowances (`setNFTAllowance`) are set lazily out-of-band to avoid an
   *      O(`nftCollections` x `trustedRecipients`) explosion at deploy time.
   *      The deployed Safe is recorded in `isDeployedSmartAccount` so integrators can verify
   *      on-chain that an account was deployed by this factory.
   * @param delegates Delegates installed on both `TrustedCalls` and `TrustedSpender` for this Safe.
   * @param currencies ERC20 tokens approved to `TrustedSpender` for this Safe.
   * @param nftCollections ERC721 collections approved (via `setApprovalForAll`) to `TrustedSpender`.
   * @param trustedRecipients Recipients allowed to receive ERC20 transfers via `TrustedSpender`.
   * @param validUntil Timestamp until which the initial ERC20 allowances are valid.
   * @param owners Final owners of the Safe.
   * @param threshold Final signature threshold.
   * @return The address of the deployed Safe.
   */
  function deploySmartAccount(
    address[] memory delegates,
    address[] memory currencies,
    address[] memory nftCollections,
    address[] memory trustedRecipients,
    uint48 validUntil,
    address[] memory owners,
    uint256 threshold
  ) external returns (address);

  /**
   * @notice Configure a Safe with modules and initial allowances.
   * @dev Must be invoked via delegatecall from a Safe during its `setup` flow. The factory
   *      stores a sentinel in the Safe's storage to ensure this runs at most once per Safe.
   * @param delegates Delegates installed on both `TrustedCalls` and `TrustedSpender`.
   * @param currencies ERC20 tokens to approve to `TrustedSpender`.
   * @param nftCollections ERC721 collections to approve (via `setApprovalForAll`) to `TrustedSpender`.
   * @param trustedRecipients Recipients allowed to receive ERC20 transfers via `TrustedSpender`.
   * @param validUntil Timestamp until which the initial ERC20 allowances are valid.
   */
  function configureSmartAccount(
    address[] memory delegates,
    address[] memory currencies,
    address[] memory nftCollections,
    address[] memory trustedRecipients,
    uint48 validUntil
  ) external;

  /**
   * @notice Predict the address that `deploySmartAccount` will produce for the given parameters.
   * @param deployer Address that will call `deploySmartAccount`.
   * @param _nonce Deployer-specific nonce to use (must match `nonces(deployer)`).
   * @param delegates See `deploySmartAccount`.
   * @param currencies See `deploySmartAccount`.
   * @param nftCollections See `deploySmartAccount`.
   * @param trustedRecipients See `deploySmartAccount`.
   * @param validUntil See `deploySmartAccount`.
   * @param owners See `deploySmartAccount`.
   * @param threshold See `deploySmartAccount`.
   * @return The deterministic Safe address that will be produced.
   */
  function predictSmartAccountAddress(
    address deployer,
    uint256 _nonce,
    address[] memory delegates,
    address[] memory currencies,
    address[] memory nftCollections,
    address[] memory trustedRecipients,
    uint48 validUntil,
    address[] memory owners,
    uint256 threshold
  ) external view returns (address);

  /** @notice Returns the next deployment nonce for `deployer`. */
  function nonces(address deployer) external view returns (uint256 nonce);

  /**
   * @notice Returns whether `account` was deployed by this factory.
   * @param account Address to check.
   * @return deployed True if `account` is a Safe deployed via `deploySmartAccount`.
   */
  function isDeployedSmartAccount(address account) external view returns (bool deployed);
}
