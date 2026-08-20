// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC1404} from "contracts/interfaces/IERC1404.sol";

/**
 * @title IVaultShareToken
 * @notice Interface for the role-gated ERC20 share token issued by `PortfolioVault`.
 *         Implements transfer restrictions so only addresses holding `SHAREHOLDER_ROLE`
 *         can receive shares, and exposes minting/burning permissions for the vault.
 */
interface IVaultShareToken is IERC20, IAccessControl, IERC1404 {
  error ZeroAddress();
  /** @notice Thrown when attempting to transfer shares to an account that lacks `SHAREHOLDER_ROLE`. */
  error ShareholderRestricted(address account);

  /** @notice Emitted when the linked vault address is set or updated for a given asset. */
  event VaultUpdate(address indexed asset, address vault);

  /** @notice Returns the role identifier for accounts permitted to hold and receive shares. */
  function SHAREHOLDER_ROLE() external view returns (bytes32);

  /** @notice Returns the role identifier for accounts permitted to grant/revoke `SHAREHOLDER_ROLE`. */
  function WHITELISTER_ROLE() external view returns (bytes32);

  /** @notice Returns the role identifier for accounts permitted to mint shares. */
  function MINTER_ROLE() external view returns (bytes32);

  /** @notice Returns the role identifier for accounts permitted to burn shares. */
  function BURNER_ROLE() external view returns (bytes32);

  /**
   * @notice Returns the vault address linked to the given underlying asset.
   * @param asset The underlying asset address.
   * @return The vault contract authorized to mint/burn shares against `asset`.
   */
  function vault(address asset) external view returns (address);

  /**
   * @notice Sets or updates the vault contract authorized to mint/burn shares.
   * @dev Revokes `MINTER_ROLE` and `BURNER_ROLE` from the previous vault. The new vault is
   *      not granted those roles here; the guardian must grant them in a separate action.
   * @param newVault The new vault address.
   */
  function setVault(address newVault) external;

  /**
   * @notice Mints `amount` shares to `to`. Caller must hold `MINTER_ROLE`.
   * @param to Recipient address (must hold `SHAREHOLDER_ROLE`).
   * @param amount Number of shares to mint.
   */
  function mint(address to, uint256 amount) external;

  /**
   * @notice Burns `amount` shares from `from`. Caller must hold `BURNER_ROLE`.
   * @param from Address whose shares are burned.
   * @param amount Number of shares to burn.
   */
  function burn(address from, uint256 amount) external;
}
