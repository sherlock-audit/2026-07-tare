# Security: Known Issues, Trust Assumptions, and Design Tradeoffs

This document enumerates the **known vulnerabilities, trust assumptions, and design tradeoffs** of the Tare smart contract suite.

- **Commit baseline:** `fb12133`

---

### 1 — Operator-set `setApprovalForAll` enables lock-and-drain on loan NFTs

**Where:** [`LoansNFT.lock`](contracts/LoansNFT.sol), [`Loans.investorWithdrawByUnlocker`](contracts/Loans.sol)

`LoansNFT.lock(tokenId, unlocker)` uses OpenZeppelin's `_isAuthorized`, which accepts any operator approved by the NFT owner via `setApprovalForAll`. An approved operator can lock the NFT to an attacker-controlled `unlocker`, then call `investorWithdrawByUnlocker` to receive all accrued interest and principal repayments. Existing operator approvals are not cleared on lock.

**Impact:** Loss equals all currently-accrued + future interest/principal payments on the loan until the lock is removed (which the unlocker alone controls).

### 2 — `Rescuable.rescueERC20Tokens` can drain the operational currency, breaking core accounting invariants

**Where:** [`Rescuable.rescueERC20Tokens`](contracts/misc/Rescuable.sol), inherited by [`Loans`](contracts/Loans.sol) and [`PortfolioVault`](contracts/PortfolioVault.sol)

`Rescuable` has no token allowlist or exclusion of the contract's configured `currency` / `assetToken`. Guardian can move the operational currency out of either contract, with no on-chain reconciliation to internal accounting.

- **On `Loans`**: every loan's cash bucket (`ACC_CASH`) is custodied in the same contract. The invariant `currency.balanceOf(loans) >= Σ ACC_CASH[loanId]` underpins per-loan cash segregation. Rescuing `currency` silently violates this invariant: subsequent withdrawals either revert (insufficient balance) or — worse — succeed by drawing against another loan's cash, cross-contaminating loan segregation.
- **On `PortfolioVault`**: `updateNav` finalization computes `lastNav = assetToken.balanceOf(this) − totalPendingDepositAssets − totalClaimableRedeemAssets + adjustedNav`. Rescuing `assetToken` lowers the balance without touching the counters; the next finalize underflow-reverts and bricks NAV until the rescued amount is returned.

**Impact:** Guardian compromise (or honest mistake) of `rescueERC20Tokens` on `Loans` permits arbitrary loss of loan custody funds. On the vault, NAV becomes unupdatable until reconciled off-chain.

### 3 — Off-chain interest/fee math consumed without on-chain re-derivation

**Where:** [`Loans.accrue`](contracts/Loans.sol), [`Loans.applyWaterfall`](contracts/Loans.sol)

Interest and fee allocations are computed off-chain by the servicer and accepted at face value subject to ledger validations. Rounding, day-count conventions, and calendar drift are not enforced on-chain.

### 4 — Originator is trusted to register only non-malicious counterparties

**Where:** [`Loans.create`](contracts/Loans.sol), [`LoansAuth.registerAddress`](contracts/misc/LoansAuth.sol)

`create` validates only that the originator is approved on the canonical book; the `borrower`, `investor`, and `servicer` addresses are drawn from the originator's own self-managed book (14). A compromised or malicious originator can name any address in any role. The protocol relies on each originator to curate its book with addresses representing real, consenting counterparties. Admin/guardian can audit and correct via `*OnBehalfOf` (see 14).

### 5 — Servicer has broad discretion over ledger state, loan data, and waterfall allocation

**Where:** [`Loans.chargeMiscFee`](contracts/Loans.sol), [`Loans.createLedgerEntries`](contracts/Loans.sol), [`Loans.applyWaterfall`](contracts/Loans.sol), [`Loans.servicerWithdraw`](contracts/Loans.sol), [`Loans.updateBorrower`](contracts/Loans.sol), [`Loans.updateLoanData`](contracts/Loans.sol), [`Loans.refundBorrower`](contracts/Loans.sol)

The servicer is a **trusted role** (T-4) — the protocol relies on the servicer to manipulate the ledger, manage per-loan participants, and apply the payment waterfall correctly. The on-chain checks are structural (entry endpoints, sign-flow, payment-clearing caps, address-book registration) — they do not validate intent. A rogue or compromised servicer can convert this discretion into real cash extraction or operational disruption up to the loans it services. This finding enumerates the surface; the mitigation is operational (servicer key hygiene, monitoring) plus guardian-side recovery (`updateServicer`, `*OnBehalfOf` address-book rewrites).

Concrete extraction / disruption paths:

- **`chargeMiscFee` is unbounded.** It credits `ACC_SERVICER_MISC_FEE_PAYABLE` (servicer's pocket) and debits `ACC_BORROWER_MISC_FEE_RECEIVABLE` for any caller-supplied amount, with no cap and no upstream-receivable requirement.
- **Siphoning a fresh borrower payment.** After `receiveBorrowerPayment(1000)` the 1000 sits in `ACC_BORROWER_PAYMENT_CLEARING`. A servicer can call `chargeMiscFee(1000)` then `applyWaterfall(miscFees=1000, …)` — the waterfall's misc-fee cap (`miscFees ≤ ACC_BORROWER_MISC_FEE_RECEIVABLE + ACC_BORROWER_MISC_FEE_PAID`) was just inflated by `chargeMiscFee`, so it passes — followed by `servicerWithdraw` to take the 1000 from `ACC_CASH`. The borrower's interest/principal never get allocated.
- **`createLedgerEntries` reallocations.** Same shape via the freeform entries primitive (`from != ACC_CASH && to != ACC_CASH && amount > 0`) — e.g. moving balances into `ACC_SERVICER_FEE_PAYABLE` then withdrawing.
- **`updateBorrower` redirection.** Servicer can rotate `borrowers[loanId]` to any address registered in its own self-curated book (14) and then call `refundBorrower` to send unobligated cash to that address. The rotation also redirects future `receiveBorrowerPayment` pulls that rely on a standing `currency` allowance from the original borrower (21 shape).
- **`updateLoanData` status / date manipulation.** Servicer can set `status` to any value (including `FullyPaid`, `Cancelled`, `ChargedOff`, `Closed`) and rewind/skew `nextDueDate` / `maturityDate`. This can DoS legitimate operations gated by `notCancelledOrClosed` (e.g. `applyWaterfall`, `updateBorrower`), or falsely signal terminal lifecycle states to off-chain consumers — without moving cash directly, but enabling out-of-band damage.

When the servicer inflates fees beyond the loan's legitimate obligations, the per-loan cash check at [`LoansLedger.sol:127`](contracts/LoansLedger.sol#L127) means `servicerWithdraw`, `investorWithdraw`, and `originatorWithdraw` are competing for the same `ACC_CASH` pool — whoever transacts first wins. In the honest flow this race is invisible because cash equals the sum of legitimate payables; under fee inflation it is a real first-come-first-served drain.

Extraction and disruption are bounded per-loan (segregation holds — the servicer cannot reach another loan's cash or mutate another servicer's loans), but the servicer can apply this on every loan it services. T-4 captures the trust assumption; this finding catalogues the concrete surface.

### 6 — Caller-supplied `timestamp` is written to ledger state (by design)

**Where:** [`Loans.accrue`](contracts/Loans.sol), [`applyWaterfall`](contracts/Loans.sol), [`*Withdraw`](contracts/Loans.sol), [`updateLoanData`](contracts/Loans.sol)

Many state-changing functions accept a `timestamp` parameter and write it to `data[loanId].updatedAt` and entry `timestamp`. **This is by design** — these functions record events whose true moment of occurrence can happen off-chain (a wire arriving, an accrual day closing), so the caller-supplied timestamp reflects the real event time rather than block time. The integrity tradeoff is that the on-chain "last updated" signal can be rewound or skewed by the servicer; monitoring should rely on block timestamps and event ordering for tamper-evidence, not on `updatedAt`.

### 7 — Zero-NAV bootstrap deadlocks the first deposit cycle

**Where:** [`PortfolioVault.approveDeposit`](contracts/PortfolioVault.sol), [`PortfolioVault.updateNav`](contracts/PortfolioVault.sol)

The vault's first NAV cycle, run before any loans exist and before any seed donation, leaves `lastNav = balanceOf(this) − totalPendingDepositAssets − totalClaimableRedeemAssets = 0` (pending deposits sitting in the contract are subtracted out). The subsequent `approveDeposit` (and `approveRedemption`) revert in `_requireFreshNav()` with `ZeroNav()`, blocking the vault from ever onboarding its first depositor.

**Recovery:** seed the vault with a small donation of `assetToken` before the first `updateNav` finalizes (or before the first approval). Codify either a deployment-time seed step or a bootstrap branch in `approveDeposit`.

### 8 — `sharePrice` denominator includes `DEAD_SHARES`

**Where:** [`PortfolioVault.sharePrice`](contracts/PortfolioVault.sol)

`sharePrice = totalAssets() / totalSupply()` where `totalSupply` includes the `DEAD_SHARES` minted at deployment. In the early state, the dead-share denominator is non-trivial relative to real share supply, so quoted `sharePrice` is biased **downward**. The bias decays as real shares grow. ERC-7540 `convertToShares` / `convertToAssets` use the same denominator and are subject to the same skew. Consumers reading `sharePrice` for very-early deposit quotes should not interpret it as `totalAssets / userClaim`.

### 9 — `applyPortfolioAdjustment` × `portfolioFactor` can amplify NAV

**Where:** [`NavCalculator.applyPortfolioAdjustment`](contracts/NavCalculator.sol)

`portfolioFactor` is capped by `maxPortfolioFactor` (default `2e18`, i.e. 2×). The cap itself has no upper bound in code; guardian can raise it arbitrarily.

### 10 — ERC-7540 claim price is set at approval, not request (no time-weighted blending)

**Where:** [`PortfolioVault.requestDeposit` / `requestRedeem` / `approveDeposit` / `approveRedemption`](contracts/PortfolioVault.sol)

All pending assets at approval time convert at the single NAV captured by that approval call — there is **no time-weighted average** across the request window. A user who re-requests, or whose request lingers across multiple NAV updates, is exposed to whichever NAV the manager next pins. Claimants are responsible for tracking pending requests off-chain.

### 11 — Asymmetric `addTrustedCall` / `removeTrustedCall` access

**Where:** [`TrustedCalls.addTrustedCall` / `removeTrustedCall`](contracts/TrustedCalls.sol)

`addTrustedCall` requires `GUARDIAN_ROLE`; `removeTrustedCall` requires `ADMIN_ROLE` or `GUARDIAN_ROLE`. Admin can DoS a trusted call they cannot re-enable; only guardian (timelock) can restore it.

### 12 — TrustedSpender per-recipient allowances default to `type(uint208).max`

**Where:** [`SmartAccountFactory.configureSmartAccount`](contracts/SmartAccountFactory.sol), [`TrustedSpender.setAllowance`](contracts/TrustedSpender.sol)

Onboarding sets uninhibited allowances per `(safe, recipient, currency)`. No per-transaction cap on routine spend.

### 13 — Onboarding issues unlimited ERC-20 approvals to TrustedSpender

**Where:** [`SmartAccountFactory.configureSmartAccount`](contracts/SmartAccountFactory.sol)

Each onboarded Safe approves TrustedSpender for every configured currency at `type(uint256).max` and these approvals are never decremented. Combined with 12 (no per-tx cap), the cumulative blast radius of a TrustedSpender bug or compromise is unlimited across the union of all onboarded Safes and their currencies.

### 14 — `LoansAuth` address books are permissionless per caller, with admin override

**Where:** [`LoansAuth.registerAddress`](contracts/misc/LoansAuth.sol), [`LoansAuth.registerAddressOnBehalfOf`](contracts/misc/LoansAuth.sol)

`registerAddress` / `unregisterAddress` are permissionless: each address self-curates its own book. In addition, `registerAddressOnBehalfOf` / `unregisterAddressOnBehalfOf` are `onlyAdminOrGuardian` — admin/guardian can write to **any** operator's book directly (except the canonical book owned by the contract itself). Underlies 4 and gives admin a one-step recovery path when an operator's book becomes adversarial.

### 15 — Asymmetric `addDelegate` / `removeDelegate` on Safe modules

**Where:** [`TrustedCalls.addDelegate` / `removeDelegate`](contracts/TrustedCalls.sol), [`TrustedSpender.addDelegate` / `removeDelegate`](contracts/TrustedSpender.sol)

`addDelegate` requires `safeOrGuardian`; `removeDelegate` requires `safeOrAdmin`. Admin (Safe multisig) can strip delegates from any onboarded Safe at will; only guardian can re-add. Same DoS shape as 11, applied per-Safe.

### 16 — `setDiscountFactor` / `setPortfolioFactor` are not idle-NAV gated

**Where:** [`NavCalculator.setDiscountFactor` / `setPortfolioFactor`](contracts/NavCalculator.sol)

The calculating agent can change factors between `updateNav` batches. Earlier batches use old factors, later batches use new factors, finalize applies the latest `portfolioFactor` to the mixed sum.

### 17 — `VaultShareToken._update` requires both sides hold `SHAREHOLDER_ROLE`

**Where:** [`VaultShareToken._update`](contracts/VaultShareToken.sol)

The vault contract itself must hold `SHAREHOLDER_ROLE` for every deposit / redemption flow to function (`DEAD_ADDRESS` needs it only during the constructor's dead-shares mint and has it revoked post-deploy); `setVault` does not assert this wiring. If `SHAREHOLDER_ROLE` is revoked from a regular holder, their shares become non-transferable until the role is granted again — recovery is possible but requires guardian action.

### 18 — Originator's `disburse` privilege survives revocation between create and disburse

**Where:** Per-loan role mappings in [`Loans.sol`](contracts/Loans.sol), [`LoansAuth.revokeOriginator`](contracts/misc/LoansAuth.sol)

`originators[loanId]` is fixed at `create` time and the originator's only post-origination on-chain action is `disburse`. Revoking originator approval does **not** strip them from existing un-disbursed loans, so a freshly-revoked originator can still disburse pre-existing loans. Servicers are not affected because [`Loans.updateServicer`](contracts/Loans.sol) lets guardian re-point `servicers[loanId]` on a per-loan basis.

### 19 — No protocol-wide pause

**Where:** `pause()` on each of [`Loans`](contracts/Loans.sol), [`PortfolioVault`](contracts/PortfolioVault.sol), [`LoansExchange`](contracts/LoansExchange.sol), [`LoansNFT`](contracts/LoansNFT.sol), [`TrustedCalls`](contracts/TrustedCalls.sol), [`TrustedSpender`](contracts/TrustedSpender.sol), [`VaultShareToken`](contracts/VaultShareToken.sol)

Each contract is paused independently. A coordinated halt requires multiple transactions; partial pause can leave inconsistent states reachable.

### 20 — Loan NFTs can land at any address regardless of ERC-721 awareness

**Where:** [`Loans.create`](contracts/Loans.sol), [`LoansExchange._acceptOffer`](contracts/LoansExchange.sol), [`PortfolioVault._transferLoans`](contracts/PortfolioVault.sol)

The protocol uses the **non-safe** variants of ERC-721 mint / transfer on the loan NFT in several places, for example `Loans.create` uses `_mint`, `LoansExchange._acceptOffer` uses `transferFrom`, and `PortfolioVault._transferLoans` exposes a non-safe `transferFrom` branch (`transferLoansUnsafe`). None of these invoke `onERC721Received` on the recipient, so a loan NFT can be delivered to a contract that does not implement the receiver hook (and would normally reject `safeTransferFrom`). Combined with 14, an approved originator can also spam NFTs to arbitrary addresses at create time. Recipients are responsible for ensuring they can manage and transfer the NFT they hold. No funds move at mint time — `fund()` still requires the investor's signed allowance.

This is a deliberate choice: skipping the receiver callback eliminates the re-entrancy surface that `safeTransferFrom` would otherwise hand to an arbitrary recipient contract during mint / exchange settlement / vault evacuation, and prevents a malicious recipient from griefing those flows by reverting from the callback.

### 21 — Admin can pull from standing user `currency` allowances on behalf of any role

**Where:** [`Loans.fund`](contracts/Loans.sol), [`Loans.receiveBorrowerPayment`](contracts/Loans.sol), [`Loans._requireCallerOrAdmin`](contracts/Loans.sol)

Several entry points are gated by `_requireCallerOrAdmin(roleAddress)` and then call `safeTransferFrom(roleAddress, address(this), …)`:

- `fund` pulls from `loansNFT.ownerOf(loanId)` (the investor).
- `receiveBorrowerPayment` pulls from `borrowers[loanId]`.

A compromised admin can therefore drain any standing `currency` allowance granted to `Loans` by an investor or borrower, without that user's signature. Bounds:

- Amount is constrained: `fund` requires `amount == commitment` (the loan's principal); `receiveBorrowerPayment` only credits the loan's clearing account.
- Tokens land in the loan's `ACC_CASH` and must be moved out through the usual exits (`disburse` to the borrower, `investorWithdraw` / `originatorWithdraw` / `servicerWithdraw` against payables, `refundBorrower`).
- However, admin already controls originator approval (T-2) and `*OnBehalfOf` address-book writes (14). The end-to-end path is: approve an attacker-controlled originator → register attacker-borrower and the victim investor in that originator's book → `create` a loan sized to the victim's outstanding allowance → `fund` (pulls allowance) → `disburse` (sends to attacker-borrower).

Mitigation is operational: users should not leave standing allowances to `Loans` beyond what is about to be consumed, and the admin Safe must be treated as a privileged actor (T-1).

### 22 — `LoansNFT.setBaseURI` is ADMIN-only with no timelock

**Where:** [`LoansNFT.setBaseURI`](contracts/LoansNFT.sol)

Metadata can be rewritten by admin instantly (no guardian gate).

### 23 — `LoansNFT.getApproved` returns the unlocker for locked tokens

**Where:** [`LoansNFT.getApproved`](contracts/LoansNFT.sol)

Non-standard ERC-721 surface. Marketplaces and indexers expecting per-token approval semantics may misinterpret a locked token's "approved" address as a buy-side approval.

### 24 — `LoansNFT._update` clears the unlocker on every transfer

**Where:** [`LoansNFT._update`](contracts/LoansNFT.sol)

Intentional. Edge case for unlocker integrations that expected persistence across transfers.

### 25 — `PortfolioVault.acceptSaleOffer` leaves residual `forceApprove` after partial fill

**Where:** [`PortfolioVault.acceptSaleOffer`](contracts/PortfolioVault.sol)

`acceptSaleOffer` calls `forceApprove(exchange, price)` to authorise the buy. If the exchange does not consume the full approval (e.g. partial fill or a future exchange-side bug), the residual non-zero approval to the exchange persists until the next `acceptSaleOffer` overwrites it. Exposure is limited to the configured `LoansExchange` address and to the amount of currency the vault holds at any given time, but during the residual window any vulnerability in `LoansExchange` could drain up to the residual approval.

### 26 — Several state-changing functions remain callable on Cancelled / Closed loans

**Where:** [`Loans.refundBorrower`](contracts/Loans.sol), various `*Withdraw` paths in [`Loans.sol`](contracts/Loans.sol)

`applyWaterfall` will be gated `notCancelledOrClosed`, but `refundBorrower` and the withdraw functions intentionally remain callable on Cancelled / Closed loans to allow post-closure cleanup. Documented here so integrators don't assume terminal status freezes all state.

### 27 — `LoansExchange.forceCancelOffer` lacks `whenNotPaused`

**Where:** [`LoansExchange.forceCancelOffer`](contracts/LoansExchange.sol)

Guardian-only and used for emergency unwind. Pause does not freeze this path.

### 28 — `setMaxPortfolioFactor` silently clamps current factor down

**Where:** [`NavCalculator.setMaxPortfolioFactor`](contracts/NavCalculator.sol)

Lowering the cap reduces the live `portfolioFactor` without an explicit re-assignment event.

### 29 — `setLoansNFT` does not check the reverse pointer

**Where:** [`Loans.setLoansNFT`](contracts/Loans.sol)

[`Loans.setLoansNFT`](contracts/Loans.sol) does not assert `loansNFT.LOANS_CONTRACT() == address(this)`; guardian must verify off-chain. (Resolved on the vault side: [`PortfolioVault.setLoans`](contracts/PortfolioVault.sol) now enforces the reverse-pointer check via `ReversePointerMismatch`.)

### 30 — `PortfolioVault.setLoans` is rotatable; `Loans.loansNFT` is one-shot

**Where:** [`PortfolioVault.setLoans`](contracts/PortfolioVault.sol), [`Loans.setLoansNFT`](contracts/Loans.sol)

`PortfolioVault.setLoans` atomically repoints both `loans` and `loansNFT` together — with a `currency()` match (`AssetMismatch`), a reverse-pointer match (`ReversePointerMismatch`), and a full curated-list reset — so the two pointers can no longer diverge inside the vault. Vault↔loans desync is therefore not possible from the vault side. The remaining asymmetry is on the Loans side: `Loans.loansNFT` is a one-shot setter, so rotating the LoansNFT in production still requires deploying a fresh `Loans` + `LoansNFT` pair and pointing the vault at it via `setLoans`.

### 31 — Revoking `SHAREHOLDER_ROLE` freezes a controller's pending and claimable ERC-7540 requests

**Where:** [`PortfolioVault.cancelDepositRequest`](contracts/PortfolioVault.sol), [`PortfolioVault.deposit` / `mint`](contracts/PortfolioVault.sol), [`PortfolioVault.cancelRedeemRequest`](contracts/PortfolioVault.sol), [`PortfolioVault.redeem` / `withdraw`](contracts/PortfolioVault.sol)

Every claim and cancellation entry point on the vault calls `_requireInvestor(...)`, which checks `shareToken.hasRole(SHAREHOLDER_ROLE, account)`. If the controller's `SHAREHOLDER_ROLE` is revoked while they have:

- a **pending deposit** (`pendingDepositAssets[controller] > 0`) — `cancelDepositRequest` reverts (`_requireInvestor(controller)` and `_requireInvestor(receiver)`); their USDC stays locked in the vault.
- an **approved/claimable deposit** (`claimableDepositShares[controller] > 0`) — `deposit` / `mint` revert (`_requireInvestor(controller)`); their pre-minted shares stay held by the vault.
- a **pending redeem** (`pendingRedeemShares[controller] > 0`) — `cancelRedeemRequest` reverts; their share balance stays escrowed by the vault.
- an **approved/claimable redeem** (`claimableRedeemAssets[controller] > 0`) — `redeem` / `withdraw` revert (both `_requireInvestor(controller)` and `_requireInvestor(receiver)`); their USDC stays held by the vault.

The funds are not lost. Recovery paths, in order of preference:

1. Re-grant `SHAREHOLDER_ROLE` to the controller (admin/guardian on `VaultShareToken`) so they can claim or cancel themselves; revoke again afterwards.
2. Have the controller authorize an operator via `setOperator` before revocation, and route the cancel/claim through that operator (the operator still needs the controller and receiver to satisfy `_requireInvestor`, so this only helps if the role-grant strategy above is also used).
3. As a last resort, use `Rescuable` (admin/guardian) to sweep stuck assets or shares out of the vault to the recovery address — heavier than a per-request cancel, and it does not clear the controller's `pending*` / `claimable*` counters, so internal accounting will then disagree with on-chain balances (2 family of caveat).

The clean operational procedure is therefore: before revoking `SHAREHOLDER_ROLE`, ensure the controller has no pending or claimable requests (drain via the controller, or via their pre-authorized operator).

---

## Trust Assumptions

These roles are trusted by design. A compromised holder is out of scope for the threat model.

- **T-1 — Admin (Safe multisig)** has the broadest blast radius. Admin can pause, rescue (2), write to any operator's address book via `*OnBehalfOf` (14), remove delegates and trusted calls, act as the i==0 caller in `_requireBatchCaller`, and stand in for any role gated by `_requireCallerOrAdmin` — including pulling standing investor/borrower `currency` allowances via `fund` / `receiveBorrowerPayment` (21).
- **T-2 — Originators, servicers, investors** are each responsible for their own self-curated address books (14). The protocol assumes operator hygiene; admin/guardian retain an override path via `*OnBehalfOf` for correction or recovery.
- **T-3 — Calculating agent and NAV batch submitter** are trusted to supply correct discount and portfolio factors (relates to 16) **and** to run `updateNav` batches honestly. The batch submitter chooses batch composition (which loans land in which batch) and finalize timing; combined with 16, factors can change mid-cycle so batch 1 and batch 2 of the same cycle may be computed under different factors. The protocol assumes the calculating agent and submitter are operationally aligned and not biasing NAV via composition / timing / mid-cycle factor changes.
- **T-4 — Servicer** is trusted to compute interest/fees correctly off-chain (3), to supply truthful timestamps (6), and to use `createLedgerEntries` only for legitimate accounting.
- **T-5 — Guardian (timelock)** is trusted to act on emergencies in good faith and not subvert pause/role topology or operational-currency custody (2).
- **T-6 — Currency** is assumed to be a standard ERC-20 (USDC). No fee-on-transfer, no rebasing, 6 decimals as assumed by the ledger, no transfer hooks.
- **T-7 — Safe (Gnosis Safe v1.4)** execution semantics, module model, and storage layout are assumed unchanged.
- **T-8 — `loansNFT` reference stability** during a NAV cycle: the `_navOwnershipNonce` mitigation requires that `PortfolioVault.loansNFT` not rotate mid-cycle (enforced by `_requireIdleNav` on `setLoans`).
- **T-9 — `PORTFOLIO_MANAGER`** directs the vault's USDC into specific loans via [`PortfolioVault.acceptSaleOffer` / `makeSaleOffer`](contracts/PortfolioVault.sol). There is no on-chain price oracle for loan fair value — the role is trusted not to collude with originators or counterparties to overpay for low-quality loans, and not to dump vault inventory at unfavorable prices.
- **T-10 — Hot signers behind `TrustedCalls` and `TrustedSpender`** are the single largest operational attack surface. Each onboarded Safe runs day-to-day operations through delegates (single-key hot wallets) on these modules; a delegate can execute any whitelisted selector and move tokens to any pre-approved recipient up to the per-recipient allowance, with no Safe-multisig signoff. Combined with 12 (default per-recipient allowance is `type(uint208).max`) and 13 (each Safe approves TrustedSpender at `type(uint256).max`), the on-chain blast radius of a single hot-key compromise is "drain every onboarded Safe of every configured currency to any pre-approved recipient." The system therefore assumes — entirely off-chain — that hot keys live in HSM/KMS with rate limits, that the selector whitelist excludes foot-guns (rescue, role grants, etc.), that the pre-approved recipient set is small and operationally meaningful, and that monitoring + guardian/admin `removeDelegate` (15) can react faster than a determined attacker exhausts the allowance.

---

## Design Tradeoffs

Deliberate choices that bound expressiveness or shift responsibility. Not bugs.

- **D-1 — Non-upgradeable contracts.** Bugs require migration, not patching. Contracts are immutable except via parameter setters.
- **D-2 — Per-loan accounting.** Each loan is a separate ledger with its own cash; no cross-loan netting. Operationally simple but expensive for batch operations.
- **D-3 — Off-chain interest calculation.** Enables flexible servicing but moves correctness off-chain (T-4, 3).
- **D-4 — ERC-7540 async claim model.** Claimants must track their pending requests off-chain (10).
- **D-5 — Loan-NFT lock model (ERC-5753-style).** The unlocker bypasses normal ERC-721 approval semantics (23, 24) and is the mechanism behind 1.
- **D-6 — Two-tier role model.** GUARDIAN_ROLE (timelock) + ADMIN_ROLE (multisig). Admin is fast and broad; guardian is slow and final. Asymmetric access patterns (11, 15) are a direct consequence — destructive operations are admin-fast, restorative operations are guardian-slow.
- **D-7 — Self-curated address books with admin override.** Each operator (originator, servicer, investor) maintains its own book via `LoansAuth.registerAddress` with no protocol-side gatekeeping on the common path, which avoids a centralised onboarding chokepoint. Admin/guardian can write to any operator's book via `*OnBehalfOf` to correct mistakes or recover from a compromised operator (14). The tradeoff: every operator's book becomes a target, and compromising one operator yields full registration authority over its book until admin notices and overrides.
- **D-8 — Per-contract pause.** No protocol-wide kill switch (19).
- **D-9 — `_navOwnershipNonce` covers NFT-set churn only.** The snapshot mechanism detects when the vault's NFT inventory changes mid-cycle but does not detect per-loan state mutations. Tradeoff between minimal write overhead and strict freshness during NAV.
