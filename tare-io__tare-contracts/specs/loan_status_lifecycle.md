# Loan Status Lifecycle Specification

This document defines loan status lifecycle behavior and where status checks are enforced in onchain code.
It focuses on two things:

1. Which functions contain loan status checks.
2. Which functions are callable in each loan status.

This spec documents status-based behavior only. Other guards (role checks, pause checks, loan existence checks, amount bounds, etc.) still apply.

## Loan Statuses

From `contracts/interfaces/ILoans.sol`:

- `DoesNotExist` (0)
- `Created` (1)
- `FullyFunded` (2)
- `Active` (3)
- `FullyPaid` (4)
- `Cancelled` (5)
- `ChargedOff` (6)
- `Closed` (7)

## Lifecycle Notes

- `create` initializes loans to `Created`.
- `fund` automatically sets status to `FullyFunded` when commitment is fully reached.
- `disburse` requires `FullyFunded` and sets status to `Active`.
- `updateLoanData` can set status to any value (except sentinel `DoesNotExist` means "no change").

## Functions That Contain Loan Status Checks

### Internal status guards

| Function | Check | Effect |
|---|---|---|
| `_notTerminal` | `status != DoesNotExist && status != Cancelled && status != Closed` | Blocks nonexistent loans and terminal states `Cancelled`/`Closed`. |
| `_onlyOutstanding` | `status == Active || status == ChargedOff` | Allows only active servicing states `Active` and `ChargedOff`. |
| `_onlyOutstandingOrFullyPaid` | `status == Active || status == ChargedOff || status == FullyPaid` | Allows servicing states and `FullyPaid` (e.g. residual payment waterfall). |

### External/public functions with status-gating behavior

| Function | Status check(s) used | Allowed statuses (status dimension only) |
|---|---|---|
| `updateBorrower` | `notTerminal` | `Created`, `FullyFunded`, `Active`, `FullyPaid`, `ChargedOff` |
| `updateServicer` | `notTerminal` | `Created`, `FullyFunded`, `Active`, `FullyPaid`, `ChargedOff` |
| `pay` | `onlyOutstanding` | `Active`, `ChargedOff` |
| `accrue` | `onlyOutstanding` | `Active`, `ChargedOff` |
| `chargeMiscFee` | `onlyOutstanding` | `Active`, `ChargedOff` |
| `fund` | `status == Created` | `Created` only |
| `disburse` | `status == FullyFunded` | `FullyFunded` only |
| `applyWaterfall` | `onlyOutstandingOrFullyPaid` | `Active`, `ChargedOff`, `FullyPaid` |
| `returnFunds` | `onlyOutstandingOrFullyPaid` | `Active`, `ChargedOff`, `FullyPaid` |
| `refundBorrower` | `onlyOutstandingOrFullyPaid` | `Active`, `ChargedOff`, `FullyPaid` |

### Functions that contain status logic (non-gating)

| Function | Status logic | Behavior |
|---|---|---|
| `fund` | `if (alreadyFunded + amount == commitment && status == Created)` | Auto-transition `Created -> FullyFunded`. |
| `_updateLoanData` | `if (status != DoesNotExist)` | Applies optional status update and emits `LoanStatusUpdated`. |

## Status-by-Status Call Matrix

Legend: `Y` means status check allows it, `N` means status check blocks it.

| Function | Created | FullyFunded | Active | FullyPaid | Cancelled | ChargedOff | Closed |
|---|---:|---:|---:|---:|---:|---:|---:|
| `updateBorrower` | Y | Y | Y | Y | N | Y | N |
| `updateServicer` | Y | Y | Y | Y | N | Y | N |
| `pay` | N | N | Y | N | N | Y | N |
| `accrue` | N | N | Y | N | N | Y | N |
| `chargeMiscFee` | N | N | Y | N | N | Y | N |
| `fund` | Y | N | N | N | N | N | N |
| `disburse` | N | Y | N | N | N | N | N |
| `applyWaterfall` | N | N | Y | Y | N | Y | N |
| `returnFunds` | N | N | Y | Y | N | Y | N |
| `refundBorrower` | N | N | Y | Y | N | Y | N |

## Implementation References

- `contracts/Loans.sol`
- `contracts/interfaces/ILoans.sol`
