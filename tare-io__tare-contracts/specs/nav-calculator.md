# NavCalculator Specification

## Overview

The `NavCalculator` is the default loan valuation strategy contract for the [Portfolio Vault](vault.md). It fetches loan data from the Loans contract, values cash already collected for the investor at par, applies configurable DPD-based (Days Past Due) discount factors to the portion of investor principal still owed by the borrower, and then applies a portfolio-level adjustment factor to the aggregated result.

## Relationship to Vault

The vault delegates loan valuation to the calculator via the `INavCalculator` interface. During NAV computation, the vault calls `getLoansValue(loans, loanIds)` once per batch — a single external call that returns the aggregate discounted value. The vault passes its own `loans` reference on every call; the calculator is stateless w.r.t. the Loans contract and reads loan data from the passed pointer via `getLoanValues()`. This keeps the vault decoupled from the loan data format while guaranteeing that the calculator and the vault cannot drift onto different ledger sources.

The vault stores the calculator address as `INavCalculator public calculator`, set by guardian via `setCalculator(address)`. This allows the valuation logic to be upgraded without redeploying the vault.

## Roles & Permissions

The contract inherits `GuardianAccessControl` which provides OpenZeppelin `AccessControl` with two base roles, plus defines one contract-specific role:

| Role                | Permissions                                                            |
| ------------------- | ---------------------------------------------------------------------- |
| `GUARDIAN_ROLE`     | `setMaxPortfolioFactor`, `grantRole`, `revokeRole`                     |
| `CALCULATING_AGENT` | `setDiscountFactor`, `setPortfolioFactor`                              |

**Role Admin Hierarchy** (determines who can `grantRole`/`revokeRole`):

| Role                | Role Admin                          |
| ------------------- | ----------------------------------- |
| `GUARDIAN_ROLE`     | `GUARDIAN_ROLE` (self-administered) |
| `CALCULATING_AGENT` | `GUARDIAN_ROLE`                     |

## Core Concepts

### Discount Factors

Each of 8 valuation buckets has an independently configurable factor in WAD (1e18 = 100%). The first five buckets classify Active loans by Days Past Due; the last three correspond to terminal loan statuses:

| Bucket       | Condition            |
| ------------ | -------------------- |
| `Current`    | 0–30 DPD             |
| `DQ30`       | 31–60 DPD            |
| `DQ60`       | 61–90 DPD            |
| `DQ90`       | 91–120 DPD           |
| `DQ120`      | 121+ DPD             |
| `ChargedOff` | status == ChargedOff |
| `Closed`     | status == Closed     |
| `Cancelled`  | status == Cancelled  |

Discount factors apply to **Active**, **ChargedOff**, **Closed**, and **Cancelled** loans. The remaining statuses are valued at 100% face value (no discount).

**Precedence**:

- **ChargedOff / Closed / Cancelled**: The bucket factor for that terminal status applies regardless of DPD. The factor is applied only to the residual `unreturnedInvestorPrincipal`; `collectedCash` is always added at par. The servicer can flip a loan to `Closed` or `Cancelled` while residual principal remains (e.g. settled-for-less, mid-funding cancellation), so these factors express recoverability of the residual rather than being inert.
- **Active**: The DPD-based bucket factor applies to `unreturnedInvestorPrincipal`; `collectedCash` is added at par.
- **`Created`**: Contributes 0 naturally — the investor has not yet funded the commitment, so `outstandingInvestorPrincipal` and `investorPrincipalWithdrawable` are both zero and the formula yields 0 without a special case.
- **All other statuses** (`FullyPaid`, `FullyFunded`): Valued at 100% with no discount. This prevents stale `nextDueDate` values from incorrectly discounting loans that have no credit risk. `FullyPaid` loans in particular may still carry undistributed cash claimable by the investor; that cash is captured by `collectedCash`.

Closed and Cancelled default to `0`: the factor writes off the residual unreturned principal while `collectedCash` is still honored at par.

$$DPD = \max\left(0,\; \left\lfloor\frac{\text{block.timestamp} - \text{nextDueDate}}{86400}\right\rfloor\right)$$

If `nextDueDate == 0` (no due date set), the loan is treated as `Current` regardless of time elapsed.

**Boundaries are inclusive on the lower bucket.** Each threshold uses a strict `>` comparison (`dpd > 30` ⇒ `DQ30`, etc.), so a loan at exactly 30 DPD stays `Current` and only becomes delinquent after a full 31 days elapse. This is intentional and mirrors the servicer's off-chain DPD logic;On-chain valuation matching the backend's DPD computation is preferred over matching the external convention.

Discount factors are configured by the `CALCULATING_AGENT` role. This allows the calculating agent to set a recovery rate for charged-off loans rather than hardcoding them to zero.

### Portfolio Adjustment Factor

A portfolio-level multiplier applied to the aggregated loan value after per-loan discounting. Defaults to `1e18` (100% = no adjustment), capped at `maxPortfolioFactor` (initial value `2e18` = 200%, guardian-tunable).

This allows the calculating agent to adjust the overall portfolio valuation for factors not captured by individual loan delinquency (e.g., purchase price discounts, portfolio-level risk).

### Configuration Version

`configurationVersion` is a monotonically increasing counter that the calculator bumps whenever a state change can affect future valuation results. It is initialized to `1` so that `0` unambiguously represents "uninitialized" for downstream consumers.

The counter is bumped (and `ConfigurationVersionBumped(newVersion)` emitted) on:

- `setDiscountFactor`
- `setPortfolioFactor`
- `setMaxPortfolioFactor` — only when the new cap is below the current `portfolioFactor` and therefore clamps it

The vault snapshots this value during NAV computation and rejects share-price-sensitive operations when the live version drifts from the snapshot, forcing a fresh `updateNav` before deposits or redemptions can be approved against the new factors. See [vault.md](vault.md) for the freshness contract.

### Per-loan valuation formula

For each loan, the calculator reads three fields from `Loans.getLoanValues()` and partitions the investor's exposure into two parts:

- **`unreturnedInvestorPrincipal`** — the share of investor capital that is still owed by the borrower (credit-exposed). Computed as `max(0, outstandingInvestorPrincipal - investorPrincipalWithdrawable)`.
- **`collectedCash`** — cash already collected on the investor's behalf and held in the Loans contract awaiting withdrawal. Computed as `max(0, investorPrincipalWithdrawable + investorInterestWithdrawable)`. This is principal already repaid by the borrower plus waterfall-allocated investor interest.

The per-loan valuation is:

$$\text{LoanValue}_i = \frac{\text{unreturnedInvestorPrincipal}_i \times \text{BucketFactor}_i}{\text{WAD}} + \text{collectedCash}_i$$

The bucket factor is selected by status (terminal statuses use their own bucket; Active loans select Current/DQ30/DQ60/DQ90/DQ120 by DPD; FullyFunded/FullyPaid use `WAD`). `collectedCash` is always valued at par regardless of bucket.

## Initialization

The constructor accepts 8 initial discount factors (one per `ValuationBucket` enum value, ordered `[Current, DQ30, DQ60, DQ90, DQ120, ChargedOff, Closed, Cancelled]`). Each must be ≤ `1e18`. By convention `Closed` and `Cancelled` are initialized to `0` (terminal statuses contribute nothing to NAV). The portfolio factor defaults to `1e18` (no adjustment).

## Data Structures

```solidity
contract NavCalculator is INavCalculator, GuardianAccessControl {
    bytes32 public constant CALCULATING_AGENT = keccak256("CALCULATING_AGENT");

    mapping(ValuationBucket bucket => uint256 factor) public discountFactors;
    uint256 public portfolioFactor;
    uint256 public maxPortfolioFactor;
    uint256 public configurationVersion; // initialized to 1; bumped on factor-changing setters
}
```

## Core Functions

### getLoansValue

```solidity
function getLoansValue(ILoans loans, uint64[] calldata loanIds) external view returns (uint256 totalValue);
```

Computes the total value of a batch of loans. Fetches loan data from `loans.getLoanValues(loanIds)` on the caller-supplied ledger pointer, computes `unreturnedInvestorPrincipal * bucketFactor + collectedCash` per loan, and returns the sum. The caller passes `loans` to guarantee the calculator and its consumer (e.g. `PortfolioVault`) agree on the ledger source for this valuation, removing any need for the calculator to hold its own `loans` reference.

- **Access**: View (no restriction)
- Skips non-existent loans (`status == DoesNotExist`) and `Created` loans
- Negative components are clamped to zero before aggregation

### applyPortfolioAdjustment

```solidity
function applyPortfolioAdjustment(uint256 rawValue) external view returns (uint256);
```

Applies the portfolio-level adjustment factor to an aggregated value.

- **Access**: View (no restriction)

### setDiscountFactor

```solidity
function setDiscountFactor(ValuationBucket bucket, uint256 factor) external;
```

Updates the discount factor for a specific valuation bucket. Factor must be ≤ `1e18` (100%).

- **Access**: `CALCULATING_AGENT` only

### setPortfolioFactor

```solidity
function setPortfolioFactor(uint256 factor) external;
```

Updates the portfolio-level adjustment factor. Factor must be ≤ `maxPortfolioFactor`.

- **Access**: `CALCULATING_AGENT` only

### setMaxPortfolioFactor

```solidity
function setMaxPortfolioFactor(uint256 newMax) external;
```

Updates the cap on `portfolioFactor`. If the current `portfolioFactor` exceeds `newMax`, it is clamped down to `newMax` and a `PortfolioFactorUpdated(newMax)` event is emitted in addition to `MaxPortfolioFactorUpdated(newMax)`.

- **Access**: `GUARDIAN_ROLE` only
- Initial value: `2e18` (200%)
- No upper bound enforced on `newMax`

### getDiscountFactor

```solidity
function getDiscountFactor(ValuationBucket bucket) external view returns (uint256);
```

Returns the current discount factor for a specific valuation bucket.

- **Access**: View (no restriction)

## Events and Errors

Events:

- `DiscountFactorUpdated(ValuationBucket indexed bucket, uint256 factor)`
- `PortfolioFactorUpdated(uint256 factor)`
- `MaxPortfolioFactorUpdated(uint256 newMax)`

Errors:

- `FactorExceedsWad()` — Discount factor exceeds 1e18
- `FactorExceedsCap()` — Portfolio factor exceeds `maxPortfolioFactor`
- `ZeroAddress()` — Zero address provided
