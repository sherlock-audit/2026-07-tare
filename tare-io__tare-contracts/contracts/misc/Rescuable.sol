// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {GuardianAccessControl} from "contracts/misc/GuardianAccessControl.sol";
import {IRescuable} from "contracts/misc/interfaces/IRescuable.sol";

/**
 * @title Rescuable
 * @notice Allows a guardian to rescue ERC20 and ERC721 tokens accidentally sent to the contract.
 */
abstract contract Rescuable is IRescuable, GuardianAccessControl {
  using SafeERC20 for IERC20;

  /// @inheritdoc IRescuable
  address public recoveryAddress;

  /// @inheritdoc IRescuable
  function setRecoveryAddress(address recoveryAddress_) external onlyRole(GUARDIAN_ROLE) {
    require(recoveryAddress_ != address(0), InvalidRecoveryAddress());
    recoveryAddress = recoveryAddress_;
    emit RecoveryAddressSet(recoveryAddress_);
  }

  /// @inheritdoc IRescuable
  function rescueERC20Tokens(
    address token,
    uint256 amount
  ) external whenNotPaused onlyRole(GUARDIAN_ROLE) returns (uint256 rescued) {
    require(recoveryAddress != address(0), RecoveryAddressNotSet());
    uint256 balance = IERC20(token).balanceOf(address(this));
    rescued = amount >= balance ? balance : amount;
    if (rescued > 0) {
      IERC20(token).safeTransfer(recoveryAddress, rescued);
      emit ERC20TokensRescued(token, rescued, recoveryAddress);
    }
  }

  /// @inheritdoc IRescuable
  function rescueERC721Tokens(address token, uint256 tokenId) external whenNotPaused onlyRole(GUARDIAN_ROLE) {
    require(recoveryAddress != address(0), RecoveryAddressNotSet());
    IERC721(token).safeTransferFrom(address(this), recoveryAddress, tokenId);
    emit ERC721TokensRescued(token, tokenId, recoveryAddress);
  }

  /**
   * @notice Initializes the recovery address. Must be called once from the concrete constructor.
   * @param recoveryAddress_ The initial recovery address (must be non-zero).
   */
  function _initRecoveryAddress(address recoveryAddress_) internal {
    require(recoveryAddress_ != address(0), InvalidRecoveryAddress());
    recoveryAddress = recoveryAddress_;
  }
}
