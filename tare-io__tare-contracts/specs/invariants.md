# Tare Contracts Properties / Invariants

Below is the full catalog of properties this codebase implicitly promises. Each invariant is tagged as follow:

- **[E]** enforced on-chain (a `require` or construction guarantees it)
- **[D]** derived/emergent — true by construction, but _nothing checks it_; violations would be silent (prime fuzz targets)
- **[C]** conditional — holds only while privileged escape hatches (`createLedgerEntries`, `updateLoanData`, rescue, guardian) are unused
- **[O]** operational — deploy-time/config invariant, asserted only off-chain

---

## 1. Ledger accounting — Loans.sol / LoansLedger.sol

**Zero-sum (the accounting equation)**

- **[D]** For every loan: $\sum_{a \in \text{Accounts}} \text{balance}(loanId, a) = 0$. Every mutation goes through `_updateBalances` (`from -= x`, `to += x`), and all balances start at 0. ledger.md lists this as invariant #1 but the chain never verifies it. Any drift means a write path bypassed `_updateBalances`.
- **[D]** Event-sourcing fidelity: replaying all `EntryCreated` events (or `entries[1..entryCount]`) reproduces `accountBalances` exactly, and the `updatedFromBalance`/`updatedToBalance` emitted match storage. Zero on-chain impact if broken — but the LMS reconstructs books from these events.

**Sign conventions** (from Accounts.sol: ids `<200` normally ≥ 0, `≥200` normally ≤ 0)

- **[E]** `ACC_CASH ≥ 0` per loan — the only sign rule actually enforced (`InsufficientCashBalance` in `_updateBalances`).
- **[C]** All other sign conventions (`ACC_BORROWER_PAYMENT_CLEARING ≤ 0`, receivables ≥ 0, payables ≤ 0, paid accounts on the correct side of zero). Normal flows preserve them (e.g. `applyWaterfall` caps allocations at `-clearing`; `refundBorrower` caps at `refundable`; `_clearReceivableDebt` caps at net outstanding), but `createLedgerEntries` can violate any of them. `getLoanAccountBalanceNormalized` silently returns negative values if broken.

**Derived pair/mirror identities**

- **[D]** `ACC_UNALLOCATED_BORROWER_INTEREST_PAYABLE == -(ACC_BORROWER_INTEREST_RECEIVABLE + ACC_BORROWER_INTEREST_PAID)`. Follows from `accrue` + `_processInterestPortion` writing matched entries; drift means an allocation/accrual path desynced.
- **[D]** `ACC_UNFUNDED_COMMITMENT ∈ [-P, 0]`; equals `-P` from `create` until `disburse`, exactly `0` afterwards.
- **[D]** After `fund`, `ACC_INVESTOR_PRINCIPAL_PAYABLE == -commitment` **forever** (no normal flow touches it again; repayment runs through the `BORROWER_PRINCIPAL_REPAID`/`INVESTOR_PRINCIPAL_REPAID` pair). `getLoanValues` and hence NAV assume this.
- **[D]** Net payables (`_getNetPayable` for servicer fee, misc fee, originator fee, investor interest, investor principal) are ≥ 0 **under standard flows** (allocations
  capped, withdrawals take exactly the net). A negative net payable is a _legitimate, documented_ state reachable only via `createLedgerEntries` corrections: it records
  that the counterparty owes the Loans contract.
- **[D]** `outstandingInvestorPrincipal ∈ [0, commitment]` and `investorPrincipalWithdrawable ≤ outstandingInvestorPrincipal` (the NavCalculator clamps negatives to 0 instead of asserting — so violations are _absorbed_, not surfaced).
- **[D]** Cumulative "paid" accounts move monotonically except through the two explicit reversal paths (`returnFunds`, `refundBorrower`); `ACC_SERVICER_ADJUSTMENT` is monotone non-increasing (it's uncapped by design in `returnFunds`).

**Entry-store shape**

- **[E]** Every entry has `amount > 0`, `from != to` (`_createInternalEntry`).
- **[D]** Entries are immutable, dense, 1-indexed per loan (`entries[loanId<<64 | 0]` never exists); `entryCount` is monotone; entry ids never collide across loans (packing `uint128(loanId) << 64 | n` is injective, as is the balance key `uint72(loanId) << 8 | account`). Packing injectivity is a classic "irrelevant until someone widens a type" invariant.
- **[D]** Entry-type constants in LedgerEntries.sol are append-only ("parsed and used by off-chain systems" — renumbering breaks nothing on-chain and everything off-chain).

## 2. Cash custody & token conservation

- **[D]** **Solvency:** `currency.balanceOf(Loans) ≥ Σ_loans ACC_CASH(loan)`, with equality modulo donations. Every `_deposit` adds the same `amount` to both sides; every `_withdraw`/batch withdraw subtracts the same from both. Nothing asserts this.
- **[C]** It survives only while `rescueERC20Tokens` (Rescuable.sol) is never called **on the loan currency itself** — rescue has no `token != currency` carve-out, so a guardian can legally make the contract insolvent against its own ledger. Rescue is now bounded: it is `whenNotPaused`, guardian-only, and can only send to a fixed non-zero `recoveryAddress` (set at construction, guardian-updatable) — it can no longer target an arbitrary address. `rescueERC721Tokens` extends the same escape hatch to ERC-721: a guardian can pull an **unlocked** `LoansNFT` that the `PortfolioVault` legitimately holds out to `recoveryAddress`, removing a loan from portfolio backing (locked/listed loans are protected — see §4/§5). Same for the vault: `assetToken.balanceOf(vault) ≥ totalPendingDepositAssets + totalClaimableRedeemAssets` is enforced by flow logic (`approveRedemption` caps at `idleLiquidity()`) but breakable by rescue. The `idleLiquidity()` zero-clamp existing at all is an admission this can be violated.
- **[D]** **Per-loan segregation:** no operation on loan A ever mutates loan B's balances, and outflows per loan never exceed inflows (cash ≥ 0 + segregation). This also bounds the blast radius of a malicious servicer: via `createLedgerEntries` + `servicerWithdraw` they can drain _their own loan's_ cash, never another loan's, never cash-account entries directly (`from/to != ACC_CASH` **[E]**).
- **[D]** Deposits always pull from the role of record, regardless of caller: `pay` from `borrowers[loanId]`, `fund` from the current NFT owner, `returnFunds` from `msg.sender`(servicer). Batch withdrawals pay a _single_ recipient whose role is uniform across the batch (`_requireBatchCaller`, and owner+unlocker uniformity in `investorWithdraw`) **[E]**.
- **[D]** Batch idempotence: duplicate `loanIds` in a withdraw batch don't double-pay (second pass computes net payable 0), and the single ERC-20 transfer equals the sum of per-loan entries written.
- **[C]** All of this assumes the currency is USDC-like: no fee-on-transfer, no rebasing, no hooks. The invariants are _not_ robust to weird tokens; that's an accepted assumption worth stating as a property ("deposit credits exactly `amount`").

## 3. Lifecycle / status machine — loan_status_lifecycle.md

- **[E]** `fund` only in `Created`, single shot, exact-commitment (`alreadyFunded == 0 && amount == commitment`); `disburse` only from `FullyFunded` with `net + fee == commitment` and `funded == commitment`.
- **[D]** **Status is never trusted where money moves.** `disburse` re-derives funding from the ledger precisely because `updateLoanData` can set any status (the comment says so). The emergent guarantee: even if a servicer sets status back to `FullyFunded`, a second `disburse` is impossible because `-ACC_UNFUNDED_COMMITMENT == 0` and `netDisbursedAmount > 0` is required. So **disbursement is single-shot** regardless of status — but only via this ledger identity, not via any explicit guard. Any new write path into `ACC_UNFUNDED_COMMITMENT`/`ACC_INVESTOR_PRINCIPAL_PAYABLE` (both reachable by `createLedgerEntries` today) plus originator collusion re-opens double-disbursement. The `LoanTerms` fields (`originationDate`, `interestRate`, `expectedMonthlyPayment`) are **not** write-once: the servicer or admin can edit them post-disbursement via `updateLoanTerms` while the loan is non-terminal. These fields do not feed NAV (the calculator values loans from the ledger plus `status`/`nextDueDate`), so editing them cannot desync share pricing.
- **[D]** Separation of duties: no _single_ non-admin role can move another party's cash to itself — the dangerous compositions all require two roles (servicer ledger-forging + originator disbursing, etc.).
- **[C]** `status == Active ⟹ funded == commitment == disbursed`, terminal states stay terminal, `Cancelled` loans satisfy the post-state identities in early*cancellation.md (`ACC_CASH == 0`, net principal 0, etc.) — all breakable by `updateLoanData`/`createLedgerEntries`, which is why they're documented as \_procedural* invariants. Note neither escape hatch has a status gate — both are gated only by `loanExists`, so they operate on terminal (`Cancelled`/`Closed`) loans too.
- **[D]** `loanCount` starts at 0 and only increments; `create` assigns `loanId = ++loanCount`, so the first loan has id 1 and loan 0 never exists; `data[id].status != DoesNotExist ⟺ 1 ≤ id ≤ loanCount`.

## 4. LoansNFT — LoansNFT.sol

- **[D]** Exactly one NFT per loan, `tokenId == loanId`, minted at `create`, **no burn path exists** ⟹ `totalSupply() == loanCount` and `ownerOf(loanId)` never reverts for a created loan. `investorWithdraw`/`fund`/NAV all assume this (a burned token would brick `fund` and NAV self-heals by silently dropping the loan — value quietly vanishes from NAV).
- **[E]** `Loans.loansNFT` is set-once (`AlreadyInitialized`); `mint` callable only by `LOANS_CONTRACT`.
- **[E]** Lock discipline (ERC-5753): locked ⟹ only unlocker can transfer; transfer auto-clears the lock; `approve` blocked and `getApproved` returns the unlocker while locked. Both privileged recovery paths refuse locked tokens: `forceTransfer` checks `_unlockers == 0` explicitly, and `rescueERC721Tokens` routes through the standard `_update` guard (`auth != unlocker ⟹ TokenLocked`), so guardian recovery can never break exchange escrow.
- **[D]** **`ownershipNonce[a]` bumps on _every_ change to `a`'s ownership set** — mint, burn, transfer, forceTransfer, all funnel through `_update`. This is the single most load-bearing "low direct impact" invariant in the system: `PortfolioVault._requireFreshNav` uses it to detect holdings changes. Any future transfer path that skips the bump = silently stale NAV accepted for share pricing.

## 5. LoansExchange — LoansExchange.sol

- **[E]** A loan is in ≤ 1 live offer (`createOffer` requires `getLocked == 0` then locks to the exchange); offer active ⟺ `buyer != 0`; `offerCount` monotone, ids never reused.
- **[E]** Offer shape: `1 ≤ loanIds.length ≤ maxLoansPerOffer`, `seller != buyer`, `deadline > now` at creation; every listed loan is owned by the seller. Expiry blocks settlement (`acceptOffer` requires `now <= deadline`) but does **not** release locks — an expired offer keeps its loans locked until `cancelOffer` (seller) or `forceCancelOffer` (guardian escape hatch, not `whenNotPaused`-gated so it works during incidents).
- **[D]** **Non-custodial:** `CURRENCY.balanceOf(exchange) == 0` and `LOANS_NFT.balanceOf(exchange) == 0` at rest (it holds _locks_, never tokens). A listed loan stays owned by the seller (the exchange is only its unlocker), so even `rescueERC721Tokens` on the exchange cannot extract an escrowed loan — the exchange never owns it.
- **[E]** Settlement ordering: NFTs to buyer before cash to seller, mutual investor-registration checks re-validated at accept time (not just at create).
- **[D]** The anti-front-running property in loans*exchange.md rests on two \_external* invariants: lock prevents seller transfer, and locked-loan `investorWithdraw` routes to the unlocker. Neither is checked inside the exchange.

## 6. PortfolioVault — PortfolioVault.sol

**Share/asset bookkeeping (aggregate = Σ parts — canonical fuzz targets)**

- **[D]** `shareToken.balanceOf(vault) ≥ Σ_c claimableDepositShares[c] + Σ_c pendingRedeemShares[c]`, with equality modulo donations — any shareholder can `transfer` shares directly to the vault (it holds `SHAREHOLDER_ROLE`), so strict equality is not adversarially robust (scenario-tested in Vault_NavSecurity.t.sol, not fuzzed).
- **[D]** `totalPendingDepositAssets == Σ_c pendingDepositAssets[c]` and `totalClaimableRedeemAssets == Σ_c claimableRedeemAssets[c]`. Breaking these has "unknown" impact because both feed **directly into NAV** at finalization.
- **[D]** Conservation: total value claimed across any partial claim sequence equals what approval granted, ± ≤1 wei dust per op, dust always stranded _in the vault_ (rounding never favors the claimant; enforced piecewise by floor division + the `assets > 0 && shares > 0` guards).
- **[D]** Paired emptiness: `claimableDepositAssets[c] == 0 ⟺ claimableDepositShares[c] == 0` (same for redeem side). Floor math preserves it (strict monotonicity of `floor(a·S/A)` for `a < A`), but nothing asserts it; a violation permanently strands the residual.

**NAV state machine**

- **[D]** Idle ⟺ `navStart == 0`, and idle ⟹ `navCursor == 0 && pendingNav == 0`; during a cycle `pendingNav` equals the calculator sum over exactly `_navLoanIds[0..navCursor)`.
- **[E]** A finalized `lastNav` is snapshot-consistent: mid-cycle holdings change (nonce), calculator config change (version), or timeout ⟹ restart, never a mixed-epoch NAV.
- **[E]** `onERC721Received` accepts only the current `loansNFT` collection — foreign-collection NFTs can enter the vault only via bare `transferFrom` (no hook), where they sit inert (never valued, only rescuable).
- **[D]** Curated-list bijection: `_navLoanIndex[id] != 0 ⟺ id ∈ _navLoanIds`, `_navLoanIds[_navLoanIndex[id]-1] == id`, no duplicates (swap-and-pop in `_removeLoanFromNav`, the in-loop no-advance re-scan in `updateNav`). Breakage = double-counted or phantom loans in NAV.
- **[D]** **The master freshness invariant** (vault.md): _every_ state affecting NAV — curated list, NFT holdings, idle USDC, loan ledger, `loans` pointer, calculator config — invalidates the cached NAV before the next `approveDeposit`/`approveRedemption`. It's maintained by a _manual conjunction_ (nonce check + version check + explicit `_invalidateNav()` at each mutating call site + `maxNavAge`). This is the highest-value property to fuzz: each new vault function must remember to invalidate, and a single omission is invisible until mispricing happens.
- **[D]** Accepted staleness bound: DPD buckets in the calculator drift with `block.timestamp` _without_ a version bump — mispricing from time drift is bounded by (one bucket-factor step × principal) within a `maxNavAge` window.

**Supply/price floor**

- **[E]** `DEAD_SHARES = 1e18` minted to `0xdead` at construction ⟹ `totalSupply ≥ 1e18` forever ⟹ `sharePrice()` never divides by zero — _unless_ a guardian grants `BURNER_ROLE` to someone who burns the dead shares (**[O]** only-vault-holds-MINTER/BURNER).
- **[E]** The share token enforces an ERC-1404 shareholder gate in `_update`: every transfer requires both parties to hold `SHAREHOLDER_ROLE`, except mint (`from == 0`) and burn (`to == 0`) which skip the respective side. `detectTransferRestriction` is a pure mirror of this rule (same restriction codes), so the off-chain read path can never disagree with on-chain enforcement. `VaultShareToken` is itself `Rescuable` (fixed `recoveryAddress`).
- **[O]** The vault and `0xdead` must hold `SHAREHOLDER_ROLE` on the share token (mints to vault, dead-share mint, and `requestRedeem` transfers all traverse the `_update` gate). A whitelister revoking the _vault's_ role bricks deposits/redeems — pure config invariant with no on-chain guard. `setVault` revokes `MINTER_ROLE`/`BURNER_ROLE` from the outgoing vault so a replaced or exploited vault can no longer mint or burn shares — but the outgoing vault keeps `SHAREHOLDER_ROLE` (can still hold/receive shares) until a whitelister revokes it.

## 7. NavCalculator — NavCalculator.sol

- **[E]** Per-bucket `discountFactors ≤ 1e18`; `portfolioFactor ≤ maxPortfolioFactor` (with clamp-on-lower).
- **[D]** `configurationVersion` is strictly monotone and bumps whenever the valuation function _may_ have changed: every `setDiscountFactor`/`setPortfolioFactor` call bumps — including a no-op re-set of the same value — and `setMaxPortfolioFactor` bumps only when it clamps `portfolioFactor` (raising the cap alone doesn't). So change ⟹ bump is guaranteed; bump ⟹ change is not.
- **[D]** Statuses with no bucket (`Created`, `FullyFunded`, `FullyPaid`) are always valued at par regardless of configuration; only `Active` uses DPD buckets, and `ChargedOff`/`Closed`/`Cancelled` their status buckets.
- **[D]** Robustness: `getLoansValue` never reverts for any ledger state (negative intermediate values are clamped to 0, `DoesNotExist` skipped) — a single pathological loan must never brick NAV. Also a masking behavior: clamps absorb ledger-corruption signals.
- **[D]** Bounds: per-loan value ≤ un-returned principal + collected cash; NAV portfolio adjustment ≤ `maxPortfolioFactor` × raw.

## 8. Auth layer — GuardianAccessControl.sol / LoansAuth.sol

- **[E]** `GUARDIAN_ROLE` is its own admin and that can never change (`CannotChangeGuardianAdmin`); `DEFAULT_ADMIN_ROLE`'s admin is locked to guardian at init (closing the OZ escalation hole).
- **[E]** Pause ratchet: admin, guardian, or `PAUSER_ROLE` can pause; only guardian can unpause. `PAUSER_ROLE`'s admin is the guardian.
- **[E]** At-least-one-guardian: `_revokeRole` reverts `LastGuardian` when revoking the final guardian (`guardianCount` tracks holders), so the guardian set can never drop to zero. `renounceRole` is disabled entirely (`RenounceRoleDisabled`) — roles are managed only by the guardian via `grant`/`revokeRole`, so no holder can self-strip access (which for the guardian would brick every admin-gated role).
- **[D]** Address-book bit hygiene: register/unregister touch exactly one bit; the canonical book (`addressBook[address(this)]`) is writable only through `approve/revokeOriginator|Servicer` (`registerAddressOnBehalfOf` excludes `address(this)`), so canonical-book bits other than Originator/Servicer are never set. Nothing reads the other bits today → tripwire.
- **[E]** No originator impersonation: `create` requires `msg.sender == originator` _and_ approval (or admin).

## 9. Safe modules — TrustedCalls.sol / TrustedSpender.sol / SmartAccountFactory.sol

- **[E]** TrustedCalls executes only globally whitelisted `(target, selector)` pairs, `value = 0`, `Operation.Call` only (no delegatecall ever), per-safe delegate gate; calldata shorter than 4 bytes is rejected (no fallback/receive-style calls).
- **[D]** Asymmetric ratchets: whitelist-add is guardian-only and delegate-add is safe-or-guardian, while the matching removals additionally open to admin — loosening is strictly harder than tightening.
- **[O]** The "never-whitelist" list in trusted-calls.md (`approve`, `transfer`, `addDelegate`, `addOwnerWithThreshold`, …) is a pure config invariant — nothing on-chain prevents the guardian from whitelisting `USDC.transfer`.
- **[E]** TrustedSpender: transfers only along pre-set `(token, from, to)` routes, allowance decremented exactly (with `uint208.max` infinite sentinel), expiry enforced; **[D]** the module never holds custody (`balanceOf(spender) == 0`).
- **[E]** Factory: `configureSmartAccount` only via delegatecall + one-shot `CONFIGURED_SLOT`; `threshold ∈ [1, owners.length]`; **[D]** `predictSmartAccountAddress` always equals the deployed address for the same inputs/nonce, and per-deployer nonces are monotone.

## 10. Deployment/config invariants — production_deployment_runbook.md

All **[O]** — asserted once by `verify-deployment`, silently violable at runtime:

- Exact-set role membership everywhere (guardian = Timelock only, admin = Admin Safe only, deployer holds nothing) — not enumerable on-chain, so drift after day 1 is invisible without monitoring.
- Pointer-triplet consistency (`exchange.LOANS == vault.loans`, `loansNFT.LOANS_CONTRACT == loans`, currencies all equal) — enforced **[E]** in `setLoans`/`setExchange` at swap time, but only there.
- Timelock `minDelay`, proposer/canceller/executor sets, share-token role topology, SA owner sets `{Ops, HotProxy, Proposer}` at 2/3.

---
