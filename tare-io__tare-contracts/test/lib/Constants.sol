// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

// Shared constants for fuzz test bounds.

// USDC amounts (6 decimals)
uint256 constant MIN_USDC_AMOUNT = 0.0001e6; // $0.0001 — smallest meaningful sub-cent
uint256 constant MAX_USDC_AMOUNT = 100_000_000_000e6; // $100B

// Timestamps (uint48)
uint48 constant MIN_TIMESTAMP = 1_231_006_505; // Jan 3 2009
uint48 constant MAX_TIMESTAMP = type(uint48).max; // Far far in the future
