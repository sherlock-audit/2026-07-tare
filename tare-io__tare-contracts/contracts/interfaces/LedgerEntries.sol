// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.33;

// Entry type constants for standard operations
// Modify with caution, these are parsed and used by off-chain systems
uint16 constant ENTRY_LOAN_COMMITMENT = 0;
uint16 constant ENTRY_INVESTOR_CAPITAL_RECEIVED = 1;
uint16 constant ENTRY_BORROWER_PAYMENT = 2;
uint16 constant ENTRY_INTEREST_ACCRUAL = 3;
uint16 constant ENTRY_BORROWER_PRINCIPAL_PAYMENT = 4;
uint16 constant ENTRY_DISBURSEMENT_TO_BORROWER = 5;
uint16 constant ENTRY_ORIGINATOR_FEE_WITHHOLDING = 6;
uint16 constant ENTRY_SERVICER_FEE_ALLOCATION = 7;
uint16 constant ENTRY_INVESTOR_INTEREST_ALLOCATION = 8;
uint16 constant ENTRY_BORROWER_INTEREST_DEBT_CLEARANCE = 9;
uint16 constant ENTRY_SERVICER_FEE_WITHDRAWAL = 10;
uint16 constant ENTRY_INVESTOR_INTEREST_WITHDRAWAL = 11;
uint16 constant ENTRY_INVESTOR_PRINCIPAL_WITHDRAWAL = 12;
uint16 constant ENTRY_ADJUSTMENT = 13; // used for ad-hoc manual adjustments
uint16 constant ENTRY_MISC_FEE_CHARGE = 14;
uint16 constant ENTRY_MISC_FEE_DEBT_CLEARANCE = 15;
uint16 constant ENTRY_MISC_FEE_WITHDRAWAL = 16;
uint16 constant ENTRY_ORIGINATOR_FEE_WITHDRAWAL = 17;
uint16 constant ENTRY_SERVICER_FUND_RETURN = 18;
uint16 constant ENTRY_INTEREST_REVERSAL = 19;
uint16 constant ENTRY_INTEREST_RECLASSIFICATION = 20;
uint16 constant ENTRY_BORROWER_REFUND = 21;
uint16 constant ENTRY_SERVICER_FEE_REVERSAL = 22;
