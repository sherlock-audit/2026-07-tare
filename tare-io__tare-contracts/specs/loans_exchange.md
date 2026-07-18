# Loans Exchange

## Goal

The exchange provides the simplest possible onchain secondary-sale flow for loan NFTs: a seller and buyer negotiate a bundle and a price offchain, and the buyer later completes an atomic USDC-for-NFT settlement onchain.

"Investor" and "loan owner" are interchangeable in this document because the investor role is represented by `ownerOf(loanId)` on the loan NFT.

## Relationship with ERC721 Transfers

Bare ERC721 transfers remain valid when a loan NFT is unlocked. The exchange is an additive flow for priced sales, not a replacement for ordinary ownership transfers.

## Architecture

The exchange lives in a standalone `LoansExchange` contract. It holds immutable references to:

- `loansNFT` as a lockable loan NFT contract
- `loans` for address-book validation
- `currency`, read once from `loans.currency()` and used for settlement

The exchange does not escrow loan NFTs. Instead it uses ERC-5753-compatible locking:

- the seller keeps `ownerOf(loanId)` while an offer is active
- the exchange becomes the unlocker for each listed loan
- only the exchange can settle or unlock the listed loan while it is locked

This design depends on two protocol-level invariants outside the exchange:

- `LoansNFT` blocks ordinary transfers while locked, except for the unlocker
- `Loans.sol` allows `fund()` for the NFT owner or admin/guardian (lock has no effect on `fund()`)
- `Loans.sol` exposes a single `investorWithdraw()` function whose route depends on the lock state of the batch: for unlocked loans it is callable by investor/admin and sends funds to the investor; for locked loans it is callable only by the unlocker and sends funds to the unlocker.

Together these preserve the anti-front-running property that previously came from escrow: a seller cannot transfer a listed loan while the offer is live. While locked, the exchange can collect cashflows via `investorWithdraw()` (which auto-routes locked loans to the unlocker), and the seller calling `investorWithdraw()` reverts because the route requires the unlocker as caller.

The exchange inherits `GuardianAccessControl` (via `Rescuable`) for role-based access control and ERC20 recovery.

## Roles & Permissions

| Role            | Permissions                                                                                                                    |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `GUARDIAN_ROLE` | `forceCancelOffer`, `rescueERC20Tokens`, `rescueERC721Tokens`, `pause`, `unpause`, `setRecoveryAddress`, `setMaxLoansPerOffer` |
| `ADMIN_ROLE`    | `pause`, `setMaxLoansPerOffer`                                                                                                 |
| `PAUSER_ROLE`   | `pause` only — least-privilege incident-response role                                                                          |
| NFT Owner       | `createOffer`, `cancelOffer` (must own the listed loans)                                                                       |
| Buyer           | `acceptOffer` (must be the designated buyer)                                                                                   |

**Role Admin Hierarchy**:

| Role            | Role Admin                          |
| --------------- | ----------------------------------- |
| `GUARDIAN_ROLE` | `GUARDIAN_ROLE` (self-administered) |
| `ADMIN_ROLE`    | `GUARDIAN_ROLE`                     |
| `PAUSER_ROLE`   | `GUARDIAN_ROLE`                     |

## Bundle Size Limit

The contract enforces `maxLoansPerOffer` (default `100`) to keep bundle settlement and cancellation within practical gas limits. Admin can update the limit for future offers via `setMaxLoansPerOffer(uint64 newMax)`, and `newMax` must be greater than `0`.

## Locking Model

When a seller creates an offer, each loan NFT is locked to the exchange instead of transferred away from the seller.

This gives the protocol the same practical sale guarantees as escrow without changing ownership up front:

- seller retains wallet-level ownership and enumeration
- exchange becomes the only address that can transfer the listed loan while locked
- `Loans.sol` freezes non-admin investor-owner actions while listed

While a loan is locked, the loan NFT resolves approval to the unlocker so the exchange can settle through the standard ERC721 authorization path.

## Offer Tracking

Offers are stored in `mapping(uint64 offerId => SaleOffer offer) internal _offers`, with offer IDs starting at `1`.

Duplicate listing of the same loan (or overlapping bundles) is prevented by the NFT lock itself: `createOffer` requires each listed loan to be unlocked and then locks it to the exchange, so a loan that is already part of an active offer fails the unlocked check.

Expired offers remain active until cancelled or force-cancelled.

## Flow

### Step 0: Seller and buyer agree offchain

- Seller and buyer agree on a bundle and price.
- Buyer provides the EVM address that will become the new investor.
- Seller registers that buyer address in the seller's address book for `Roles.Investor`.

### Step 1: Seller creates an offer via `createOffer`

Preconditions:

- seller has approved the exchange to operate each listed loan NFT, either per-token or via `setApprovalForAll`
- buyer is registered in the seller's address book for the Investor role

Parameters:

- `uint64[] loanIds`
- `uint128 price`
- `address buyer`
- `uint48 deadline`

Validation:

- `loanIds.length` is non-zero and does not exceed `maxLoansPerOffer`
- `buyer` is not `msg.sender` and not `address(0)`
- `deadline > block.timestamp`
- buyer is registered for `Roles.Investor` in the seller's address book
- every listed `loanId` is currently owned by `msg.sender`
- every listed `loanId` is currently unlocked (this also rejects loans that are already part of another active offer, since `createOffer` locks the NFT)

Execution:

1. increment `offerCount` to get a new `offerId`
2. for each listed loan, call `loansNFT.lock(address(this), loanId)`
3. store the `SaleOffer`
4. emit `OfferCreated`

The exchange does not take custody of the NFTs. Ownership stays with the seller until the buyer settles.

### Step 2: Buyer accepts via `acceptOffer`

Permissioning:

- only `offer.buyer` may accept

Precondition:

- buyer has approved the exchange to pull `currency` if `price > 0`

Validation:

- the caller is the offer's buyer (reverts `NotOfferRecipient` otherwise; this also rejects inactive offers, whose `buyer` is `address(0)`)
- `block.timestamp <= offer.deadline`
- the buyer (`msg.sender`) is still registered as an `Investor` in the seller's address book (reverts `BuyerNotRegistered` otherwise) — re-checked at accept time because the seller may have unregistered the buyer between `createOffer` and `acceptOffer`
- the seller is registered as an `Investor` in the buyer's address book (reverts `SellerNotRegistered` otherwise) — ensures the buyer has independently whitelisted the seller before settlement

Execution:

1. delete the offer first
2. for each listed loan, transfer the NFT from seller to buyer via plain `transferFrom`, using the exchange's unlocker authority; the lock is cleared automatically as part of the transfer
3. if `price > 0`, transfer `currency` from buyer to seller
4. emit `OfferAccepted`

NFTs move before currency so that no external observer can witness an intermediate state in which the seller holds both the loans and the proceeds. Plain `transferFrom` is used in every case: no `onERC721Received` callback is ever invoked on the buyer, which removes an arbitrary-code-execution surface during settlement (notably preventing cross-contract reentrancy into NAV-reading paths). Buyers that are contracts must therefore be able to receive ERC-721 via plain `transferFrom` (an EOA, a Safe, or a contract that does not require the receiver hook); contracts that strictly need the receiver hook can be rescued via `LoansNFT.forceTransfer` after settlement clears the exchange lock.

No loan-status restriction is imposed beyond existence. This remains consistent with bare ERC721 transfers when a loan is unlocked.

### Cancelling via `cancelOffer`

Permissioning:

- only `offer.seller` may cancel

Execution:

1. delete the offer
2. unlock each listed loan in place
3. emit `OfferCancelled`

Because ownership never left the seller, cancellation does not transfer NFTs back. It only clears the lock and offer state.

### Guardian Recovery via `forceCancelOffer`

`forceCancelOffer(uint64 offerId)` is a guardian-only escape hatch for stuck offers, such as abandoned listings or seller key loss.

It:

- clears offer storage
- unlocks every listed loan (while an offer is active, each listed loan is always locked with the exchange as unlocker)
- emits `OfferForceCancelled`

This is the intended recovery path for listed loan NFTs that are locked to the exchange.

## Accounting Ledger Updates

Loan sales do not create ledger entries. A sale changes who is entitled to future distributions, not the loan's economic state.

## Pricing

The exchange does not enforce a pricing formula. It only guarantees atomic settlement between the agreed seller and buyer. A fair bundle price is nevertheless expected to reflect the loan's full investor position, which decomposes into four components:

| Component                    | What it is                                                                    | Fair-value treatment                                                      |
| ---------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Expected investor interest   | Interest accrued through the settlement date but not yet paid by the borrower | Owed to the seller; compensated in the price (see entitlement rule below) |
| Expected investor principal  | Outstanding investor principal still out with the borrower                    | Discountable by the buyer to reflect credit risk                          |
| Collected investor interest  | Waterfall-allocated interest held by the loan, awaiting `investorWithdraw()`  | Cash, no credit risk — priced at par                                      |
| Collected investor principal | Repaid investor principal held by the loan, awaiting `investorWithdraw()`     | Cash, no credit risk — priced at par                                      |

This mirrors the valuation split used by the `NavCalculator` (see [nav-calculator.md](nav-calculator.md)): collected investor cash at par, unreturned investor principal subject to a credit discount.

### Interest entitlement rule

The seller is entitled to all investor interest accrued up to the day the trade settles, regardless of when the borrower's payment actually lands. A loan is usually sold between two payment dates, so part of that seller-owed interest is only received — as ordinary loan cashflow — after the loan has already been transferred to the buyer. The price must compensate the seller for it.

Example: after settlement the buyer withdraws $2,000 of interest cashflow, of which $500 accrued before the settlement date. A fair price is increased by that $500, so accrued interest is fairly distributed between seller and buyer no matter when the borrower's payment arrives.

The entitlement is absolute; its valuation is negotiable. Compensating accrued-but-unpaid interest at par is the convention for performing loans, but that interest is still a receivable — the borrower's next payment may never arrive — so for delinquent loans the buyer may discount this component for collection risk, just like principal.

### Why the price is the only compensation mechanism

While a loan is listed, `investorWithdraw()` is callable only by the unlocker, and the current exchange exposes no function that forwards collected cashflows to the seller (the unlocker-withdraw routing exists so that a potential future version of the LoansExchange can collect cashflows during listing). All investor cash that is unwithdrawn at listing time or arrives while the offer is live therefore lands with the buyer after settlement. Sellers should either withdraw available investor cash before listing or price it into the offer at par, and always price in the interest expected to accrue up to settlement.

### Timing

The price is fixed when the offer is created, but the seller's interest entitlement runs through the settlement date. Offer deadlines should therefore stay short — under one day, since interest accrues on a daily cadence (the LMS enforces a 6-hour maximum offer expiry).

When the seller is a Portfolio Vault, share-price-sensitive operations must additionally be suspended while the offer is live — see the pending-offer approval hazard in [vault.md](vault.md).

## Risks

- Wrong price is specified.
- Wrong buyer address is specified.
- Expired offers remain live until cancelled or force-cancelled.
- Investor cash collected by a listed loan while the offer is live cannot be withdrawn by the seller and accrues to the buyer at settlement; the seller is only made whole if the price accounted for it.
- A seller can create an offer with duplicate `loanIds`, but the transaction reverts because the second occurrence is already locked within the same call.

## Decisions

| Decision                      | Choice                                                                                                                | Rationale                                                                                                                                                                        |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bare ERC721 transfers         | Remain unrestricted when unlocked                                                                                     | Exchange is additive, not mandatory                                                                                                                                              |
| Offer model                   | Single designated buyer                                                                                               | Simplest atomic sale flow                                                                                                                                                        |
| NFT custody during listing    | No escrow                                                                                                             | Seller keeps ownership; lock supplies settlement control                                                                                                                         |
| Anti-front-running protection | Lock + auto-routing withdraw                                                                                          | Lock blocks transfers; `investorWithdraw()` on a locked batch requires the unlocker as caller and sends funds to the unlocker                                                    |
| Mutual whitelisting at accept | Buyer must be in seller's address book AND seller must be in buyer's address book, both checked at `acceptOffer` time | Settlement only proceeds if both counterparties currently whitelist each other; protects each side against a stale or unilateral whitelist from the offer-creation moment        |
| Settlement ordering           | NFTs first, currency last via plain `transferFrom`                                                                    | Removes the `onERC721Received` callback surface during settlement and prevents external NAV observers from witnessing a state where the seller holds both the loans and the cash |
| Offers per loan               | One at a time                                                                                                         | Reverse index prevents duplicate or overlapping listings                                                                                                                         |
| Price model                   | Single lump sum per bundle                                                                                            | Per-loan breakdown remains offchain                                                                                                                                              |
| Price of `0`                  | Allowed                                                                                                               | Supports internal moves or offchain consideration                                                                                                                                |
| Cancellation                  | Supported by seller                                                                                                   | Seller must be able to rescind                                                                                                                                                   |
| Guardian recovery             | `forceCancelOffer`                                                                                                    | Non-permanent recovery path for stale or stuck offers                                                                                                                            |
| Bundle size limit             | `100`, admin-modifiable                                                                                               | Keeps settlement and cancellation within gas limits                                                                                                                              |

## Pause Restrictions

The exchange inherits OZ `Pausable` via `GuardianAccessControl`. When paused, all offer operations revert with `EnforcedPause()`. Admin, guardian, or pauser can pause; only guardian can unpause.

**Functions blocked when paused** (`whenNotPaused`):

- `createOffer` — Creating new sale offers
- `acceptOffer` — Atomic settlement (NFTs via `transferFrom`, then currency)
- `cancelOffer` — Seller cancelling their offer
- `rescueERC20Tokens` — ERC20 recovery (inherited from `Rescuable`)
- `rescueERC721Tokens` — ERC721 recovery (inherited from `Rescuable`)
- `pause` — Pausing the contract (admin, guardian, or pauser; reverts if already paused)

**Functions NOT paused** (administrative, always operational):

- `forceCancelOffer` — Guardian emergency cancellation (must remain available while paused so stuck offers can be unwound)
- `setMaxLoansPerOffer` — Configuration change
- `setRecoveryAddress` — Setting rescue destination
- `setRoleAdmin` — Role hierarchy configuration
- `grantRole` / `revokeRole` — OZ AccessControl role management (`renounceRole` is disabled and always reverts)

**Only callable when paused**:

- `unpause` — Unpausing the contract (guardian only)

## Events and Errors

Events:

- `OfferCreated(uint64 indexed offerId, address indexed seller, address indexed buyer, uint128 price, uint48 deadline, uint64[] loanIds)`
- `OfferAccepted(uint64 indexed offerId, address indexed seller, address indexed buyer, uint128 price)`
- `OfferCancelled(uint64 indexed offerId)`
- `OfferForceCancelled(uint64 indexed offerId, address indexed seller)`
- `MaxLoansPerOfferUpdated(uint64 newMax)`

Errors:

- `OfferExpired()`
- `OfferInactive()`
- `NotOfferRecipient()`
- `NotSeller()`
- `NotLoanOwner()`
- `LoanLocked()`
- `InvalidBuyer()`
- `BuyerNotRegistered()`
- `SellerNotRegistered()`
- `InvalidLoanIdsLength()`
- `InvalidDeadline()`
- `InvalidMaxLoansPerOffer()`
- `ZeroAddress()`
