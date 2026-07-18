// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {GuardianAccessControl} from "contracts/misc/GuardianAccessControl.sol";
import {ILoansAuth} from "contracts/misc/interfaces/ILoansAuth.sol";
import {Roles} from "contracts/interfaces/ILoans.sol";

/**
 * @title LoansAuth
 * @notice Loans RBAC and address books, built on `GuardianAccessControl`.
 * @dev Address books are entity-managed registries of addresses and their roles.
 *      Each address book is owned by a specific address (`addressBookOwner`).
 *      When `addressBookOwner` is `address(this)`, it is used as the canonical
 *      book for global/protocol-level approvals, managed by admins.
 */
abstract contract LoansAuth is GuardianAccessControl, ILoansAuth {
  // Bitmask constants for role approvals (matching Roles enum)
  // forge-lint: disable-next-line(incorrect-shift)
  uint256 public constant ORIGINATOR_MASK = 1 << uint8(Roles.Originator);
  // forge-lint: disable-next-line(incorrect-shift)
  uint256 public constant SERVICER_MASK = 1 << uint8(Roles.Servicer);

  /// @inheritdoc ILoansAuth
  mapping(address addressBookOwner => mapping(address grantee => uint256 roleBitmask)) public addressBook;

  constructor(address initialGuardian) {
    _initGuardian(initialGuardian);
  }

  /// @inheritdoc ILoansAuth
  function registerAddress(Roles role, address addr) external {
    // forge-lint: disable-next-line(incorrect-shift)
    addressBook[msg.sender][addr] |= (1 << uint8(role));
    emit AddressRegistered(msg.sender, role, addr);
  }

  /// @inheritdoc ILoansAuth
  function unregisterAddress(Roles role, address addr) external {
    // forge-lint: disable-next-line(incorrect-shift)
    addressBook[msg.sender][addr] &= ~(1 << uint8(role));
    emit AddressUnregistered(msg.sender, role, addr);
  }

  // ###### ADMIN ONLY FUNCTIONS ######

  /// @inheritdoc ILoansAuth
  function registerAddressOnBehalfOf(address addressBookOwner, Roles role, address addr) external onlyAdminOrGuardian {
    require(addressBookOwner != address(this), InvalidAddressBookOwner());

    // forge-lint: disable-next-line(incorrect-shift)
    addressBook[addressBookOwner][addr] |= (1 << uint8(role));
    emit AddressRegistered(addressBookOwner, role, addr);
  }

  /// @inheritdoc ILoansAuth
  function unregisterAddressOnBehalfOf(
    address addressBookOwner,
    Roles role,
    address addr
  ) external onlyAdminOrGuardian {
    require(addressBookOwner != address(this), InvalidAddressBookOwner());

    // forge-lint: disable-next-line(incorrect-shift)
    addressBook[addressBookOwner][addr] &= ~(1 << uint8(role));
    emit AddressUnregistered(addressBookOwner, role, addr);
  }

  /// @inheritdoc ILoansAuth
  function approveOriginator(address user) public onlyRole(GUARDIAN_ROLE) {
    addressBook[address(this)][user] |= ORIGINATOR_MASK;
    emit AddressRegistered(address(this), Roles.Originator, user);
    emit OriginatorApproved(user);
  }

  /// @inheritdoc ILoansAuth
  function revokeOriginator(address user) public onlyAdminOrGuardian {
    addressBook[address(this)][user] &= ~ORIGINATOR_MASK;
    emit AddressUnregistered(address(this), Roles.Originator, user);
    emit OriginatorRevoked(user);
  }

  /// @inheritdoc ILoansAuth
  function approveServicer(address user) public onlyRole(GUARDIAN_ROLE) {
    addressBook[address(this)][user] |= SERVICER_MASK;
    emit AddressRegistered(address(this), Roles.Servicer, user);
    emit ServicerApproved(user);
  }

  /// @inheritdoc ILoansAuth
  function revokeServicer(address user) public onlyAdminOrGuardian {
    addressBook[address(this)][user] &= ~SERVICER_MASK;
    emit AddressUnregistered(address(this), Roles.Servicer, user);
    emit ServicerRevoked(user);
  }

  // ###### VIEW FUNCTIONS #######

  /// @inheritdoc ILoansAuth
  function isRegisteredForRole(address addressBookOwner, Roles role, address addr) public view returns (bool) {
    return ((addressBook[addressBookOwner][addr] >> uint8(role)) & 1 == 1);
  }
}
