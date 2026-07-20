// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LoansTestBase} from "../../setup/LoansTestBase.t.sol";

/// @notice Shared setup for all LoansNFT unit tests.
abstract contract LoansNFTTestBase is LoansTestBase {
  int128 internal constant PRINCIPAL = 100_000e6;
  string internal constant NEW_BASE_URI = "https://api.tare.io/loans/";
}
