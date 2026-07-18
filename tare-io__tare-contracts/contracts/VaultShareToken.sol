// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Rescuable} from "contracts/misc/Rescuable.sol";
import {
  IERC1404,
  SUCCESS_CODE,
  SENDER_RESTRICTED_CODE,
  RECIPIENT_RESTRICTED_CODE,
  SUCCESS_MESSAGE,
  SENDER_RESTRICTED_MESSAGE,
  RECIPIENT_RESTRICTED_MESSAGE,
  UNKNOWN_MESSAGE
} from "contracts/interfaces/IERC1404.sol";
import {IVaultShareToken} from "contracts/interfaces/IVaultShareToken.sol";

/**
 * @title VaultShareToken
 * @notice Role-gated ERC20 share token issued by `PortfolioVault`. Transfers
 *         are restricted to addresses holding `SHAREHOLDER_ROLE`; the vault
 *         holds `MINTER_ROLE` and `BURNER_ROLE` to issue and redeem shares.
 * @dev Implements an ERC1404-style restriction interface
 *      (`detectTransferRestriction`/`messageForTransferRestriction`) so off-chain
 *      consumers can surface a human-readable reason for blocked transfers.
 */
contract VaultShareToken is ERC20, Rescuable, IVaultShareToken {
  /// @inheritdoc IVaultShareToken
  bytes32 public constant SHAREHOLDER_ROLE = keccak256("SHAREHOLDER_ROLE");

  /// @inheritdoc IVaultShareToken
  bytes32 public constant WHITELISTER_ROLE = keccak256("WHITELISTER_ROLE");

  /// @inheritdoc IVaultShareToken
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  /// @inheritdoc IVaultShareToken
  bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

  address private immutable _asset;
  address private _vault;

  /**
   * @notice Deploys the share token, wires up its role hierarchy, and grants the initial
   *         vault `MINTER_ROLE` + `BURNER_ROLE`.
   * @param name_ ERC20 token name.
   * @param symbol_ ERC20 token symbol.
   * @param initialGuardian Address that receives `GUARDIAN_ROLE` (controls all admin roles).
   * @param initialRecoveryAddress Address that rescued tokens are sent to (must be non-zero).
   * @param vault_ Initial vault contract address authorised to mint, burn, and hold shares.
   * @param asset_ The underlying asset address the vault settles in (used by `vault(asset)`).
   */
  constructor(
    string memory name_,
    string memory symbol_,
    address initialGuardian,
    address initialRecoveryAddress,
    address vault_,
    address asset_
  ) ERC20(name_, symbol_) {
    require(initialGuardian != address(0), ZeroAddress());
    require(vault_ != address(0), ZeroAddress());
    require(asset_ != address(0), ZeroAddress());

    _asset = asset_;
    _vault = vault_;

    _initGuardian(initialGuardian);
    _initRecoveryAddress(initialRecoveryAddress);
    _setRoleAdmin(WHITELISTER_ROLE, GUARDIAN_ROLE);
    _setRoleAdmin(SHAREHOLDER_ROLE, WHITELISTER_ROLE);
    _setRoleAdmin(MINTER_ROLE, GUARDIAN_ROLE);
    _setRoleAdmin(BURNER_ROLE, GUARDIAN_ROLE);
    _grantRole(MINTER_ROLE, vault_);
    _grantRole(BURNER_ROLE, vault_);
    _grantRole(SHAREHOLDER_ROLE, vault_);

    emit VaultUpdate(asset_, vault_);
  }

  /// @inheritdoc IVaultShareToken
  function vault(address asset) external view returns (address) {
    return asset == _asset ? _vault : address(0);
  }

  /// @inheritdoc IVaultShareToken
  function setVault(address newVault) external onlyRole(GUARDIAN_ROLE) {
    require(newVault != address(0), ZeroAddress());

    // Revoke mint/burn authority from the outgoing vault so an exploited old
    // vault cannot mint or burn shares.
    address oldVault = _vault;
    _revokeRole(MINTER_ROLE, oldVault);
    _revokeRole(BURNER_ROLE, oldVault);

    _vault = newVault;
    emit VaultUpdate(_asset, newVault);
  }

  /// @inheritdoc IVaultShareToken
  function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
    _mint(to, amount);
  }

  /// @inheritdoc IVaultShareToken
  function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
    _burn(from, amount);
  }

  /// @inheritdoc IERC1404
  function detectTransferRestriction(address from, address to, uint256) external view returns (uint8) {
    return _detectTransferRestriction(from, to);
  }

  /// @inheritdoc IERC1404
  function messageForTransferRestriction(uint8 restrictionCode) external pure returns (string memory) {
    if (restrictionCode == SUCCESS_CODE) return SUCCESS_MESSAGE;
    if (restrictionCode == SENDER_RESTRICTED_CODE) return SENDER_RESTRICTED_MESSAGE;
    if (restrictionCode == RECIPIENT_RESTRICTED_CODE) return RECIPIENT_RESTRICTED_MESSAGE;
    return UNKNOWN_MESSAGE;
  }

  /**
   * @notice Advertises `IERC7575Share` (ERC-7575 share-to-vault lookup), `IERC1404`
   *         (transfer restrictions), and `IERC20` interface support in addition to the
   *         standard `AccessControl` set.
   * @dev The `0xf815c03d` selector is the hard-coded `IERC7575Share` interface id from the EIP.
   */
  function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
    return
      interfaceId == 0xf815c03d ||
      interfaceId == type(IERC1404).interfaceId ||
      interfaceId == type(IERC20).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  /**
   * @dev Enforces the shareholder gate on every transfer/mint/burn. Mint (`from == 0`) and
   *      burn (`to == 0`) skip the corresponding side's role check so the vault can issue and
   *      redeem shares without first being granted `SHAREHOLDER_ROLE`.
   */
  function _update(address from, address to, uint256 value) internal override {
    uint8 restriction = _detectTransferRestriction(from, to);
    if (restriction == SENDER_RESTRICTED_CODE) revert ShareholderRestricted(from);
    if (restriction == RECIPIENT_RESTRICTED_CODE) revert ShareholderRestricted(to);

    super._update(from, to, value);
  }

  /**
   * @dev Shared shareholder-eligibility rule backing both the ERC-1404 read path
   *      (`detectTransferRestriction`) and the enforcement path (`_update`). Mint
   *      (`from == 0`) and burn (`to == 0`) skip the corresponding side's check.
   */
  function _detectTransferRestriction(address from, address to) private view returns (uint8) {
    if (from != address(0) && !hasRole(SHAREHOLDER_ROLE, from)) return SENDER_RESTRICTED_CODE;
    if (to != address(0) && !hasRole(SHAREHOLDER_ROLE, to)) return RECIPIENT_RESTRICTED_CODE;
    return SUCCESS_CODE;
  }
}
