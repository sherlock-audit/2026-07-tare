// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

// Loan Account Constants
//
// Defines account identifiers for the loan ledger system.
// Accounts are grouped by sign behavior:
//   - 100-199: Normally positive (Assets, Contra-Liabilities, Expenses)
//   - 200-255: Normally negative (Liabilities, Contra-Assets, Revenue)
//
// Use `account >= 200` to check if an account is normally negative.
// Note: Account values are stored as uint8, limiting the max value to 255.

// =============================================================
//                    NORMALLY POSITIVE (100-199)
// =============================================================

// --- Assets (100-149) ---
uint8 constant ACC_CASH = 100;
uint8 constant ACC_BORROWER_PRINCIPAL_RECEIVABLE = 101;
uint8 constant ACC_BORROWER_INTEREST_RECEIVABLE = 102;
uint8 constant ACC_BORROWER_MISC_FEE_RECEIVABLE = 103;

// --- Contra-Liabilities (150-199) ---
uint8 constant ACC_INVESTOR_PRINCIPAL_REPAID = 150;
uint8 constant ACC_INVESTOR_INTEREST_PAID = 151;
uint8 constant ACC_SERVICER_FEE_PAID = 152;
uint8 constant ACC_ORIGINATOR_FEE_PAID = 153;
uint8 constant ACC_SERVICER_MISC_FEE_PAID = 154;

// =============================================================
//                    NORMALLY NEGATIVE (200-255)
// =============================================================

// --- Liabilities (200-249) ---
uint8 constant ACC_UNFUNDED_COMMITMENT = 200;
uint8 constant ACC_BORROWER_PAYMENT_CLEARING = 201;
uint8 constant ACC_INVESTOR_PRINCIPAL_PAYABLE = 202;
uint8 constant ACC_INVESTOR_INTEREST_PAYABLE = 203;
uint8 constant ACC_SERVICER_FEE_PAYABLE = 204;
uint8 constant ACC_ORIGINATOR_FEE_PAYABLE = 205;
uint8 constant ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE = 206;
uint8 constant ACC_SERVICER_MISC_FEE_PAYABLE = 207;
uint8 constant ACC_SERVICER_ADJUSTMENT = 208;

// --- Contra-Assets (250-255) ---
uint8 constant ACC_BORROWER_PRINCIPAL_REPAID = 250;
uint8 constant ACC_BORROWER_INTEREST_PAID = 251;
uint8 constant ACC_BORROWER_MISC_FEE_PAID = 252;
