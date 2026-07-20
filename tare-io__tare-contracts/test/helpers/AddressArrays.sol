// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Inline builders for `address[] memory` literals.
/// @dev Solidity has no array literal syntax for dynamic memory arrays;
///      these overloads let tests express small fixed-size arrays as a
///      single expression instead of multi-line index assignments.
library AddressArrays {
  function make() internal pure returns (address[] memory arr) {
    arr = new address[](0);
  }

  function make(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function make(address a, address b) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }

  function make(address a, address b, address c) internal pure returns (address[] memory arr) {
    arr = new address[](3);
    arr[0] = a;
    arr[1] = b;
    arr[2] = c;
  }
}
