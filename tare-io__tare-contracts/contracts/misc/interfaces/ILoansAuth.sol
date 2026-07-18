// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

import {Roles} from "contracts/interfaces/ILoans.sol";

/**
 * @title ILoansAuth
 * @notice Role-based access control for the Loans protocol.
 *         Tracks which addresses are approved by Tare as Originators or Servicers,
 *         and lets every actor maintain a per-role "address book" of counterparties
 *         that they trust to participate in their loans.
 */
interface ILoansAuth {
  event OriginatorApproved(address indexed user);
  event OriginatorRevoked(address indexed user);
  event ServicerApproved(address indexed user);
  event ServicerRevoked(address indexed user);
  /** @notice Emitted when `addressBookOwner` registers `addr` for `role` in their address book. */
  event AddressRegistered(address indexed addressBookOwner, Roles role, address indexed addr);
  /** @notice Emitted when `addressBookOwner` unregisters `addr` from `role` in their address book. */
  event AddressUnregistered(address indexed addressBookOwner, Roles role, address indexed addr);

  /** @notice Thrown when an address is not registered for the role required by the operation. */
  error UnregisteredAddress(address user);
  /** @notice Thrown when an address-book operation is attempted with a zero address book owner. */
  error InvalidAddressBookOwner();

  /**
   * @notice Register `addr` for `role` in the caller's address book.
   * @param role The role to register the address for.
   * @param addr The address to register.
   */
  function registerAddress(Roles role, address addr) external;

  /**
   * @notice Unregister `addr` from `role` in the caller's address book.
   * @param role The role to unregister.
   * @param addr The address to unregister.
   */
  function unregisterAddress(Roles role, address addr) external;

  /**
   * @notice Approve `user` as a Tare-approved Originator. Admin or guardian only.
   * @param user The user to approve.
   */
  function approveOriginator(address user) external;

  /**
   * @notice Revoke `user`'s Originator approval. Admin or guardian only.
   * @param user The user to revoke.
   */
  function revokeOriginator(address user) external;

  /**
   * @notice Approve `user` as a Tare-approved Servicer. Admin or guardian only.
   * @param user The user to approve.
   */
  function approveServicer(address user) external;

  /**
   * @notice Revoke `user`'s Servicer approval. Admin or guardian only.
   * @param user The user to revoke.
   */
  function revokeServicer(address user) external;

  /**
   * @notice Admin/guardian registers `addr` for `role` in `addressBookOwner`'s address book.
   * @param addressBookOwner The address book owner being mutated.
   * @param role The role to register.
   * @param addr The address to register.
   */
  function registerAddressOnBehalfOf(address addressBookOwner, Roles role, address addr) external;

  /**
   * @notice Admin/guardian unregisters `addr` from `role` in `addressBookOwner`'s address book.
   * @param addressBookOwner The address book owner being mutated.
   * @param role The role to unregister.
   * @param addr The address to unregister.
   */
  function unregisterAddressOnBehalfOf(address addressBookOwner, Roles role, address addr) external;

  /**
   * @notice Returns the raw role bitmask stored for `addr` in `addressBookOwner`'s address book.
   * @param addressBookOwner The address book owner being queried.
   * @param addr The address being looked up.
   * @return Bitmask of `Roles` bits set for `addr`.
   */
  function addressBook(address addressBookOwner, address addr) external view returns (uint256);

  /**
   * @notice Returns true if `addr` is registered for `role` in `addressBookOwner`'s address book.
   * @param addressBookOwner The address book owner being queried.
   * @param role The role being checked.
   * @param addr The address being checked.
   * @return True if `addr` carries `role` in `addressBookOwner`'s book.
   */
  function isRegisteredForRole(address addressBookOwner, Roles role, address addr) external view returns (bool);
}
