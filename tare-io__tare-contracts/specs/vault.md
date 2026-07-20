# Loan Portfolio Vault

## Overview

The Portfolio Vault enables funds to gain exposure to a portfolio of loans originated on Tare's platform through a single ERC20 share token. Shareholders deposit USDC into the vault, which uses those funds to purchase loans from Tare SPV (initial investor for all loans created). The vault becomes the `investor` for each acquired loan by owning the loan NFT, and receives principal and interest distributions as borrowers make payments.

## Design Goals

- **Simplicity**: While more complex, feature-rich solutions exist we want to keep this vault as simple as possible. That means no epoch calculation, cross-chain capabilities or management/performance fees charged by the vault
- **Liquidity Management**: Fully asynchronous deposit and redemption flows enable a fund to easily own thousands of loans via a simple ERC20 token
- **Composability**: ERC-7540/ERC-7575 compatible for DeFi integration
- **Permissioning**: Only whitelisted addresses can deposit, redeem, or hold shares
- **NAV Transparency**: Fully on-chain NAV calculation from authoritative Loan ledger in Tare’s Loans contract

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            CENTRIFUGE / FUND                                │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         Centrifuge Pool                               │  │
│  │  • Holds vault shares                                                 │  │
│  │  • Manages tranches (senior/junior)                                   │  │
│  │  • Coordinates with Centrifuge Hub for cross-chain                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                         deposit/redeem shares                               │
│																		 ▼		 		                                │
└─────────────────────────────────────────────────────────────────────────────┘                                       │
																		 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│																TARE PROTOCOL 																│
│   		                                                                      │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                       PORTFOLIO VAULT                                 │  │
│  │  • ERC20 share token                                                  │  │
│  │  • Whitelisted shareholders only                                      │  │
│  │  • Fully async (ERC-7540) deposits and redemptions                    │  │
│  │  • On-chain NAV from loan portfolio                                   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    ▲                                        │
│              purchase/sell loans   │   withdraw cashflows                   │
│                    (USDC + NFT)    │   (USDC)                               │
│                                    ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         Loans.sol                                     │  │
│  │  • Loan NFTs (ERC-721)                                                │  │
│  │  • Double-entry ledger per loan                                       │  │
│  │  • Investor role receives cashflows                                   │  │
│  │  • investorWithdraw() for cashflow collection                     │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    ▲                                        │
│                                    │                                        │
│                           borrower payments                                 │
│                                    │                                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         Borrowers                                     │  │
│  │  • Make principal + interest payments                                 │  │
│  │  • Payments recorded in Loans.sol ledger                              │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Relationship to Loans.sol

The vault interacts with the Loans contract (which implements loans as NFTs) as follows:

- Vault purchases loan NFTs, becoming the investor for each loan (investor = NFT owner in LoansNFT.sol)
- As a loan investor, Vault receives cashflows from borrowers which sit in the Loans contract until the vault calls the Loans contract to withdraw these cashflows
- Vault manager can sell/transfer loan NFTs out of the vault

---

# General Requirements

## Shareholder Access Control

Only whitelisted addresses may interact with the vault as shareholders to:

- Deposit assets (USDC) into the vault
- Request redemption of shares
- Receive or hold vault shares (including via transfer)

Whitelist management is performed by `INVESTOR_MANAGER` holders.

**Single Entity Assumption: While technically multiple addresses can hold shares, we expect them to belong to the same entity (e.g., a fund using multiple wallets) and in practice most of the time only one shareholder address will interact with the vault. This simplifies the threat model:**

- No adversarial scenarios between shareholders, e.g one shareholder front-running another.
- Pro-rata redemption fairness is less critical

### Investor Verification

Only verified investors may deposit into or redeem from the vault. The vault uses `SHAREHOLDER_ROLE` on the share token as the investor verification mechanism — any address with `SHAREHOLDER_ROLE` is considered a verified investor. No separate investor role exists on the vault.

The deposit and redeem flows involve three addresses with distinct roles:

- **Owner**: The account that provides assets (deposit) or shares (redeem)
- **Controller**: The account that owns the request and authorizes claims
- **Receiver**: The account that ultimately receives shares (deposit) or assets (redeem)

Each address is verified at the appropriate step. Checks are either **explicit** (the vault calls `_requireInvestor()`) or **implicit** (the share token's `_update` hook reverts if the address lacks `SHAREHOLDER_ROLE`). The asset token (e.g. USDC) has no transfer restrictions, so asset transfers do not provide implicit checks.

**Why both controller and receiver are checked**: The deposit and redeem flows are asynchronous — time passes between request and claim. If an address is compromised between these steps, the investor manager can revoke its `SHAREHOLDER_ROLE` to block the compromised address from claiming any assets or shares. The controller check prevents the compromised address from initiating claims, and the receiver check prevents assets or shares from being directed to non-verified addresses.

#### Verification Matrix

| Function               | `owner`                      | `controller` | `receiver`                   | Rationale                                                                                  |
| ---------------------- | ---------------------------- | ------------ | ---------------------------- | ------------------------------------------------------------------------------------------ |
| `requestDeposit`       | ✅ explicit                  | —            | —                            | Assets come from owner; must be verified. Controller deferred to claim time.               |
| `deposit` / `mint`     | —                            | ✅ explicit  | ✅ implicit (share transfer) | Controller directs the claim. Receiver enforced by share token `_update`.                  |
| `cancelDepositRequest` | —                            | ✅ explicit  | ✅ explicit                  | Controller authorizes cancellation. Receiver must be a verified investor (explicit check). |
| `requestRedeem`        | ✅ implicit (share transfer) | —            | —                            | Owner proven via `safeTransferFrom`. Controller deferred to claim time.                    |
| `redeem` / `withdraw`  | —                            | ✅ explicit  | ✅ explicit                  | No share transfer at claim — receiver gets assets. Both must be explicitly checked.        |
| `cancelRedeemRequest`  | —                            | ✅ explicit  | ✅ implicit (share transfer) | Controller authorizes cancellation. Receiver gets shares back via share token transfer.    |

**Vault self-exclusion**: The vault address itself holds `SHAREHOLDER_ROLE` (required for share custody during async flows), so `_requireInvestor` alone would accept it. All async functions therefore explicitly reject the vault as `controller` (`InvalidController`) on `requestDeposit`/`requestRedeem`, and as `receiver` (`InvalidReceiver`) on `deposit`, `mint`, `redeem`, `withdraw`, `cancelDepositRequest`, and `cancelRedeemRequest`. A request with the vault as controller would be unclaimable (no one can pass `onlyAccountOrOperator(vault)`), and a payout to the vault as receiver would be a self-donation.

## Full Asynchronicity

The vault uses a fully async model for both deposits and redemptions with the Request-approve-claim pattern.

**Why both flows are async:**

1. **NAV freshness control**: The manager approves requests at a given NAV, ensuring accurate share pricing.
2. **Consistent UX**: Both deposit and redemption follow the same request-approve-claim pattern, simplifying integration and mental model.
3. **Liquidity management**: Manager has full control over when capital enters/exits the vault, enabling better portfolio management.

<summary><h2>Deposit & Redemption Flows (ERC-7540 overview)</h2></summary>
<details>

The vault implements the deposit and redemption flows adhering to [EIP-7540](https://eips.ethereum.org/EIPS/eip-7540). The following is an overview summary of these flows.

### Deposit Flow (Asynchronous)

Deposits follow the request-approve-claim pattern:

1. **Request**: Shareholder calls `requestDeposit(assets, controller, owner)`
   - Assets (USDC) transferred from owner to vault (held as pending)
   - Request recorded as pending for the controller
   - Multiple requests from the same controller are **additive** (increases pending amount)
   - Emits `DepositRequest` event
2. **Approval**: Manager calls `approveDeposit(controller, assets)` — This is the valuation point
   - Manager triggers NAV update if needed to ensure fresh pricing
   - Shares calculated at current NAV: `shares = assets * totalSupply / lastNav` (rounded down, favoring existing shareholders)
   - Shares are minted to the vault and `lastNav` is adjusted upward by `assets` — this keeps `totalSupply` and NAV synchronized for any subsequent approvals within the same NAV window
   - Supports **partial approvals**: only the specified `assets` amount is converted to shares; the remainder stays pending
   - Multiple partial approvals accumulate — claimable shares and assets are additive
   - Reverts if `assets` exceeds pending amount or if shares rounds to zero
   - Emits `DepositApproved` event
3. **Claim**: Shareholder calls `deposit(assets, receiver, controller)`
   - Pre-minted shares transferred from vault to receiver
   - Claimable amounts reduced
   - Emits `Deposit` event

### Deposit Request Cancellation

Shareholders may cancel pending deposit requests:

- Call `cancelDepositRequest(controller, receiver)` to cancel all pending assets
- Assets (USDC) returned to the specified receiver
- Emits `DepositRequestCancelled` event

### Redemption Flow (Asynchronous)

Redemptions follow the request-approve-claim pattern:

1. **Request**: Shareholder calls `requestRedeem(shares, controller, owner)`
   - Shares locked (cannot be transferred while pending)
   - Request recorded as pending for the controller
   - Multiple requests from the same controller are **additive** (increases pending amount)
   - Emits `RedeemRequest` event
2. **Approval**: Manager calls `approveRedemption(controller, shares)` - This is the valuation point
   - Manager specifies exact number of pending shares to approve (partial or full)
   - The resulting `assets` must be `<= idleLiquidity()` (vault USDC balance minus pending deposits and already-claimable redemptions); otherwise the call reverts with `InsufficientLiquidity`. This guarantees every approved redemption is immediately fundable and prevents the NAV finalization formula from underflowing
   - Share price locked at time of approval
   - Shares are burned from the vault and `lastNav` is adjusted downward by `assets` — this keeps `totalSupply` and NAV synchronized for any subsequent approvals within the same NAV window
   - Multiple partial approvals accumulate: `claimableRedeemShares` and `claimableRedeemAssets` are additive across calls, and `redeem()` uses the proportional ratio between the two for conversion — naturally handling weighted-average pricing when partial approvals happen at different NAV values
   - Request becomes (partially or fully) claimable
   - Emits `RedeemApproved` event
3. **Claim**: Shareholder calls `redeem(shares, receiver, controller)`
   - Assets (USDC) transferred to receiver (shares already burned at approval time)
   - Emits `Withdraw` event

### Redemption Request Cancellation

Shareholders may cancel pending redemption requests:

- Call `cancelRedeemRequest(controller, receiver)` to cancel all pending shares
- Shares unlocked and transferred to the specified receiver
- Emits `RedeemRequestCancelled` event

### Request States

```jsx
Pending → Claimable → Claimed
   ↘ Cancelled
```

Requests go directly from Pending to Claimable (via approval) or Cancelled.

Any state transition of a Request emits an event.

</details>

## Request Processing

- Both deposits and redemptions are approved individually by the manager per controller address
- Share price at approval time is used for the transaction
- `approveDeposit` and `approveRedemption` enforce NAV freshness: they revert if `navStart != 0` (NAV computation in progress), if `lastNav == 0` (vault not yet bootstrapped), if `block.timestamp - lastNavUpdate > maxNavAge` (stale NAV), or if `calculator.configurationVersion() != lastCalculatorConfigurationVersion` (calculator configuration changed since the cached NAV was finalized — surfaced as `CalculatorConfigurationChanged`)
- No epoch batching — each request is processed independently
- Given the **single-entity assumption**, ordering between controllers is not a concern

## Contract Parameters

- `maxNavAge` — maximum age (seconds) of NAV to allow share-price-sensitive operations
- `maxNavComputationTime` — maximum allowed duration (seconds) for a NAV computation
- `calculator` — address of the `INavCalculator` contract used for loan valuation during NAV computation
- `exchange` — address of the LoansExchange contract
- `loans` — address of the Loans contract
- `loansNFT` — address of the Loans NFT contract (ERC721Enumerable)
- `GUARDIAN_ROLE` holders — addresses (TimelockController) authorized for critical timelocked operations
- `ADMIN_ROLE` holders — addresses with immediate operational and emergency control
- `PORTFOLIO_MANAGER` holders — addresses authorized for loan portfolio operations
- `INVESTOR_MANAGER` holders — addresses authorized for investor management and shareholder whitelist

## Other features

- Rescue ERC20 function (guardian-only, sends to `recoveryAddress`)
- Rescue ERC721 function (guardian-only, sends to `recoveryAddress`)
- Recovery address for rescued funds (`setRecoveryAddress`, guardian-only)

## NAV Calculation

Net Asset Value is calculated on-chain by aggregating across all loan NFTs held by the vault. Per-loan values are read from the authoritative Loans contract ledger, then valued by the external calculator — collected investor cash at par and unreturned investor principal adjusted by a bucket factor (see [nav-calculator.md](nav-calculator.md)):

$TotalAssets = \text{Idle Currency Balance} - \text{Total Pending Deposit Assets} - \text{Total Claimable Redeem Assets} + \sum_{i=1}^{n} \text{LoanValue}_i$

Where each $\text{LoanValue}_i$ is computed by the external [calculator contract](#valuation-strategy) as `unreturnedInvestorPrincipal * bucketFactor + collectedCash`.

Pending deposit assets (USDC held by the vault but not yet converted to shares) are deducted from the idle currency balance so that new deposits do not inflate NAV before approval. Claimable redeem assets (USDC owed to shareholders for approved but unclaimed redemptions) are similarly deducted — these funds belong to redeeming shareholders and must not inflate the NAV for remaining holders. Running counters `totalPendingDepositAssets` and `totalClaimableRedeemAssets` track these efficiently without iterating controllers.

### How NAV is Computed

The vault computes NAV by iterating a **curated list of loan IDs** (`_navLoanIds`), reading each loan's data from Loans.sol, passing it through the external [calculator](#valuation-strategy) for discount-adjusted valuation, and adding the vault's stablecoin balance. The curated list — not raw ERC-721 ownership — is the single source of truth for which loans contribute to NAV. See [Curated Loan List](#curated-loan-list) for why this design was chosen and the invariants it maintains.

Each loan's investor value is the sum of 2 net amounts (net outstanding principal and net investor interest payable) and requires 4 account balances to calculate:

| Account                          | Purpose                                 |
| -------------------------------- | --------------------------------------- |
| `ACC_INVESTOR_PRINCIPAL_PAYABLE` | Total principal owed to investor        |
| `ACC_INVESTOR_PRINCIPAL_REPAID`  | Principal repaid (contra-liability)     |
| `ACC_INVESTOR_INTEREST_PAYABLE`  | Total interest accrued owed to investor |
| `ACC_INVESTOR_INTEREST_PAID`     | Interest repaid (contra-liability)      |

To avoid 4 separate external calls per loan, Loans.sol exposes a batch view function `getLoanValues(uint64[] calldata loanIds)` that returns a `LoanValue` struct per loan:

| Field                           | Type         | Description                                                                                                                       |
| ------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `outstandingInvestorPrincipal`  | `int128`     | Investor capital deployed and not yet returned: `-ACC_INVESTOR_PRINCIPAL_PAYABLE` - `ACC_INVESTOR_PRINCIPAL_REPAID`               |
| `investorPrincipalWithdrawable` | `int128`     | Principal collected by Loans and withdrawable by the investor: `-ACC_BORROWER_PRINCIPAL_REPAID` - `ACC_INVESTOR_PRINCIPAL_REPAID` |
| `investorInterestWithdrawable`  | `int128`     | Waterfall-allocated investor interest cash held by Loans: `-ACC_INVESTOR_INTEREST_PAYABLE` - `ACC_INVESTOR_INTEREST_PAID`         |
| `status`                        | `LoanStatus` | Current loan status (so vault can filter charged-off loans)                                                                       |
| `nextDueDate`                   | `uint48`     | Next payment due date (so vault can compute DPD discount factors)                                                                 |

A single external call replaces 4 per loan. Non-existent loan IDs return a zeroed struct with `status = DoesNotExist`.

### Loan Valuation

The vault delegates individual loan valuation to an external **calculator contract** (see [nav-calculator.md](nav-calculator.md) for the full specification). During NAV computation, the vault calls `calculator.getLoansValue(loans, loanIds)` once per batch — a single external call that returns the aggregate discounted value. The vault passes its own `loans` reference into every call so the calculator and the vault cannot drift onto different ledger sources; the calculator itself is stateless w.r.t. the Loans contract.

The vault stores the calculator address as `INavCalculator public calculator`, set by guardian via `setCalculator(address)`. The interface exposes two functions the vault uses:

```solidity
interface INavCalculator {
    function getLoansValue(ILoans loans, uint64[] calldata loanIds)
        external view returns (uint256 totalValue);

    function applyPortfolioAdjustment(uint256 rawValue)
        external view returns (uint256 adjustedValue);
}
```

After all per-loan batches are accumulated, the vault calls `calculator.applyPortfolioAdjustment(pendingNav)` once at finalization to apply a portfolio-level adjustment factor.

### NAV Pagination

The manager calls `updateNav(uint256 batchSize)` repeatedly to paginate through the portfolio. The vault maintains a cursor and accumulates a running total (`pendingNav`):

```
updateNav(batchSize):
    currentNonce = loansNFT.ownershipNonce(address(this))
    currentConfigurationVersion = calculator.configurationVersion()

    if navStart == 0:
        navStart = now
        lastOwnershipNonce = currentNonce
        lastCalculatorConfigurationVersion = currentConfigurationVersion
    else if currentNonce != lastOwnershipNonce
         or currentConfigurationVersion != lastCalculatorConfigurationVersion
         or navStart < now - maxNavComputationTime:
        // Restart: NFT set changed, calculator configuration changed, or computation took too long
        navStart = now
        navCursor = 0
        pendingNav = 0
        lastOwnershipNonce = currentNonce
        lastCalculatorConfigurationVersion = currentConfigurationVersion

    // Iterate the curated list. Each entry is verified to still be owned by the
    // vault; any entry that is no longer owned is popped via swap-and-pop
    // without advancing the cursor (self-healing reconciliation).
    batch = []
    while batch.length < batchSize and navCursor < _navLoanIds.length:
        loanId = _navLoanIds[navCursor]
        if loansNFT.ownerOf(loanId) != address(this):
            // swap-and-pop, stay on same cursor
            _navLoanIds[navCursor] = _navLoanIds[last]
            _navLoanIds.pop()
            emit LoanRemovedFromNav(loanId)
            continue
        batch.push(loanId)
        navCursor += 1

    pendingNav += calculator.getLoansValue(loans, batch)  // one external call per batch

    if navCursor reaches end of curated list:
        adjustedNav = calculator.applyPortfolioAdjustment(pendingNav)
        lastNav = assetToken.balanceOf(this) + adjustedNav - totalPendingDepositAssets - totalClaimableRedeemAssets
        navCursor = 0
        lastNavUpdate = now
        pendingNav = 0
        navStart = 0
```

### Curated Loan List

The vault maintains an explicit, manager-curated list of loan IDs (`_navLoanIds` plus a `_navLoanIndex` mapping for O(1) presence checks and swap-and-pop removal) that defines exactly which loans contribute to NAV. NAV iteration reads only this list — never raw `balanceOf`/`tokenOfOwnerByIndex` over the vault's NFT holdings.

#### Why a curated list

Tying NAV iteration to raw NFT ownership (`ERC721Enumerable.tokenOfOwnerByIndex` over the vault's holdings) exposes the vault to two valuation-correctness attack classes:

1. **NAV inflation via donation.** Anyone can `safeTransferFrom` a loan NFT to the vault. Under enumeration the donation would be priced into NAV on the next `updateNav` and lift the share price for the donor's redemption or for incoming approvals.
2. **Defaulting-loan dump.** A counterparty could push a worthless or distressed loan NFT into the vault, forcing the calculator to consume gas and (depending on calculator semantics) potentially recognise negative value the manager never opted into.

The curated list closes both:

- A loan only enters the list through an authorized admission path (auto-admit on `fundLoan` / `fundLoans` / `acceptSaleOffer`, or explicit `addLoansToNav` by the portfolio manager). A raw inbound transfer adds nothing to the valuation set, so donations and dumps cannot move NAV until the manager explicitly opts the loan in.
- The manager can refuse to admit (or explicitly `removeLoansFromNav`) any loan whose valuation they don't want priced into NAV.

**Restart-on-ownership-change is intentional.** Any NFT moving in or out of the vault (including unsolicited donations) bumps `ownershipNonce(vault)` and restarts an in-progress `updateNav` cycle. This is a deliberate correctness guarantee: the cached NAV must never reflect a stale view of the holdings set, so the only safe response to a mid-cycle ownership change is to recompute from a consistent snapshot. The curated list keeps the restart cheap — iteration is bounded by the curated set, not by the attacker's donations, and the donated NFT is never valued — so a griefer pays gas per transfer to add only one extra restart per cycle. If sustained interference becomes operationally costly, `ADMIN_ROLE` can `pause` and the guardian can rescue the donated NFTs via `rescueERC721Tokens`.

#### Admission and removal paths

| Path                                | Effect on list                                                       | Caller / context                            |
| ----------------------------------- | -------------------------------------------------------------------- | ------------------------------------------- |
| `fundLoan` / `fundLoans`            | Auto-adds the funded loan(s)                                         | Portfolio manager                           |
| `acceptSaleOffer`                   | Auto-adds the purchased loan                                         | Portfolio manager                           |
| `addLoansToNav(loanId)`             | Explicit admission (back-fill / donation opt-in)                     | Portfolio manager, requires vault ownership |
| `transferLoans`                     | Auto-removes each transferred loan                                   | Portfolio manager                           |
| `removeLoansFromNav(loanId)`        | Explicit removal (without transferring the NFT)                      | Portfolio manager                           |
| `updateNav` in-loop ownership check | Pops any entry whose `ownerOf` is no longer the vault (self-healing) | Anyone iterating NAV                        |

`addLoansToNav` requires the NFT to already be owned by the vault (`LoanNotOwned` otherwise) and is idempotent — re-admitting a loan already in the list is a no-op. `removeLoansFromNav` is also idempotent for loans not in the list. All four manager-facing functions (`addLoansToNav`, `removeLoansFromNav`, plus the auto-add/auto-remove paths) are gated by `_requireIdleNav`, so the list cannot mutate mid-cycle.

#### Invariants

The vault enforces two complementary mechanisms so that any change to either the curated list or the underlying NFT holdings forces a fresh `updateNav` before share-price-sensitive operations succeed:

1. **NFT in/out movement bumps `ownershipNonce(vault)`.** Detected by `_requireFreshNav` as `PortfolioHoldingsChanged`. Covers external transfers (donations, exchange settlements) and auto-remove via `transferLoans`.
2. **Operations that mutate NAV inputs without bumping the ownership nonce explicitly clear `lastNavUpdate` and emit `NavInvalidated`.** Detected by `_requireFreshNav` as `StaleNav`. Covers:
   - `addLoansToNav` — only when the loan was not already present.
   - `removeLoansFromNav` — only when the loan was actually present.
   - `setCalculator` — swaps the valuation strategy entirely.
   - `setLoans` — atomically repoints both the Loans ledger and the LoansNFT contract, and empties the curated NAV list.

Together these guarantee the invariant: **any state that affects NAV — the curated list, the NFT holdings, the vault's idle USDC, the underlying loan ledger, the loans contract pointer, or the calculator configuration — invalidates the cached NAV.** `_requireFreshNav` evaluates the more specific failure modes first (`NavComputationInProgress` → zero NAV → `PortfolioHoldingsChanged` → `CalculatorConfigurationChanged` → generic `StaleNav` age check) so operators get a precise diagnosis.

A secondary invariant — the list never double-counts a loan no longer owned by the vault — is enforced by the in-loop ownership check in `updateNav`, which acts as a self-healing reconciliation even if an external transfer leaves a stale entry between cycles.

#### View helpers

- `navLoanCount() → uint256` — current list size
- `navLoanIdAt(uint256 index) → uint64` — loan ID at a given index (used for off-chain pagination/inspection)
- `isInNav(uint64 loanId) → bool` — O(1) membership check

### Calculator Configuration Versioning

`NavCalculator` exposes a monotonic `configurationVersion()` that is bumped whenever a state change can affect loan valuation (`setDiscountFactor`, `setPortfolioFactor`, and `setMaxPortfolioFactor` only when it clamps `portfolioFactor`). The vault snapshots this value at the start of each NAV cycle (`lastCalculatorConfigurationVersion`) and rejects any share-price-sensitive call once the live version drifts from the snapshot, surfaced as `CalculatorConfigurationChanged`. Operators must re-run `updateNav` after a calculator configuration change before they can approve deposits or redemptions again. Mid-cycle configuration changes restart the in-flight NAV computation from cursor `0`.

For the full per-function NAV-invalidation behaviour, see the [Per-function NAV invalidation map](#per-function-nav-invalidation-map).

### Operations During NAV Computation

While the nav is being recomputed across multiple blocks, `nav()` returns the previously finalized result which is likely stale.
Since share price depends on NAV, operations that rely on a valid share price must be blocked while `navStart != 0`:

| Check                               | Functions                                                                                                                                                          |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `_requireIdleNav` (`navStart == 0`) | `acceptSaleOffer`, `fundLoan`, `fundLoans`, `transferLoans`, `collectCashflows`, `addLoansToNav`, `removeLoansFromNav`, `setCalculator`, `setLoans`, `setExchange` |
| `_requireFreshNav`                  | `approveDeposit`, `approveRedemption`                                                                                                                              |
| No NAV check                        | `createSaleOffer`, `cancelSaleOffer`, `requestDeposit`, `requestRedeem`, `deposit`, `mint`, `redeem`, `withdraw`, `cancelDepositRequest`, `cancelRedeemRequest`    |

Portfolio manager operations (`acceptSaleOffer`, `transferLoans`) only require that no NAV computation is in progress — they are **not** blocked by pending offers. This lets the manager buy new loans while a sale offer is open.

`createSaleOffer` does not require idle NAV because offer creation no longer escrows loans — NFTs remain owned by the vault and entries stay in the curated loan list during enumeration.

Guardian setters `setCalculator`, `setLoans`, and `setExchange` only require that no NAV computation is in progress. The first two additionally invalidate the cached NAV; `setExchange` does not, because the exchange is not an input to NAV.

`setExchange` enforces that the incoming exchange's immutable `LOANS()`, `LOANS_NFT()`, and `CURRENCY()` pointers match the vault's current `loans`, `loansNFT`, and `assetToken`, reverting `InvalidExchange` otherwise. This means **rotating the loans pair via `setLoans` and rotating the exchange are coordinated operations**: after `setLoans(newLoans, newLoansNFT)`, the previously-installed exchange (which was bound to the old pair at construction) will no longer satisfy the check, so the guardian must follow up with `setExchange(newExchange)` pointing at an exchange wired to the new pair before any further sale activity. The `CURRENCY()` check is defense-in-depth: the canonical `LoansExchange` derives it from `LOANS().currency()` at construction, but the explicit check rejects forked or custom exchanges whose currency drifted from the vault's asset.

For operational migration procedures that use these setters safely (including exchange-only, calculator-only, and full loans+NFT swaps), see [vault-migration-runbook.md](./vault-migration-runbook.md).

If the guardian rotates the exchange while older offers are still live on the previous exchange, that cleanup must be handled operationally offchain.

`updateNav` no longer checks for pending sale offers. Under the lock-based exchange flow, listed loans remain owned by the vault and therefore stay in the curated loan list during enumeration. Pending offers no longer create a portfolio undercount.

**Pending sale offers and share-price approvals**: although `approveDeposit` / `approveRedemption` are not blocked onchain while a vault sale offer is pending, approving against a NAV computed during a live offer is hazardous. The offer price is fixed at creation, while NAV keeps tracking the listed loans' ledger state. If a borrower payment is processed (`applyWaterfall`) on a listed loan whose bucket factor is below par, discounted unreturned principal converts into collected cash valued at par and NAV jumps by `(1 − factor) × repaid principal` — value the vault will never realize, because the buyer collects that cash after settlement while the vault receives only the fixed offer price. The interest leg jumps too, even at factor `1`, since accrued interest enters NAV only once waterfall-allocated; that jump nets out only if the offer price already compensated for it (see the pricing model in [loans_exchange.md](loans_exchange.md)). If there were multple shareholders, shares approved against such an inflated NAV are mispriced at the expense of remaining shareholders.

The contract does not guard against this. The LMS backend enforces it operationally by refusing `approveDeposit` / `approveRedemption` while any sale offer with the vault as seller is pending or open — consistent with the single-entity/trusted-manager model, and bypassable by a manager key acting outside the backend. An expired-but-uncancelled offer can no longer settle at its stale price and is strictly no longer hazardous, but the simpler block-until-cancelled rule is kept. The post-settlement window needs no operational rule: `acceptOffer` bumps the vault's `ownershipNonce`, so `_requireFreshNav` rejects approvals with `PortfolioHoldingsChanged` until NAV is recomputed.

`cancelSaleOffer` is intentionally exempt from NAV-idle checks because cancellation only clears offer state and unlocks NFTs in place; it does not move ownership and therefore does not disturb enumeration.

`cancelDepositRequest` and `cancelRedeemRequest` are always available because they do not depend on share price. `cancelDepositRequest` returns USDC to the receiver and decrements `totalPendingDepositAssets` — since NAV deducts pending deposits, the net effect on NAV is zero. `cancelRedeemRequest` only unlocks shares with no impact on NAV.

Blocking operations is acceptable under the single-entity shareholder assumption: the manager controls when to trigger NAV updates and can schedule them to avoid blocking critical operations.

**Ownership-change caveat**: NFT ownership can change outside the vault — most notably when an external buyer settles an open offer via `LoansExchange.acceptOffer` (the exchange transfers the NFT directly without re-entering the vault), or when a loan NFT is transferred into the vault by an outside party. Vault-internal mutating paths (`acceptSaleOffer`, `fundLoan`, `fundLoans`, `transferLoans`, `collectCashflows`, `addLoansToNav`, `removeLoansFromNav`, `setCalculator`) are all gated by `_requireIdleNav`, but external ownership shifts must still be detected.

To detect any such change, `LoansNFT` exposes a per-address monotonic `ownershipNonce(address)` mapping that is incremented inside its `_update` override (the single funnel for mints, transfers, and burns) once for the sender and once for the receiver. The vault snapshots `ownershipNonce(address(this))` at the start of each NAV cycle and re-reads it on every batch. If the nonce no longer matches, the in-progress computation is restarted: `navCursor` and `pendingNav` are reset, the new nonce is captured, and a `NavComputationStarted` event is re-emitted. The same restart branch covers the existing `maxNavComputationTime` timeout. Restarting (rather than reverting) lets the manager simply resume by calling `updateNav` again. Within each batch, entries whose `ownerOf` no longer matches the vault are popped from the curated list via swap-and-pop (self-healing — see [Curated Loan List](#curated-loan-list)).

### Gas Costs and Scaling

Scaling on Avalanche (15M gas block limit, 2s/block).
The vault is chain-agnostic — these numbers are illustrative and should be benchmarked per deployment target.
_Numbers likely underestimated → to double check_

| Portfolio size | NAV computation (batch view) | NAV computation (no batch view) |
| -------------- | ---------------------------- | ------------------------------- |
| 5,000 loans    | 4-5 blocks (~10s)            | 7 blocks (~14s)                 |
| 50,000 loans   | 44 blocks (~1.5 min)         | 70 blocks (~2.3 min)            |
| 100,000 loans  | 87 blocks (~2.9 min)         | 139 blocks (~4.6 min)           |

Every NAV computation iterates the entire portfolio.

### NAV Impact of Operations

|                              | **Impact on NAV**                                                  | **Share Price** |
| ---------------------------- | ------------------------------------------------------------------ | --------------- |
| Borrower interest accrual    | Increases: accrued interest (+)                                    | Increases       |
| Loan write off               | Decreases: outstanding principal (-)                               | Decreases       |
| Receiving borrower's payment | Neutral: cash (+), outstanding principal (-), accrued interest (-) | No change       |
| New shareholder deposit      | Increases: cash (+)                                                | No change       |
| Shareholder redemption       | Decreases: cash (-)                                                | No change       |
| Loan NFT sale (at par)       | Neutral: outstanding principal (-), accrued interest (-), cash (+) | No change       |
| Buying a loan NFT (at par)   | Neutral: cash (-), outstanding principal (+), accrued interest (+) | No change       |
| Discount factor change       | Increases or decreases: adjusted loan values change                | Changes         |

All of the above are reflected in the next NAV computation. See the [Per-function NAV invalidation map](#per-function-nav-invalidation-map) for which functions invalidate the cached NAV instantly versus which are NAV-neutral or deferred to the next scheduled `updateNav`.

#### Vanilla inbound transfers (loan NFTs and USDC)

Anyone can send a loan NFT or USDC directly to the vault without calling any vault function. The two are handled asymmetrically:

**Loan NFT donations** (`safeTransferFrom` or low-level `transferFrom`) bump `ownershipNonce(vault)` inside `LoansNFT._update`. The donated loan is **not** added to the curated `_navLoanIds` list — only `fundLoan` / `fundLoans`, `acceptSaleOffer`, and `addLoansToNav` admit loans — so it contributes zero to NAV. The nonce bump surfaces at the next `_requireFreshNav` as `PortfolioHoldingsChanged` (and restarts any in-progress `updateNav`), forcing a fresh cycle before the next approval. The guardian can rescue the NFT via `rescueERC721Tokens`. See [NAV inflation via donation](#why-a-curated-list) for the threat model.

**USDC donations** (`assetToken.transfer(vault, amount)`) have no receive hook and no nonce equivalent. The deposit is silently credited to `assetToken.balanceOf(this)` and is only reflected in `lastNav` on the next `updateNav` cycle; until then `_requireFreshNav` keeps the cached NAV valid until it ages past `maxNavAge` (reverting as `StaleNav`).

**Why USDC transfers do not invalidate NAV.** Hooking ERC20 inbound transfers as an invalidation trigger would create a trivial DoS: any holder of a single USDC unit could spam 1-wei `transfer`s to the vault and force `_requireFreshNav` to fail until the manager re-runs `updateNav`, indefinitely blocking `approveDeposit` / `approveRedemption`. Bounding staleness by time (`maxNavAge`) instead means a donation can at worst sit unreflected for one staleness window before the next mandatory refresh picks it up. The donation then accrues pro-rata to existing holders, which is acceptable under the single-entity shareholder assumption; the guardian can rescue it via `rescueERC20Tokens` if desired.

#### Per-function NAV invalidation map

The table below maps each externally callable vault function to its NAV-freshness impact. The **Invalidates NAV?** column is **Yes** only when the operation causes _instant_ invalidation — i.e. the next `approveDeposit` / `approveRedemption` reverts at `_requireFreshNav` until the manager re-runs `updateNav`. Otherwise the column is **No**, and the explanation classifies the row as either:

- **NAV-neutral** — the effect on `lastNav` is exactly zero by construction (two NAV inputs move by equal and opposite amounts in the same call), so no refresh is needed; or
- **Deferred** — the operation changes a NAV input without triggering invalidation, so the change is reflected only on the next scheduled `updateNav`; freshness is bounded only by `maxNavAge`.

| Function                                                                                                     | Invalidates NAV?       | Mechanism                                  | Why neutral / why invalidated                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------------------------ | ---------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fundLoan` / `fundLoans`                                                                                     | **Yes**                | explicit `_invalidateNav`                  | At-par origination is NAV-neutral _only_ when `portfolioFactor == 1e18`; under any other factor the new bucket entry is discounted while idle USDC drops at par. Vault is already the investor, so no NFT transfer / nonce bump occurs — invalidated explicitly to keep the cached NAV correct under all factor settings.                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `collectCashflows` (investor cash withdraw)                                                                  | **Yes**                | explicit `_invalidateNav`                  | Value moves from `investorPrincipalWithdrawable + investorInterestWithdrawable` (priced into `LoanValue` by the calculator) to idle USDC at par. No NFT moves, so no nonce bump; invalidated explicitly because the per-loan ledger and `idleLiquidity` both change. **Reverts `LoanNotInNav` if any loanId is not in the curated NAV set** — otherwise cashflows from an excluded loan would silently inflate NAV via `idleLiquidity`.                                                                                                                                                                                                                                                                                                    |
| `requestDeposit`                                                                                             | No                     | —                                          | **NAV-neutral**: incoming USDC is offset 1:1 by `totalPendingDepositAssets`, which the NAV formula subtracts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `cancelDepositRequest`                                                                                       | No                     | —                                          | **NAV-neutral**: inverse of `requestDeposit`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `requestRedeem`                                                                                              | No                     | —                                          | **NAV-neutral**: only escrows shares to the vault. NAV is asset-side; pricing is deferred to `approveRedemption`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `cancelRedeemRequest`                                                                                        | No                     | —                                          | **NAV-neutral**: only releases escrowed shares back to the owner. No asset movement.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `deposit` / `mint` (claim)                                                                                   | No                     | —                                          | **NAV-neutral**: releases pre-minted shares to the receiver. All NAV accounting (`lastNav += assets`, share mint) already happened at `approveDeposit`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `redeem` / `withdraw` (claim)                                                                                | No                     | —                                          | **NAV-neutral**: idle USDC ↓ and `totalClaimableRedeemAssets` ↓ by the same amount — both deducted from NAV, so the net effect cancels. Shares were already burned at `approveRedemption`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `createSaleOffer`                                                                                            | No                     | —                                          | **NAV-neutral**: offer creation only approves the exchange to pull NFTs; no transfer and no calculator inputs change.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `cancelSaleOffer`                                                                                            | No                     | —                                          | **NAV-neutral**: clears offer state and pre-approvals; no NFT or USDC movement.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `approveDeposit` / `approveRedemption`                                                                       | No                     | —                                          | **NAV-neutral** (consumes NAV): updates `lastNav` in-place by the approved amount and keeps `totalSupply` synchronized so subsequent approvals at the same snapshot remain consistent.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `acceptSaleOffer`                                                                                            | **Yes**                | `ownershipNonce` bump                      | NFT transfer into the vault bumps `ownershipNonce(vault)`. The economic effect is only NAV-neutral if `offer.price` equals the calculator-implied value; since the SPV sets `price` independently, a fresh `updateNav` is required to reconcile.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `transferLoans`                                                                                              | **Yes**                | `ownershipNonce` bump                      | NFT transfer out of the vault. Auto-removes the loan from the curated list as well.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `addLoansToNav`                                                                                              | **Yes (when changed)** | explicit `_invalidateNav`                  | Grows the curated valuation set without an NFT transfer; cached NAV excluded these loans.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `removeLoansFromNav`                                                                                         | **Yes (when changed)** | explicit `_invalidateNav`                  | Shrinks the curated valuation set without an NFT transfer; cached NAV still included these loans.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `setCalculator`                                                                                              | **Yes**                | explicit `_invalidateNav`                  | Replaces the valuation strategy entirely.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `setLoans`                                                                                                   | **Yes**                | explicit `_invalidateNav`                  | Atomically repoints `loans` and `loansNFT`. Reverts unless `ILoans(newLoans).currency() == assetToken` (`AssetMismatch`) and `ILoansNFT(newLoansNFT).LOANS_CONTRACT() == newLoans` (`ReversePointerMismatch`). Also **empties the curated NAV list** — the old tokenIds belong to the previous NFT collection and would mis-value (or revert) against the new pair. The existing exchange likely becomes incompatible and must be re-pointed via `setExchange`. **Scaling caveat**: clearing emits one `LoanRemovedFromNav` per curated loan; for portfolios large enough that the block gas limit would be exceeded, the manager should first shrink the curated list with batched `removeLoansFromNav` calls before invoking `setLoans`. |
| External NFT transfer into the vault (donation, exchange settlement of an outgoing offer)                    | **Yes**                | `ownershipNonce` bump                      | Detected outside any vault function; surfaces as `PortfolioHoldingsChanged`. The donated loan is **not** auto-admitted to the curated list. See [Vanilla inbound transfers](#vanilla-inbound-transfers-loan-nfts-and-usdc).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| External USDC transfer into the vault (donation, mistaken send)                                              | No                     | —                                          | **Deferred**: ERC20 has no receive hook and no nonce; hooking inbound transfers would enable a 1-wei spam DoS on `approveDeposit` / `approveRedemption`. The donation sits in `assetToken.balanceOf(this)` and is picked up on the next scheduled `updateNav`; staleness is bounded by `maxNavAge`. See [Vanilla inbound transfers](#vanilla-inbound-transfers-loan-nfts-and-usdc).                                                                                                                                                                                                                                                                                                                                                        |
| Calculator factor change (`setDiscountFactor`, `setPortfolioFactor`, `setMaxPortfolioFactor` when it clamps) | **Yes**                | calculator's `configurationVersion()` bump | Surfaces at `_requireFreshNav` as `CalculatorConfigurationChanged`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |

### Cashflow Collection

Cashflow collection is independent from NAV calculation. Uncollected cashflows are already reflected in loan account balances — the vault reads them during NAV enumeration without needing to withdraw first.

The vault uses a **pull-based** model: the manager calls `collectCashflows(loanIds, ref)` on the vault, which in turn calls `investorWithdraw()` on the Loans contract to withdraw accumulated cashflows for specified loans. Every `loanId` must currently be in the curated NAV set (`_navLoanIds`); otherwise the call reverts with `LoanNotInNav` so that proceeds from an excluded loan can never re-enter NAV via `idleLiquidity`.

After collection, the vault's USDC balance increases and the loans' receivable balances decrease by the same amount. The next NAV computation automatically reflects both changes — no atomic cache update needed.

Pull was chosen over push (ERC1363 `transferAndCall()`) because:

- The vault controls when to collect, avoiding reentrancy risks
- Borrower payments are never blocked by vault issues
- Simpler vault logic with no callback handling
- ERC1363 is not sufficiently adopted (not supported by Safe)

**Cost per loan**: ~78,000 gas for ledger entries (2 entries × ~39k each) + ~45,000 gas USDC transfer per batch (amortized).

### NAV Lag / Staleness

Under the single-entity shareholder model, any "staleness" resulting from interest accrued or loans charged off since the last NAV update results only in "self-dilution," which does not change the entity's total on-chain net worth, only the number of shares owned:

- Using a "stale" NAV, the entity has fewer shares, but each share is worth slightly more.
- With a "fresh" NAV, the entity has more shares, but each share is worth slightly less.

In both cases the entity's total net worth from the vault is the same. The manager should trigger a NAV update before approving deposits or redemptions to ensure fair pricing.

### Alternative Considered: Vault-Side Loan Value Cache

An alternative approach would have maintained a cached value per loan and an aggregate total in the vault:

```solidity
mapping(uint64 loanId => uint256) public cachedLoanValue;
uint256 public totalCachedLoanValue;

function nav() public view returns (uint256) {
    return asset.balanceOf(address(this)) + totalCachedLoanValue;
}
```

NAV would be available via O(1) read with no blocking. The manager would incrementally refresh cached values for loans with recent activity (detected from on-chain events). A periodic full sweep via cursor would reconcile any missed changes.

**Pros**: No blocking during NAV computation — all operations always available. NAV is always readable. Targeted refreshes only touch changed loans instead of the full portfolio.

**Cons**: Every operation that changes a loan's value must maintain the cache:

- `collectCashflows` must **atomically** refresh `cachedLoanValue` for collected loans in the same transaction — otherwise the withdrawn cash is double-counted (vault cash increases but `totalCachedLoanValue` still includes the withdrawn amount). Direct calls to `investorWithdraw` on Loans.sol bypassing the vault would silently break NAV consistency.
- `acceptSaleOffer` and `createSaleOffer`/`transferLoans` must update `totalCachedLoanValue` at purchase/sale time.
- Missed refreshes cause staleness (acceptable under single-entity assumption, but adds operational burden).
- Storage cost: 1 extra slot per loan (22,100 gas first write), plus write overhead on every refresh (~10,000 gas for 2 warm SSTOREs to update `cachedLoanValue` and `totalCachedLoanValue`).

The full enumeration approach avoids all of this complexity. NAV is computed from the authoritative source (Loans.sol account balances) with no derived state to keep in sync. The blocking window during computation is acceptable under the single-entity assumption. If portfolio sizes grow beyond expectations or blocking becomes operationally problematic, the vault-side cache can be added without changes to Loans.sol.

## Loan Portfolio Management

The vault is **not** the initial investor for loans originated on Tare. Instead, it acquires existing loans from sellers (typically Tare SPV, the initial investor for all originated loans) via the `LoansExchange` contract, which provides atomic USDC-for-NFT settlement. The vault can also sell loans though the same exchange contract or transfer them out.

### Loan NFT Ownership

The vault tracks the loans that contribute to NAV in a **curated list** (`_navLoanIds`, see [Curated Loan List](#curated-loan-list)). Raw NFT ownership is still answered by the Loans NFT contract:

- `loansNFT.balanceOf(vault)` — number of loan NFTs the vault owns (may exceed `navLoanCount()` if donations are present and not yet admitted, or if the manager has called `removeLoansFromNav` without transferring out)
- `loansNFT.ownerOf(loanId)` — current owner of a given loan
- `vault.navLoanCount()` / `vault.navLoanIdAt(i)` / `vault.isInNav(loanId)` — curated loan list membership

The vault is the authoritative source for which loans price into NAV; `loansNFT` is the authoritative source for raw ownership. The two are reconciled by the `_requireFreshNav` gates (ownership-nonce + explicit `NavInvalidated`) and by the self-healing in-loop ownership check inside `updateNav`.

| Operation         | Mechanism                                                                              |
| ----------------- | -------------------------------------------------------------------------------------- |
| **Buying loans**  | Atomic swap via `LoansExchange.acceptOffer()`; ownership tracked by Loans NFT contract |
| **Selling loans** | Manager creates offer on `LoansExchange`, or transfers NFT directly for internal moves |
| **Enumeration**   | Query Loans NFT contract via `ERC721Enumerable` for NAV calculation                    |

The vault implements `IERC721Receiver` (`onERC721Received`) to accept incoming loan NFTs via `safeTransferFrom`.

### Purchasing Loans

The vault purchases loans through the `LoansExchange` contract. The full flow:

1. **Off-chain agreement**: Vault manager and seller (current investor) agree on price and loan(s)
2. **Address book registration**: Seller registers the vault's address in their address book on the Loans contract for `Roles.Investor` (via `loans.registerAddress(Roles.Investor, vaultAddress)`)
3. **Offer creation**: Seller calls `LoansExchange.createOffer(buyer, price, deadline, loanIds)`. Loan NFTs remain owned by the seller but are locked to the exchange.
4. **Offer acceptance**: Manager calls `acceptSaleOffer(offerId)` on the vault, which:
   - Reads the offer from `LoansExchange.getOffer(offerId)` to determine the price
   - Approves `LoansExchange` to pull the required USDC from the vault (if price > 0)
   - Calls `LoansExchange.acceptOffer(offerId)`
   - USDC flows from vault to seller; loan NFT(s) flow from seller to vault via the exchange's unlocker authority
   - After the exchange call, verifies the vault now owns each loan NFT listed in the offer, reverting `LoanNotOwned` otherwise (defense against a malicious or buggy exchange that takes payment without delivering every NFT)
   - Admits each delivered loan into the curated NAV list via `_addLoanToNav`
5. **Result**: The vault now owns the loan NFT(s) and is the investor for each loan, entitled to future cashflows

**Preconditions**:

- The vault must hold sufficient idle USDC to cover the offer price
- The vault must be the designated `buyer` on the offer
- No NAV computation in progress (`navStart == 0`)

**Signature**: `acceptSaleOffer(uint64 offerId) external` — `PORTFOLIO_MANAGER` only.

### Selling Loans

The vault supports two mechanisms for moving loans out:

#### Via LoansExchange (priced sales)

For sales where USDC payment is required, the vault creates an offer on `LoansExchange`:

1. **Address book registration**: The buyer's address is registered in the vault's address book on the Loans contract for `Roles.Investor` via `vault.registerAddress(address)` (callable by the portfolio manager, admin, or guardian).
2. **Offer creation**: Manager calls `createSaleOffer(buyer, price, deadline, loanIds)` on the vault, which:
   - Approves `LoansExchange` to operate each loan NFT
   - Calls `LoansExchange.createOffer(buyer, price, deadline, loanIds)`
   - Loan NFTs remain owned by the vault but are locked to the exchange
3. **Buyer acceptance**: Buyer calls `LoansExchange.acceptOffer(offerId)` directly
   - USDC flows from buyer to vault; loan NFT(s) flow from vault to buyer via the exchange's unlocker authority
4. **Cancellation**: Manager can cancel via `cancelSaleOffer(offerId)` on the vault, which calls `LoansExchange.cancelOffer(offerId)`. Listed NFTs stay in the vault and are simply unlocked. `cancelSaleOffer` does not require idle NAV because it does not change ownership.

**Signatures**:

- `createSaleOffer(address buyer, uint128 price, uint48 deadline, uint64[] calldata loanIds) external returns (uint64 offerId)` — `PORTFOLIO_MANAGER` only
- `cancelSaleOffer(uint64 offerId) external` — `PORTFOLIO_MANAGER` only

#### Via bare ERC721 transfer (internal moves)

For ownership changes where no USDC payment is needed (e.g., internal restructuring, returning a loan to the SPV):

- Manager calls `transferLoans(loanIds, recipient)` on the vault
- Vault calls `loansNFT.transferFrom(vault, recipient, loanId)` for each loan
- No address book requirement (LoansNFT does not restrict standard ERC721 transfers)
- No USDC settlement

**Signatures**:

- `transferLoans(uint64[] calldata loanIds, address recipient) external` — `PORTFOLIO_MANAGER` only. Uses `transferFrom` (does not invoke `onERC721Received`).

> **Operational requirement**: `transferLoans` is the only outbound path that synchronously removes the loan from the curated loan list. Any other way of moving a loan NFT out of the vault (for example, an external buyer settling an open sale offer via `LoansExchange.acceptOffer`, or any future hot-wallet/admin path that calls `loansNFT.transferFrom` directly) leaves a stale entry in the list until the next `updateNav` cycle reconciles it via the ownership-nonce sync. The list entry is not double-counted (sync drops it before valuation), but managers should prefer `transferLoans` for predictable, single-tx accounting.

Offer creation, offer acceptance, and bare transfers are blocked while NAV is not idle (`navStart != 0`). Pending sale offers no longer block NAV.

### Direct Loan Funding

In addition to secondary-market purchases via `LoansExchange`, the vault can directly fund loans on `Loans.sol` when the vault is already set as the loan's investor (that is, the vault owns the loan NFT).

- Manager calls `fundLoan(loanId, amount, timestamp, ref)` on the vault
- Vault approves `Loans.sol` to pull the funding USDC
- Vault calls `loans.fund(loanId, amount, timestamp, ref)`
- Funds move from vault USDC balance into `Loans.sol` custody for that loan

**Preconditions**:

- `amount > 0`
- Vault is the current investor for `loanId` (enforced by `Loans.sol`)
- Vault has sufficient idle liquidity: `max(0, asset.balanceOf(vault) - totalPendingDepositAssets - totalClaimableRedeemAssets) >= amount`
- No NAV computation in progress (`navStart == 0`)

**Signatures**:

- `fundLoan(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external` — `PORTFOLIO_MANAGER` only. Thin wrapper around `fundLoans` for the single-loan case.
- `fundLoans(uint64[] calldata loanIds, int128[] calldata amounts, uint48 timestamp, bytes32 ref) external` — `PORTFOLIO_MANAGER` only. Atomic batch funding: all loans fund in one transaction or the whole call reverts. `loanIds` and `amounts` must be the same non-zero length (`ZeroAmount` / `LengthMismatch` otherwise); each amount must be positive (`ILoans.InvalidAmount`); the sum must fit within `idleLiquidity()` (`InsufficientLiquidity`). One `forceApprove` covers the batch total and one `_invalidateNav` runs at the end.

### Address Book Management

The Loans contract uses per-address role registries ("address books") to control who can be assigned loan roles. The vault interacts with address books in different ways depending on the operation:

| Operation                       | Who registers             | What is registered                                          |
| ------------------------------- | ------------------------- | ----------------------------------------------------------- |
| **Purchasing** (vault is buyer) | Seller                    | Vault address in seller's address book for `Roles.Investor` |
| **Selling via LoansExchange**   | Vault (PM/admin/guardian) | Buyer address in vault's address book for `Roles.Investor`  |
| **Bare ERC721 transfer**        | No registration needed    | —                                                           |

`Roles.Investor` is the only role the vault's own address book is ever read for (buyers, and counterparty sellers on the exchange), so the vault exposes dedicated buyer-management functions callable by `PORTFOLIO_MANAGER`, `ADMIN_ROLE`, or `GUARDIAN_ROLE`:

- `registerAddress(address addr)` — forwards to `loans.registerAddress(Roles.Investor, addr)` (vault is `msg.sender`, so the vault's own address book is populated)
- `unregisterAddress(address addr)` — forwards to `loans.unregisterAddress(Roles.Investor, addr)`

The vault owns loan NFTs directly (unlocked), so `collectCashflows()` calls `investorWithdraw()` on behalf of the vault.

## No Fees

The vault does not charge any fees.

All returns flow through to shareholders proportionally.

---

## Liquidity Management

### Per-Controller Mapping Approach

Given the **single-entity shareholder assumption**, request ordering (FIFO, pro-rata, etc.) is unnecessary. Instead, the vault tracks pending and claimable amounts per controller address using simple mappings:

```solidity
// Deposit request state per controller
mapping(address controller => uint256) public pendingDepositAssets;
mapping(address controller => uint256) public claimableDepositShares;

// Redemption request state per controller
mapping(address controller => uint256) public pendingRedeemShares;
mapping(address controller => uint256) public claimableRedeemAssets;
```

**Why this is sufficient:**

- All shareholder addresses belong to the same entity — no adversarial ordering concerns
- Manager approves requests individually by controller address
- Simpler to implement and audit than queue-based approaches

---

## Technical Implementation

### Data Structures

```solidity
// === Request State (per controller) ===

// Deposit requests
mapping(address controller => uint256) public pendingDepositAssets;    // Assets awaiting approval
mapping(address controller => uint256) public claimableDepositShares;  // Shares ready to mint
mapping(address controller => uint256) public claimableDepositAssets;  // Asset equivalent of claimable shares (for proportional conversion)
// Both claimable assets and shares are tracked (rather than a stored price-per-share) to support
// partial approvals at different NAV snapshots. A single price-per-share would be overwritten on each
// new approval, corrupting the conversion rate for shares from earlier approvals. This would also block
// new deposit requests as long as the controller has unclaimed shares, since any new approval would
// override the previous price. By accumulating both values, deposit()/mint() derive the effective
// weighted-average price from their ratio (claimableShares / claimableAssets).

// Redemption requests
mapping(address controller => uint256) public pendingRedeemShares;     // Shares awaiting approval
mapping(address controller => uint256) public claimableRedeemShares;   // Shares ready to claim (used for proportional conversion)
mapping(address controller => uint256) public claimableRedeemAssets;   // Assets ready to withdraw

// === Aggregate Counters ===
uint256 public totalPendingDepositAssets;  // Running counter of all pending deposit assets across controllers.
                                           // Incremented on requestDeposit, decremented on approveDeposit (by approved amount) and cancelDepositRequest.
                                           // Used to deduct pending deposits from NAV (avoids iterating controllers).

uint256 public totalClaimableRedeemAssets; // Running counter of all claimable redeem assets across controllers.
                                           // Incremented on approveRedemption, decremented on redeem.
                                           // Used to deduct claimable redemptions from NAV (avoids iterating controllers).

// === NAV State (Curated List Enumeration) ===
uint64[] internal _navLoanIds;         // Curated list of loan IDs that price into NAV
mapping(uint64 => uint256) internal _navLoanIndex; // 1-indexed presence map (0 = absent) for O(1) lookup + swap-and-pop
uint256 public navCursor;              // Index into _navLoanIds for pagination
uint256 public pendingNav;             // Running total of loan values during computation
uint256 public navStart;               // Timestamp when current NAV computation started (0 when idle)
uint256 public lastNav;                // Final NAV value from most recent completed computation
uint256 public lastNavUpdate;          // Timestamp of the most recent completed NAV computation
uint256 public lastOwnershipNonce;     // Snapshot of loansNFT.ownershipNonce(vault) captured at the start of each NAV cycle
uint256 public lastCalculatorConfigurationVersion;   // Snapshot of calculator.configurationVersion() captured at the start of each NAV cycle;
                                       // mismatch with the current version blocks share-price-sensitive operations

// === Configuration ===
uint256 public maxNavAge;              // Maximum age (seconds) of NAV to allow share-price-sensitive operations
uint256 public maxNavComputationTime;  // Maximum allowed duration (seconds) for a NAV computation

// === External References ===
ILoans public loans;                   // Loans contract (mutable, guardian-only)
ILoansNFT public loansNFT;             // Loans NFT contract (ERC721Enumerable, mutable, guardian-only)
ILoansExchange public exchange;        // Exchange contract (mutable, guardian-only)
INavCalculator public calculator;      // Loan valuation strategy contract (mutable, guardian-only)
IERC20 public immutable assetToken;    // Underlying asset (USDC)
IVaultShareToken public immutable shareToken; // Vault share token contract (ERC20)

// === Recovery ===
address public recoveryAddress;        // Pre-set address where rescued tokens/NFTs are sent (guardian-only to change)
```

### Roles & Permissions

All contracts in the protocol use OpenZeppelin `AccessControl` for role-based permissions. Vault-side and loan-side contracts share a common base contract `GuardianAccessControl` that provides `GUARDIAN_ROLE`, `ADMIN_ROLE`, guardian initialization, and an at-least-one-guardian invariant.

```solidity
bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 public constant PORTFOLIO_MANAGER = keccak256("PORTFOLIO_MANAGER");
bytes32 public constant INVESTOR_MANAGER = keccak256("INVESTOR_MANAGER");
// SHAREHOLDER_ROLE lives on VaultShareToken, not on the vault itself
```

| Role                | Permissions                                                                                                                                                                                                                                         |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GUARDIAN_ROLE`     | `pause`, `rescueERC20Tokens`, `rescueERC721Tokens`, `unpause`, `setLoans`, `setExchange`, `setCalculator`, `setRecoveryAddress`, `registerAddress`, `unregisterAddress`, `setMaxNavAge`, `setMaxNavComputationTime`                                 |
| `ADMIN_ROLE`        | `pause`, `registerAddress`, `unregisterAddress`, `setMaxNavAge`, `setMaxNavComputationTime`                                                                                                                                                         |
| `PAUSER_ROLE`       | `pause` only — least-privilege incident-response role (e.g. 3rd-party monitoring services)                                                                                                                                                          |
| `PORTFOLIO_MANAGER` | `acceptSaleOffer`, `createSaleOffer`, `cancelSaleOffer`, `transferLoans`, `updateNav`, `collectCashflows`, `fundLoan`, `fundLoans`, `addLoansToNav`, `removeLoansFromNav`                                                                           |
| `INVESTOR_MANAGER`  | `approveDeposit`, `approveRedemption`, `updateNav`, `collectCashflows`                                                                                                                                                                              |
| `SHAREHOLDER_ROLE`  | `requestDeposit` (owner), `deposit`, `mint`, `redeem`, `withdraw` (controller + receiver), `cancelDepositRequest`, `cancelRedeemRequest` (controller), receive share transfers. See [Investor Verification](#investor-verification) for full matrix |

**Role Admin Hierarchy** (OZ AccessControl — determines who can `grantRole`/`revokeRole`):

| Role                | Role Admin (who can grant/revoke)   |
| ------------------- | ----------------------------------- |
| `GUARDIAN_ROLE`     | `GUARDIAN_ROLE` (self-administered) |
| `ADMIN_ROLE`        | `GUARDIAN_ROLE`                     |
| `PAUSER_ROLE`       | `GUARDIAN_ROLE`                     |
| `PORTFOLIO_MANAGER` | `GUARDIAN_ROLE`                     |
| `INVESTOR_MANAGER`  | `GUARDIAN_ROLE`                     |

Granting or revoking `ADMIN_ROLE`, `PAUSER_ROLE`, `PORTFOLIO_MANAGER`, and `INVESTOR_MANAGER` requires `GUARDIAN_ROLE` — i.e., a timelocked operation through the TimelockController. `GUARDIAN_ROLE` is self-administered: only an existing guardian can grant or revoke other guardians.

**Last-Guardian Invariant**: `GuardianAccessControl` enforces an on-chain at-least-one-guardian invariant. `renounceRole` is disabled entirely (always reverts with `RenounceRoleDisabled`), and revoking the last remaining guardian reverts with `LastGuardian` — so the contract can never drop to zero guardians and permanently lose role management.

**Constructor Pattern**: All contracts call `_initGuardian(initialGuardian)` which sets up the role admin hierarchy (`GUARDIAN_ROLE` administers itself and `ADMIN_ROLE`) and grants `GUARDIAN_ROLE` to the initial guardian. No admin is granted at construction — the guardian must explicitly grant `ADMIN_ROLE` (and other roles) post-deployment.

**Role Hierarchy**:

- `GUARDIAN_ROLE` is held by a TimelockController — all guardian operations have a publicly visible delay before execution (see [timelocked-tx.md](timelocked-tx.md))
- `ADMIN_ROLE` is held by multisig for immediate operational and emergency actions (e.g., `pause`)
- `PORTFOLIO_MANAGER` for loan portfolio operations
- `INVESTOR_MANAGER` manages investor lifecycle (deposit/redemption approvals)

**Shareholder Whitelist**: `SHAREHOLDER_ROLE` lives on the `VaultShareToken` contract (not on the vault). The VaultShareToken has its own `GUARDIAN_ROLE` and role hierarchy. The `WHITELISTER_ROLE` on VaultShareToken manages `SHAREHOLDER_ROLE` grants. In practice, the entity holding `INVESTOR_MANAGER` on the vault is granted `WHITELISTER_ROLE` on VaultShareToken at deployment time — this is an operational link, not a code-level coupling.

**VaultShareToken Roles**:

| Role               | Role Admin         | Purpose                                                                                                                                                               |
| ------------------ | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GUARDIAN_ROLE`    | `GUARDIAN_ROLE`    | Self-administered, manages all other roles; `rescueERC20Tokens`, `rescueERC721Tokens`, `setRecoveryAddress`                                                           |
| `ADMIN_ROLE`       | `GUARDIAN_ROLE`    | Pause                                                                                                                                                                 |
| `WHITELISTER_ROLE` | `GUARDIAN_ROLE`    | Grants/revokes `SHAREHOLDER_ROLE`                                                                                                                                     |
| `MINTER_ROLE`      | `GUARDIAN_ROLE`    | Can call `mint()` — granted to the vault in the constructor; revoked from the old vault on `setVault`                                                                 |
| `BURNER_ROLE`      | `GUARDIAN_ROLE`    | Can call `burn()` — granted to the vault in the constructor; revoked from the old vault on `setVault`                                                                 |
| `SHAREHOLDER_ROLE` | `WHITELISTER_ROLE` | Required to send/receive shares (enforced in `_update`). The vault is granted this role in the constructor so it can custody shares during async deposit/redeem flows |

Share transfers are restricted: both sender and recipient must have `SHAREHOLDER_ROLE`. For mints (`from == address(0)`), only the sender check is skipped — the recipient must still have `SHAREHOLDER_ROLE`. For burns (`to == address(0)`), only the recipient check is skipped — the sender must still have `SHAREHOLDER_ROLE`.

**Rotating the vault (`setVault`)**: the guardian-only `setVault(newVault)` updates the `vault(asset)` pointer and immediately revokes `MINTER_ROLE` and `BURNER_ROLE` from the outgoing vault, so an exploited old vault can no longer mint or burn shares. It does not grant those roles (or `SHAREHOLDER_ROLE`) to the new vault — the guardian must do that in a separate action before the new vault can operate.

**Token recovery**: `VaultShareToken` inherits `Rescuable`, so the guardian can rescue ERC20/ERC721 tokens accidentally sent to the contract via `rescueERC20Tokens` / `rescueERC721Tokens`. Rescued tokens are sent to a pre-set `recoveryAddress` (initialized in the constructor, changeable via the guardian-only `setRecoveryAddress`).

**Roles in ERC-7540 (reminder):**

- **_Controller:_** Owner of the request, it’s the only address authorized to call the final `deposit()` or `redeem()` function
- **_Operator_**: Entity able to call `requestRedeem()` on behalf of `investor`, designating a _Controller_ to manage the exit.
- **_Owner_**: The account that ultimately owns the underlying assets (e.g., USDC) or the vault shares.

### Vault’s Interface

The vault fully implements ERC-7540 and ERC-7575:

```solidity
interface IPortfolioVault is IERC7540Deposit, IERC7540Redeem, IERC7575 {
    // --- ERC-7540 Async Deposits ---
    function requestDeposit(uint256 assets, address controller, address owner)
        external returns (uint256 requestId);  // Always returns 0

    function pendingDepositRequest(uint256 requestId, address controller)
        external view returns (uint256 assets);  // requestId ignored (always 0)

    function claimableDepositRequest(uint256 requestId, address controller)
        external view returns (uint256 assets);  // requestId ignored; returns claimableDepositAssets

    // Claim approved deposit - mints shares to receiver
    function deposit(uint256 assets, address receiver, address controller)
        external returns (uint256 shares);

    function mint(uint256 shares, address receiver, address controller)
        external returns (uint256 assets);

    // --- ERC-7540 Async Redemptions ---
    function requestRedeem(uint256 shares, address controller, address owner)
        external returns (uint256 requestId);  // Always returns 0

    function pendingRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256 shares);  // requestId ignored (always 0)

    function claimableRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256 shares);  // requestId ignored; returns claimableRedeemShares

    // Claim approved redemption - burns shares, transfers assets
    function redeem(uint256 shares, address receiver, address controller)
        external returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address controller)
        external returns (uint256 shares);

    // --- Request Cancellation ---
    function cancelDepositRequest(address controller, address receiver) external returns (uint256 assets);
    function cancelRedeemRequest(address controller, address receiver) external returns (uint256 shares);

    // --- ERC-7540 Operators ---
    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address controller, address operator) external view returns (bool);

    // --- Investor Manager Operations ---
    function approveDeposit(address controller, uint256 assets) external returns (uint256 shares);
    function approveRedemption(address controller, uint256 shares) external returns (uint256 assets);

    // --- Portfolio Manager Operations ---
    function acceptSaleOffer(uint64 offerId) external;
    function createSaleOffer(address buyer, uint128 price, uint48 deadline, uint64[] calldata loanIds) external returns (uint64 offerId);
    function cancelSaleOffer(uint64 offerId) external;
    function transferLoans(uint64[] calldata loanIds, address recipient) external;
    function fundLoan(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external;
    function fundLoans(uint64[] calldata loanIds, int128[] calldata amounts, uint48 timestamp, bytes32 ref) external;
    function addLoansToNav(uint64[] calldata loanIds) external;
    function removeLoansFromNav(uint64[] calldata loanIds) external;

    // --- Shared (Portfolio Manager + Investor Manager) ---
    function updateNav(uint256 batchSize) external;
    function collectCashflows(uint64[] calldata loanIds, bytes32 ref) external returns (InvestorWithdrawalResult[] memory);

    // --- Admin Operations ---
    function pause() external;
    function registerAddress(Roles role, address addr) external;
    function unregisterAddress(Roles role, address addr) external;
    function setMaxNavAge(uint256 maxNavAge) external;
    function setMaxNavComputationTime(uint256 maxNavComputationTime) external;

    // --- Guardian Operations (timelocked) ---
    function unpause() external;
    function setLoans(address loans, address loansNFT) external; // also clears curated NAV list
    function setExchange(address exchange) external;             // exchange.LOANS / LOANS_NFT must match the vault's current pair
    function setCalculator(address calculator) external;
    function setRecoveryAddress(address recoveryAddress_) external;
    function rescueERC20Tokens(address token, uint256 amount) external;     // sends to recoveryAddress
    function rescueERC721Tokens(address token, uint256 tokenId) external;   // sends to recoveryAddress

    // --- Views ---
    function loans() external view returns (ILoans);
    function calculator() external view returns (INavCalculator);
    function nav() external view returns (uint256);
    function sharePrice() external view returns (uint256);
    function lastNavUpdate() external view returns (uint256);
}
```

### ERC-4626/7540 Methods Behavior

**Async claim methods (require prior approval):**

- `deposit(assets, receiver, controller)` — claims approved deposit, transfers pre-minted shares proportional to `assets * claimableShares / claimableAssets` from vault to receiver (requires claimable > 0)
- `mint(shares, receiver, controller)` — claims approved deposit by share amount, transfers pre-minted shares, deducts proportional assets (requires `claimableDepositShares >= shares`)
- `redeem(shares, receiver, controller)` — claims approved redemption, transfers assets to receiver (shares already burned at approval time)
- `withdraw(assets, receiver, controller)` — claims approved redemption by asset amount, transfers assets, deducts proportional share quota (requires `claimableRedeemAssets >= assets`)

**Methods that MUST revert:**

- `deposit(uint256, address)` — 2-param ERC-4626 variant, **MUST revert** (use 3-param async version)
- `mint(uint256, address)` — 2-param ERC-4626 variant, **MUST revert** (use 3-param async version)
- `previewDeposit`, `previewMint` — cannot know if/when deposit will be approved
- `previewWithdraw`, `previewRedeem` — cannot know if/when redemption will be approved

**Blocking during NAV computation:**

While `navStart != 0`, share-price-sensitive operations must revert:

- `approveDeposit`, `approveRedemption` — require valid share price
- `acceptSaleOffer`, `fundLoan`, `transferLoans`, `addLoansToNav`, `removeLoansFromNav` — would mutate the curated loan list mid-enumeration
- `collectCashflows` — would cause double-counting (cash increases while loan balances not yet fully enumerated)

Always available regardless of NAV state:

- `requestDeposit`, `requestRedeem` — submit new requests at any time
- `deposit`, `mint`, `redeem`, `withdraw` — claim already-approved requests (price was locked at approval time)
- `cancelDepositRequest`, `cancelRedeemRequest` — NAV-neutral (see blocking rules in NAV Calculation)

**Conversion views are informational, not a live oracle:**

`convertToShares` / `convertToAssets` (and `totalAssets` / `sharePrice`) price off the **last finalized NAV** (`lastNav`). They return `0` only before the vault is bootstrapped (`lastNav == 0`). Crucially, when the cached NAV has been invalidated (`lastNavUpdate == 0`, pending a fresh `updateNav`) these views still return values derived from the last finalized `lastNav` — they do **not** revert or return `0`. On-chain flows are protected because `approveDeposit` / `approveRedemption` enforce NAV freshness via `_requireFreshNav`, but external integrators reading `convertToShares` / `convertToAssets` must not treat the result as a live, up-to-the-block share price. Cross-check `lastNavUpdate` (and `navStart`) before relying on the returned value.

### Interoperability

Correct implementation of IERC165 is critical.

---

## Arithmetic Safety & Exploit Resistance

This section documents why the vault's share/asset conversion math is robust against common attack vectors, including deposit/mint and redeem/withdraw arbitrage, extreme amounts, split-claim grinding, and decimal mismatch exploits.

### Rounding Direction

All division in the vault rounds **down** (Solidity's default integer division). This consistently favors the vault (existing shareholders) over the depositor/redeemer:

| Operation                                                                 | Rounds | Consequence                                                                                                     |
| ------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------- |
| `approveDeposit`: `shares = assets * totalSupply / lastNav`               | Down   | Depositor receives fewer shares for their assets                                                                |
| `approveRedemption`: `assets = shares * lastNav / totalSupply`            | Down   | Redeemer receives fewer assets for their shares                                                                 |
| `deposit()` claim: `shares = assets * claimableShares / claimableAssets`  | Down   | Depositor mints fewer shares                                                                                    |
| `mint()` claim: `assets = shares * claimableAssets / claimableShares`     | Down   | Depositor consumes fewer assets for the exact shares requested (favors depositor; dust stays in claimable pool) |
| `redeem()` claim: `assets = shares * claimableAssets / claimableShares`   | Down   | Redeemer receives fewer assets                                                                                  |
| `withdraw()` claim: `shares = assets * claimableShares / claimableAssets` | Down   | Redeemer burns fewer shares for the exact assets requested (favors redeemer; dust stays in claimable pool)      |

Rounding down everywhere means no operation can create value out of thin air. The worst case is that rounding dust accumulates in the claimable pool — but dust is bounded and always favors the vault.

### deposit() vs mint() — No Arbitrage

Both `deposit()` and `mint()` draw from the same claimable pool (`claimableDepositAssets`, `claimableDepositShares`). They are algebraic inverses of each other:

- `deposit(assets)` → `shares = assets × claimableShares / claimableAssets`
- `mint(shares)` → `assets = shares × claimableAssets / claimableShares`

**Why no arbitrage is possible:**

1. **Full-claim equivalence**: Claiming all via `deposit(claimableAssets)` produces exactly `claimableShares`, and `mint(claimableShares)` consumes exactly `claimableAssets`. Both fully drain the pool with no difference.
2. **Split-claim grinding**: Splitting into many small `deposit(tiny)` calls rounds each chunk's shares DOWN. The sum of rounded-down parts ≤ the unrounded whole, so splitting cannot yield extra shares. The same applies to `mint()` — each small chunk rounds assets DOWN, consuming fewer assets per chunk. But the shares consumed from the pool are exact, so no extra shares are manufactured.
3. **Cross-function mixing**: Alternating `deposit()` and `mint()` on the same pool draws down both counters consistently. Each call independently satisfies `assets > 0 && shares > 0`, preventing zero-value claims. After consuming the pool, both counters reach 0 simultaneously (mathematically, full consumption in either dimension zeros both).

### redeem() vs withdraw() — No Arbitrage

Both `redeem()` and `withdraw()` draw from the same claimable pool (`claimableRedeemShares`, `claimableRedeemAssets`). They are algebraic inverses:

- `redeem(shares)` → `assets = shares × claimableAssets / claimableShares`
- `withdraw(assets)` → `shares = assets × claimableShares / claimableAssets`

The analysis is symmetric to deposit/mint above. Splitting redeems into many small chunks yields ≤ total assets (each chunk's assets rounds down). Splitting withdrawals burns ≤ total shares (each chunk's shares rounds down). No arbitrage between the two paths.

### Zero-Value Guard

Four critical guards prevent rounding exploits at the boundaries:

| Location            | Guard                                | Prevents                                                                                                                                                                                      |
| ------------------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `approveDeposit`    | `require(shares > 0)`                | Approving tiny assets that round to 0 shares, which would strand assets in the claimable pool with no shares to claim them                                                                    |
| `approveRedemption` | `require(assets > 0)`                | Approving tiny shares that round to 0 assets, which would lock shares in the claimable pool with nothing to withdraw                                                                          |
| `approveRedemption` | `require(assets <= idleLiquidity())` | Reserving more USDC than the vault holds, which would underflow the NAV finalization (`balance + adjustedNav − totalPendingDepositAssets − totalClaimableRedeemAssets`) and brick `updateNav` |
| `_claimDeposit`     | `require(assets > 0 && shares > 0)`  | `mint(tiny)` computing `assets = 0` (free shares) or `deposit(tiny)` computing `shares = 0` (assets consumed for nothing)                                                                     |
| `_claimRedeem`      | `require(assets > 0 && shares > 0)`  | `withdraw(tiny)` computing `shares = 0` (free USDC) or `redeem(tiny)` computing `assets = 0` (shares redeemed for nothing)                                                                    |

### Extreme Amounts

**Very large amounts** (e.g., 100 billion USDC): No overflow risk because Solidity 0.8+ has built-in overflow checks. The intermediate multiplication `assets * totalSupply` in `approveDeposit` produces values up to ~$10^{38}$ which fits in uint256 ($2^{256} \approx 10^{77}$).

**Very small amounts** (1 wei of USDC): `approveDeposit` computes `shares = 1 * totalSupply / lastNav`. With realistic NAV values, this rounds to 0 and reverts via the `require(shares > 0)` guard. Similarly, `approveRedemption(1 share)` succeeds only if `1 * lastNav / totalSupply > 0`, which depends on the share price.

### Multiple Partial Approvals

Each `approveDeposit` and `approveRedemption` **accumulates** into the claimable pool rather than overwriting. This is critical for correctness when partial approvals happen at different NAV snapshots:

- `claimableDepositShares[c] += shares` and `claimableDepositAssets[c] += assets`
- `claimableRedeemShares[c] += shares` and `claimableRedeemAssets[c] += assets`

At claim time, `deposit()` and `mint()` convert using the **ratio** `claimableShares / claimableAssets`, which is the weighted average of all approval prices. This is equivalent to maintaining a per-approval price history but much simpler:

$$\frac{\sum_i \text{shares}_i}{\sum_i \text{assets}_i} = \text{weighted average conversion rate}$$

**No exploit**: Interleaving partial approvals with partial claims works correctly because each claim reduces both counters proportionally. The ratio for remaining claims is preserved.

### Decimal Mismatch Robustness

The vault math is **asset-agnostic** — no conversion formula hardcodes a decimal count. All conversions are ratio-based (`assets * shares / counterpart`), so the arithmetic works identically regardless of the underlying asset's decimals. The current deployment uses USDC (6 decimals) with 18-decimal shares, creating a 10¹² ratio between the units. This is the hardest case for rounding: same-decimal pairings (e.g. 18/18) produce smaller ratios with less rounding loss, making them strictly easier. Any future asset swap requires no contract changes — only the share token's decimals and the asset's decimals matter, and the math handles them generically.

**1 share is worth ~416 USDC-wei at typical ratios.** With NAV = 500,000 USDC and totalSupply ≈ 1.2×10⁹ shares: `1 share = 500_000e6 / 1.2e9 ≈ 416`. Even a single share has non-zero asset value, so the `require(assets > 0)` guard in `approveRedemption` is not triggered at normal operating ratios.

**The guard would trigger only at extreme ratios**: Specifically, `totalSupply > lastNav × 10^{12}`, meaning each share is worth less than $10^{-12}$ USDC — an effectively impossible scenario.

**Round-trip conservation**: Depositing USDC → receiving shares → immediately redeeming shares never returns more USDC than deposited, regardless of decimal mismatch. This follows from rounding down in both directions.

### Conservation Invariant

The vault maintains a strict conservation property: after any combination of partial approvals and claims, the total value extracted equals the total value approved (minus rounding dust that is always ≤ 1 wei per operation).

Specifically, for a fully consumed claimable pool:

- `claimableDepositAssets[c]` reaches exactly 0 when `claimableDepositShares[c]` reaches 0 (and vice versa)
- `claimableRedeemAssets[c]` reaches exactly 0 when `claimableRedeemShares[c]` reaches 0 (and vice versa)
- `totalClaimableRedeemAssets` equals the sum of all individual `claimableRedeemAssets[c]` at all times

---

## Security Considerations (to be reviewed)

### Reentrancy

**Risk**: External calls during deposit/redeem/claim could allow reentrancy attacks.

**Mitigation**:

- Use solmate `ReentrancyGuard` on all state-changing external functions
- Follow checks-effects-interactions pattern
- Complete all state updates before external calls

### Access Control

**Risk**: Unauthorized access to admin functions or shareholder-restricted operations.

**Mitigation**:

- Four-tier structure: Guardian (TimelockController) for critical operations with timelock delay, Admin (multisig) for immediate operational/emergency actions, Portfolio Manager and Investor Manager for day-to-day
- The contract enforces an at-least-one-guardian invariant on-chain: `renounceRole` always reverts, and revoking the last remaining guardian reverts, so guardian-gated functions can never be permanently locked by dropping to zero guardians
- Critical operations (`rescueERC20Tokens`, `rescueERC721Tokens`, `unpause`, `setLoans`, `setExchange`, `setCalculator`, `setRecoveryAddress`) require `GUARDIAN_ROLE` — timelocked via TimelockController
- Granting/revoking `ADMIN_ROLE`, `PORTFOLIO_MANAGER`, `INVESTOR_MANAGER` is timelocked (guardian is role admin)
- Constructor grants only `GUARDIAN_ROLE` — admin must be explicitly granted post-deployment
- `pause` remains immediate via `ADMIN_ROLE` for fast emergency response
- `SHAREHOLDER_ROLE` required for deposits and redemption requests
- Share transfers restricted to `SHAREHOLDER_ROLE` holders only

### Share Price Manipulation

**Risk**: Attacker manipulates NAV to mint shares cheap or redeem at inflated price.

**Mitigation**:

- Single entity assumption: no adversarial shareholders to front-run
- Manager must update the NAV before approving deposits
- Managers must refresh the NAV before approving deposits/redemptions
- Redemption price locked at approval time by manager
- On-chain NAV from authoritative Loans.sol state (no external oracle)

### NAV Calculation Integrity

**Risk**: Stale or incorrect NAV leads to mispriced shares.

**Mitigation**:

- NAV calculated from Loans.sol on-chain state (single source of truth)
- Loan values adjusted by delinquency discount factors via the external calculator
- Deposits blocked during NAV update
- Managers must refresh the NAV before approving deposits/redemptions
- Emit events for NAV updates to enable off-chain monitoring

### Liquidity Risk

**Risk**: Redemption requests exceed available cash, shareholders cannot exit.

**Mitigation**:

- Manager can approve redemptions only when sufficient liquidity exists
- Manager can call `collectCashflows()` to pull USDC from loans before approving redemptions
- Emergency pause capability for extreme scenarios

### Loan NFT Validation

**Risk**: Arbitrary ERC-721 tokens sent to the vault via `safeTransferFrom` are accepted, polluting state.

**Mitigation**:

- `onERC721Received` reverts if `msg.sender != address(loansNFT)` — only loan NFTs from the configured Loans NFT contract are accepted
- `rescueERC721Tokens` (guardian-only, timelocked) as a fallback for tokens sent via low-level `transferFrom` (which bypasses `onERC721Received`) — sends to `recoveryAddress`

### Integer Overflow/Underflow

**Risk**: Arithmetic errors in share/asset calculations.

**Mitigation**:

- Use Solidity 0.8+ with built-in overflow checks
- Use `SafeCast` for int128 ↔ uint256 conversions
- Validate amounts are positive before operations

### Pause Restrictions

**Risk**: Exploit in progress requires immediate halt of operations.

**Mitigation**:

- Implement OpenZeppelin `Pausable` via `GuardianAccessControl`. Admin, guardian, or pauser can pause; only guardian can unpause.

**Functions blocked when paused** (`whenNotPaused`):

- `requestDeposit` — Initiating a new deposit request
- `requestRedeem` — Initiating a new redemption request
- `approveDeposit` — Approving pending deposits
- `approveRedemption` — Approving pending redemptions
- `deposit` / `mint` — Claiming approved deposits
- `redeem` / `withdraw` — Claiming approved redemptions
- `cancelDepositRequest` — Cancelling pending deposit
- `cancelRedeemRequest` — Cancelling pending redemption
- `collectCashflows` — Collecting loan cashflows into vault
- `updateNav` — Computing and updating NAV
- `acceptSaleOffer` — Accepting an exchange offer
- `createSaleOffer` — Creating an exchange offer
- `cancelSaleOffer` — Cancelling an exchange offer
- `transferLoans` — Transferring loan NFTs out
- `fundLoan` / `fundLoans` — Funding (single or batched) loans from vault liquidity
- `addLoansToNav` — Admitting a vault-owned loan into the NAV list
- `removeLoansFromNav` — Excluding a vault-owned loan from NAV
- `rescueERC20Tokens` — ERC20 recovery (inherited from `Rescuable`)
- `rescueERC721Tokens` — ERC721 recovery (inherited from `Rescuable`)
- `pause` — Pausing the contract (admin, guardian, or pauser; reverts if already paused)

**Functions NOT paused** (administrative, always operational):

- `setCalculator` — Updating NAV calculator address
- `setLoans` — Atomically updating Loans + LoansNFT pair
- `setExchange` — Updating exchange contract address
- `setMaxNavAge` — Configuring NAV staleness threshold
- `setMaxNavComputationTime` — Configuring NAV computation timeout
- `setOperator` — ERC-7540 operator management
- `registerAddress` / `unregisterAddress` — Address book management
- `setRecoveryAddress` — Setting rescue destination
- `setRoleAdmin` — Role hierarchy configuration
- `grantRole` / `revokeRole` — OZ AccessControl role management (`renounceRole` is disabled and always reverts)
- `onERC721Received` — ERC721 receiver callback

**Only callable when paused**:

- `unpause` — Unpausing the contract (guardian only)

**View functions reflecting the paused state**:

- `maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` — return `0` while paused, since the corresponding `deposit`/`mint`/`redeem`/`withdraw` claims are blocked by `whenNotPaused` (per ERC-4626/ERC-7575, a `max*` function must return `0` when its action is disabled).

### Front-Running

**Risk**: Informed actors exploit predictable state changes.

**Mitigation**:

- Single entity assumption: shareholders are the same entity, no incentive to front-run themselves
- NAV is on-chain and deterministic, no hidden information
- Manager controls redemption approvals, can sequence appropriately

### Constructor Validation

The vault constructor enforces:

- All address parameters must be non-zero (`ZeroAddress()`)
- `maxNavAge` and `maxNavComputationTime` must be greater than zero
- `loans.currency()` must equal `assetToken` (`AssetMismatch()`)
- `loansNFT.LOANS_CONTRACT()` must equal `loans` (`ReversePointerMismatch()`)
- Role admin hierarchy: `PORTFOLIO_MANAGER` and `INVESTOR_MANAGER` are both administered by `GUARDIAN_ROLE`
- Mints dead shares (see below)

### **Dead Shares**

The vault constructor mints `1e18` shares (1 full share) to `address(0xdead)` via `shareToken.mint()` to establish a permanent minimum supply that makes exchange rate manipulation economically unfeasible.

Since VaultShareToken restricts transfers to `SHAREHOLDER_ROLE` holders, the deployment script must temporarily whitelist `0xdead` before the vault is deployed:

1. Deploy VaultShareToken
2. Guardian grants `WHITELISTER_ROLE` to deployer
3. Deployer grants `SHAREHOLDER_ROLE` to `0xdead`
4. Deploy PortfolioVault (constructor mints dead shares to `0xdead`)
5. Deployer revokes `SHAREHOLDER_ROLE` from `0xdead`
6. Guardian revokes `WHITELISTER_ROLE` from deployer

After revocation, `0xdead` holds shares permanently but cannot receive more (no `SHAREHOLDER_ROLE`). Since nobody controls `0xdead`, the shares can never be transferred or redeemed. Zero runtime gas overhead — no code-level bypass needed in `_update`. Steps 3–6 are performed by the deploy script (`DeployVaultLibrary.deployVaultContracts`), and `verify-deployment` asserts that `0xdead` no longer holds `SHAREHOLDER_ROLE`.

#### Bootstrap NAV fixes the initial share price

While `totalSupply == DEAD_SHARES` (immediately after deployment, and again any time every real shareholder has fully redeemed), the first finalized NAV alone determines the conversion rate. From `approveDeposit`, `shares = assets × totalSupply / lastNav`, so:

- **Initial price** = `bootstrapNav / DEAD_SHARES` asset base units per share.
- **First real deposit** mints `shares = assets × DEAD_SHARES / bootstrapNav`.

This makes the seed amount a deliberate parameter, not an arbitrary donation:

- A **too-small** seed makes each share worth a sub-wei amount, so fractional share balances round to `0` on redemption (`convertToAssets` / `approveRedemption`).
- A **too-large** seed raises the minimum approvable deposit — `approveDeposit` reverts via `require(shares > 0)` for any amount below `⌈bootstrapNav / DEAD_SHARES⌉` asset base units.

With `DEAD_SHARES = 1e18`, 6-decimal USDC, and 18-decimal shares, seeding exactly `1e6` (1 USDC) yields the clean `1 USDC → 1 whole share` starting price (`1e18 / 1e6 = 1e12` shares per base unit). The deployment runbook mandates this seed; see [production_deployment_runbook.md §7.7](deployment/production_deployment_runbook.md#7-7-seed-vault).

---

## Decisions

1. **Share transfer restrictions**: Should shares be freely transferable between `SHAREHOLDER_ROLE` holders, or require explicit admin approval per transfer?

   **✅ Decision**: There is a canonical whitelist for transfers, deposit() and redeem() calls. Transfer revert if sent to an address that is not whitelisted. This whitelist is managed by the `INVESTOR_MANAGER`.

2. **Asynchronicity**: Is there a way the vault could be even partially synchronous? This seems only possible if the number of shareholders is always restricted to 1.

   **✅ Decision**: Fully async for both deposits and redemptions. This gives the manager full control over NAV freshness at approval time and provides a consistent UX.

3. Asynchronous flow may be wrapped into 1-step instead of 2 for the user if the Request becomes Claimable in the same block, using a Router contract.

   **✅ Decision**: Keep things simple for now. Can always add later

4. **Request cancellation**: What would a Request to deposit or redeem cancelled or denied by a manager would look like? EIP-7540 leave that completely up to the implementer.

   **✅ Decision**: Shareholders can cancel their own pending requests via `cancelDepositRequest()` and `cancelRedeemRequest()`. Cancelled deposits return assets to receiver; cancelled redemptions unlock shares to receiver.

5. **Epoch timing constraints**: Should there be a minimum time between epochs to prevent gaming? Maximum age for pending requests before forced settlement?

   **✅ Decision**: We don’t need epochs, shareholders won’t try to game themselves

6. **Multi-version Loans contract support**: Should a single vault hold loans from different Loans.sol deployments (different NFT collections)?
   - Adds complexity for NAV calculation and approval management, but provides flexibility for protocol upgrades.

   **✅ Decision**: ONLY ONE Loans contract registered in the vault

7. **Loan purchase mechanics**: Does Loans.sol need a dedicated `transferLoanInvestor()` function, or will standard ERC-721 transfer with `onERC721Received` hook suffice?

   **✅ Decision**: Loan purchases go through the LoansExchange contract for atomic USDC+NFT settlement. Loan sales support both paths: `LoansExchange` for priced sales (atomic swap) and bare ERC721 transfer for internal moves without payment. The vault becomes the investor by owning the loan NFT (investor = NFT owner in Loans.sol).

8. **EIP-7575**: Should we adopt a decoupled architecture (EIP-7575) where the ERC-20 share token is a standalone contract, or maintain a monolithic structure (EIP-4626) where the vault and share logic reside in a single contract? EIP-7540 states “Smart contracts implementing this Vault standard MUST implement the [ERC-7575](https://eips.ethereum.org/EIPS/eip-7575) standard (in particular the `share` method).”
   - Pro: Separation of concerns, allows the share token to be a "clean" ERC-20 with dedicated restriction logic as we need whitelisting management. No mixing of ERC-721 loan transfer function and ERC-20 transfer functions.
   - Pro: Enable future extension for multiple holdings (other stablecoins, shares from other vaults in addition to our vault) sharing one share token.
   - Con: Integrators might be confused expecting the share tokens and associated method to be at the same address as the vault

   **✅ Decision**: We decouple so that we follow the standard and have more flexibility for the future

9. **RequestIds**: Enough to rely on the `controller` address and set all Request IDs to 0?

   **✅ Decision**: All requestIds = 0

10. **Partial fulfillment**: Should `approveDeposit` and `approveRedemption` accept an amount parameter for partial fills?

    **✅ Decision**: Both `approveDeposit(controller, assets)` and `approveRedemption(controller, shares)` support partial approvals. Multiple partial approvals accumulate: claimable shares/assets are additive across calls, and `deposit()`/`mint()`/`redeem()` use the proportional ratio between the two for conversion. This naturally handles weighted-average pricing when partial approvals happen at different NAV values.

# Resources

Centrifuge Implementation

- https://github.com/centrifuge/protocol/blob/main/src/vaults/SyncDepositVault.sol
-

### EIPs

- https://eips.ethereum.org/EIPS/eip-4626
- https://eips.ethereum.org/EIPS/eip-7540
- https://eips.ethereum.org/EIPS/eip-7575
- https://eips.ethereum.org/EIPS/eip-1363
- Potentially needed: ERC1404
