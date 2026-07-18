# PortfolioVault migration runbook

Procedures for rotating the asset-side infrastructure pointed to by `PortfolioVault` (`loans` / `loansNFT`, `calculator`, `exchange`). Safety comes from on-chain setter invariants, `Timelock.executeBatch` atomicity, and an on-chain `finalize(...)` post-condition check included in the same batch. Off-chain scripts exist only as a regression layer (see the bottom of this document).

Related: [vault.md](./vault.md), [loans_exchange.md](./loans_exchange.md), [nav-calculator.md](./nav-calculator.md), [timelocked-tx.md](./timelocked-tx.md).

## Common assumptions

- Guardian = `TimelockController` holding `GUARDIAN_ROLE` on `PortfolioVault` and `VaultShareToken`, and role-admin of `PORTFOLIO_MANAGER` / `INVESTOR_MANAGER`.
- Every "atomic batch" is a single `Timelock.executeBatch(...)` proposal.
- All three setters (`setCalculator`, `setLoans`, `setExchange`) are `onlyRole(GUARDIAN_ROLE)` and `_requireIdleNav()` (revert `NavComputationInProgress` if `navStart != 0`).
- **On-chain enforced cross-invariants** (no off-chain assertion needed):
  - `setLoans(_loans, _loansNFT)` reverts unless `ILoans(_loans).currency() == assetToken` (`AssetMismatch`) and `ILoansNFT(_loansNFT).LOANS_CONTRACT() == _loans` (`ReversePointerMismatch`). Empties the curated NAV list and invalidates the cached NAV.
  - `setExchange(_exchange)` reverts unless `ILoansExchange(_exchange).LOANS() == loans`, `LOANS_NFT() == loansNFT`, and `CURRENCY() == assetToken` (`InvalidExchange`). The `CURRENCY` check is defense-in-depth against forked/custom exchanges whose currency drifted from the vault's asset.
  - `setCalculator(_calculator)` only checks non-zero and invalidates the cached NAV. The calculator is decoupled from `loans` — vault passes `loans` per call.
- **Target-side immutables**: `LoansNFT.LOANS_CONTRACT`, `LoansExchange.{LOANS, LOANS_NFT, CURRENCY}`. Any change to those forces a redeploy.
- **Curated NAV list (`_navLoanIds`)**: only loans admitted via `addLoansToNav` or via `fundLoan*` / `acceptSaleOffer` contribute to NAV. ERC-721 ownership alone is not enough. After `setLoans` the list is empty.

### Bundling principle

Whenever a migration touches more than one of `{loans+loansNFT, exchange, calculator}`, **every setter that changes plus every accompanying `addLoansToNav` / role grant / role revoke / offer cancel rides in the same `Timelock.executeBatch(...)`**. Never queue a second batch "to finish the job".

- A two-batch migration that fails on the second batch leaves the vault stranded mid-state.
- Splitting doubles the timelock latency window during which the vault is degraded.
- `setLoans` empties `_navLoanIds`; until `addLoansToNav` runs in the same batch, every `_requireFreshNav` consumer sees a deflated `lastNav` and would price the next approval wrong.
- `setLoans` also orphans the exchange (the pointer triplet check rejects the old one); a stale exchange is bricked-but-safe — trivially avoidable by bundling.

The only standalone-setter cases are Scenario 1 (exchange-only) and Scenario 2 (calculator-only), and even those bundle their accompanying cancel-offers / role-management.

## Scenarios at a glance

| Need | Use |
|---|---|
| Fix bug in exchange / new fee model | [Scenario 1](#scenario-1--swap-loansexchange-only) |
| Improve valuation / fix bug in calculator | [Scenario 2](#scenario-2--swap-navcalculator-only) |
| Replace loan engine while keeping investors whole | [Scenario 3 Path A](#path-a--liabilities-untouched-via-migrator) |
| Wind down → fresh launch on new infra | [Scenario 3 Path B](#path-b--cleared-vault) |

Every batch ends with an on-chain post-conditions call — see [On-chain post-conditions](#on-chain-post-conditions-load-bearing-defense).

---

## Scenario 1 — Swap `LoansExchange` only

`loans`, `loansNFT`, `calculator` unchanged. New exchange must be bound to the same `LOANS / LOANS_NFT / CURRENCY` immutables.

### Atomic batch
1. For each open offer where vault is seller: `vault.cancelSaleOffer(offerId)`.
2. `vault.setExchange(newExchange)` — reverts unless `LOANS()/LOANS_NFT()/CURRENCY()` all match.
3. `assertions.assertPostConditions(vault, expectedRefs)` on the stateless `VaultAssertions` helper.

### Residual risk
- NFT custody: `createOffer` calls `LoansNFT.lock` (which clears any prior ERC-721 approval); `cancelOffer` calls `unlock`. After step 1 the vault holds zero NFTs locked by the old exchange. No live offer struct, no `_unlockers[tokenId] == oldExchange`, no standing approval.
- Old exchange's USDC allowance from the vault: `acceptSaleOffer` uses `forceApprove(offer.price)` per-offer and `acceptOffer` consumes the full amount via `safeTransferFrom`. Residual is `0`.

### Suggested invariant
After the batch, assert every curated NFT is unlocked so no residual lock references the old exchange:
```solidity
for (uint256 i; i < vault.navLoanCount(); ++i) {
  require(loansNFT.getLocked(vault.navLoanIdAt(i)) == address(0), "stale exchange lock");
}
```

---

## Scenario 2 — Swap `NavCalculator` only

`loans`, `loansNFT`, `exchange` unchanged. Lowest-risk migration — `setCalculator` only invalidates the cached NAV.

### Atomic batch
1. `vault.setCalculator(newCalculator)`.
2. `assertions.assertPostConditions(vault, expectedRefs)`.

### Residual risk
- Off-chain valuation-equivalence: for every curated loan, verify `newCalculator.getLoansValue(vault.loans(), [id]) == oldCalculator.getLoansValue(vault.loans(), [id])` before the batch — or accept that the next `updateNav` will step the share price.
- Re-grant `CALCULATING_AGENT` on `newCalculator` to the operational keys (the calculator's role book is independent of the vault).
- A routine factor change on the *existing* calculator (`setDiscountFactor`, `setPortfolioFactor`, `setMaxPortfolioFactor`) is **not** a migration; it bumps `configurationVersion()` and surfaces at the next `_requireFreshNav` as `CalculatorConfigurationChanged`.

---

## Scenario 3 — Swap `Loans` + `LoansNFT` (always paired; `LoansExchange` must also be swapped)

`LoansNFT.LOANS_CONTRACT` is immutable, so a new `Loans` always pairs with a new `LoansNFT`. The new `LoansExchange` must also be re-deployed (its `LOANS`, `LOANS_NFT`, `CURRENCY` are immutable). `NavCalculator` can stay or be replaced independently.

### Path A — Liabilities untouched, via migrator

Use when: portfolio is active, shareholders must keep their shares, pending/claimable state must survive.

#### Migrator requirements
A one-off `LoansMigrator` that:
- Holds `PORTFOLIO_MANAGER` on the vault for the batch (so it can call `transferLoans` and `addLoansToNav`); revoked at the end.
- Has minting authority on `newLoansNFT`. Because `LoansNFT.LOANS_CONTRACT` is immutable and `mint` is gated to that single address, the migrator must **be** `newLoansNFT.LOANS_CONTRACT()` itself — i.e. the migrator is (or extends) `newLoans`. This satisfies the `setLoans` invariant `LOANS_CONTRACT == _loans`. (A bespoke `LoansNFT` variant with a separate migration mint role would also work but requires a custom collection.)
- Exposes `finalize(PostConditions)` — see [On-chain post-conditions](#on-chain-post-conditions-load-bearing-defense).

The migrator's only job: receive old NFTs from the vault, mint identical (same ids, same ledger semantics) NFTs on `newLoansNFT`, `safeTransferFrom` them back to the vault, admit them into the curated NAV list, run `finalize`.

#### Atomic batch

Single `Timelock.executeBatch(...)`:

1. `vault.grantRole(PORTFOLIO_MANAGER, migrator)`.
2. `migrator.cancelOffers(vault, [offerIds])` — internally calls `vault.cancelSaleOffer(offerId)` for each open vault-as-seller offer.
3. `migrator.pullFromVault(vault, allLoanIds)` — internally calls `vault.transferLoans(allLoanIds, migrator)`. Plain `transferFrom`, auto-removes each loan from the curated NAV set. Vault now holds only USDC.
4. `vault.setLoans(newLoans, newLoansNFT)` — reverts unless `currency()` and `LOANS_CONTRACT()` invariants hold. Curated-list clear is a no-op (step 3 drained it). Cached NAV invalidated.
5. `vault.setExchange(newExchange)` — reverts unless `LOANS()/LOANS_NFT()/CURRENCY()` all point at the new pair / asset.
6. If replacing the calculator: `vault.setCalculator(newCalculator)`.
7. `migrator.mintAndDeliver(vault, allLoanIds)` — mints equivalent NFTs on `newLoansNFT` and `safeTransferFrom`s each to vault. `onERC721Received` passes because `msg.sender == newLoansNFT == vault.loansNFT`.
8. `migrator.admit(vault, allLoanIds)` — calls `vault.addLoansToNav(allLoanIds)`. **Required**: vanilla NFT receipt does **not** auto-admit. Without this the curated set stays empty, `lastNav` deflates, and the next `approveDeposit` / `approveRedemption` mints or burns at the wrong price.
9. `migrator.finalize(expectedRefs)` — reverts the entire batch on any post-condition failure. See [On-chain post-conditions](#on-chain-post-conditions-load-bearing-defense).
10. `vault.revokeRole(PORTFOLIO_MANAGER, migrator)`.

The stored `lastNav` is briefly inflated between steps 3 and 8 (NFTs gone, list empty, but cached NAV still reflects them). The batch executes atomically — no external call can observe or transact against the intermediate state.

#### Properties preserved
- Share supply, shareholders, share-token MINTER/BURNER bindings, `shareToken.vault(asset) == vault`.
- `pendingDepositAssets`, `claimableDepositAssets/Shares`, `pendingRedeemShares`, `claimableRedeemAssets/Shares`.
- ERC-7540 operator approvals (`_isOperator`).
- Vault address and roles (`PORTFOLIO_MANAGER`, `INVESTOR_MANAGER`) — integrators unaffected.

#### Residual risk

Real, value-affecting:
- A bug in the migrator (mints wrong NFTs, drops one, mints to wrong recipient, fails to admit) silently breaks value conservation. Audit the migrator.
- Off-chain state-migration correctness is load-bearing. A single mis-copied ledger entry produces a wrong-by-pennies `lastNav` after the first post-migration `updateNav`.
- **Omitting step 8 (`addLoansToNav`)** is the most dangerous failure — succeeds silently with no on-chain error. Mitigation: `finalize` asserts `navLoanCount == expected` and `isInNav(id)` for every admitted id, so the batch reverts if step 8 was forgotten.

Operational only — cannot leak funds:
- **Omitting step 5 (`setExchange`)** leaves the vault with a stale exchange. The old exchange's immutable `LOANS_NFT` is the old collection, so it cannot list or accept on the new NFTs. Step 3 already moved every old NFT to the migrator, so it cannot move old NFTs from the vault either. The standing USDC allowance is zero between offers, and a replacement `setExchange(badExchange)` reverts under the triplet check. Net: bricked sales path, no fund loss, recoverable by a single-call `setExchange` batch.

---

### Path B — Cleared vault

Use when: portfolio is being wound down, fresh launch on new infra, or participant set is small/governed enough to coordinate full redemption.

#### Pre-batch drain (off-chain orchestration over multiple txs)

Before the atomic batch can run, the vault must be empty of NFTs and liabilities. This phase is inherently off-chain because it depends on controllers cooperating:

1. Communicate the migration to shareholders and operators; publish a redemption deadline.
2. Halt new deposits (revoke `INVESTOR_MANAGER` from operational keys or pause the vault).
3. Controllers `cancelDepositRequest` / `cancelRedeemRequest` or claim outstanding `claimable*` balances; pending shareholders request a full redemption.
4. Drain loans via `transferLoans` to a custodian (auto-removes from the curated NAV set). Prefer this over `createSaleOffer` because exchange settlement does *not* synchronously remove `_navLoanIds` entries.
5. Process every redemption. `approveRedemption` enforces `assets <= idleLiquidity()`, so sequence drains and approvals together.
6. Run `vault.updateNav(batchSize)` to self-heal the curated list to empty.
7. Final state pre-batch: `totalPendingDepositAssets() == 0`, `totalClaimableRedeemAssets() == 0`, all per-controller counters zero, `oldLoansNFT.balanceOf(vault) == 0`, no open vault-as-seller offers, `shareToken.totalSupply() == DEAD_SHARES`, `navStart() == 0`.

#### Atomic batch

1. `vault.setLoans(newLoans, newLoansNFT)`.
2. `vault.setExchange(newExchange)`.
3. If replacing the calculator: `vault.setCalculator(newCalculator)`.
4. `assertions.assertPostConditions(vault, expectedRefs)` on the stateless `VaultAssertions` helper.

#### Post-batch (separate tx)

A keeper holding `PORTFOLIO_MANAGER` or `INVESTOR_MANAGER` calls `vault.updateNav(batchSize)` once. The curated list is empty, so the loop exits immediately and finalizes `lastNav = assetToken.balanceOf(vault) + calculator.applyPortfolioAdjustment(0)`. Not in the atomic batch because the Timelock holds `GUARDIAN_ROLE`, not either manager role. Until this runs, the vault has a stale cached NAV — harmless because there are no shareholders and no pending requests, so no `_requireFreshNav` path is reachable.

#### Properties preserved
- Vault address. Share token contract. Share token roles (MINTER/BURNER still bound to this vault). Vault roles.

#### Properties NOT preserved
- All shareholders are out (intentional).
- All ERC-7540 operator approvals are stale but harmless (no controllers have state).
- `DEAD_SHARES` remain on the share token.

#### Residual risk
- Liveness on the cooperation phase. If a controller is unreachable, their `pendingX` cannot be cleared without their cancel call. Migration is blocked until resolved.
- Only viable when participant set is small or governed by terms-of-service that compel redemption.

---

## On-chain post-conditions (load-bearing defense)

Every migration batch ends with one of:

- **Path A**: `migrator.finalize(expectedRefs)` — step 9 of the atomic batch, before role teardown.
- **Path B and Scenarios 1/2**: `assertions.assertPostConditions(vault, expectedRefs)` on a stateless `VaultAssertions` helper deployed once per network and reused.

Why this is the primary defense, not off-chain verification:

- **Atomic with the state change.** A failed assertion reverts the entire batch — the migration either lands fully consistent or doesn't land at all. No window where the vault is half-migrated.
- **Runs as the Timelock at execution time.** Catches drift between batch construction (queued behind the delay) and execution: a state-changing tx in the delay window, a setter wired to a stale address, an env var that was correct then but isn't now.
- **The queued payload is its own audit artifact.** Reviewers during the timelock delay can decode the assertion arguments from calldata and see exactly which invariants will be enforced.

### Assertion set

```solidity
function finalize(PostConditions calldata p) external {
  require(msg.sender == p.expectedTimelock, "only timelock executor");

  // (1) Guardian is the deployed TimelockController, not an EOA / Safe / random contract.
  require(p.expectedTimelock.code.length > 0, "guardian not a contract");
  require(
    TimelockController(payable(p.expectedTimelock)).PROPOSER_ROLE() == keccak256("PROPOSER_ROLE"),
    "guardian not a TimelockController"
  );
  require(p.vault.hasRole(p.vault.GUARDIAN_ROLE(), p.expectedTimelock), "vault guardian drift");

  // (2) Asset-side pointer equality.
  require(address(p.vault.loans()) == p.expectedLoans, "loans pointer drift");
  require(address(p.vault.loansNFT()) == p.expectedLoansNFT, "nft pointer drift");
  require(address(p.vault.exchange()) == p.expectedExchange, "exchange pointer drift");
  require(address(p.vault.calculator()) == p.expectedCalculator, "calculator pointer drift");

  // (3) Cross-invariants between the new contracts. Redundant with the setter checks for
  //     the same-batch calls, but covers any later in-batch state change that could
  //     violate them after the setters ran.
  require(ILoansNFT(p.expectedLoansNFT).LOANS_CONTRACT() == p.expectedLoans, "nft reverse pointer");
  require(address(ILoans(p.expectedLoans).currency()) == address(p.vault.assetToken()), "currency drift");
  require(ILoansExchange(p.expectedExchange).LOANS() == ILoans(p.expectedLoans), "exchange→loans");
  require(ILoansExchange(p.expectedExchange).LOANS_NFT() == ILoansNFT(p.expectedLoansNFT), "exchange→nft");
  require(address(ILoansExchange(p.expectedExchange).CURRENCY()) == address(p.vault.assetToken()), "exchange→currency");

  // (4) Share-token binding preserved.
  require(p.vault.shareToken().vault(address(p.vault.assetToken())) == p.vault, "share-token vault binding");

  // (5) NAV idle.
  require(p.vault.navStart() == 0, "nav computation in progress");

  // (6) Curated NAV inventory matches expectation.
  //       Path A: equals migrated id count, every id present.
  //       Path B: equals zero.
  require(p.vault.navLoanCount() == p.expectedNavLoanCount, "curated list length");
  for (uint256 i; i < p.expectedAdmittedIds.length; ++i) {
    require(p.vault.isInNav(p.expectedAdmittedIds[i]), "missing admitted loan");
  }

  // (7) Migrator decommissioned (Path A only — pass address(0) to skip).
  if (p.migrator != address(0)) {
    require(!p.vault.hasRole(p.vault.PORTFOLIO_MANAGER(), p.migrator), "migrator role not revoked");
    require(!p.vault.hasRole(p.vault.INVESTOR_MANAGER(), p.migrator), "migrator role not revoked");
  }

  // (8) Liability-side bookkeeping.
  //       Path A: counters unchanged from pre-batch snapshots.
  //       Path B: both zero.
  require(p.vault.totalPendingDepositAssets() == p.expectedTotalPendingDeposit, "pending deposit drift");
  require(p.vault.totalClaimableRedeemAssets() == p.expectedTotalClaimableRedeem, "claimable redeem drift");
}
```

### Operational notes

- **The fresh-NAV check is the one assertion that cannot live here.** The migrator does not hold `PORTFOLIO_MANAGER` / `INVESTOR_MANAGER` (and shouldn't), and an `updateNav` cycle for a large portfolio may not fit in one transaction. Run it as a follow-up tx and gate any subsequent approval on its result.
- **Pre-batch snapshots** (`expectedTotalPendingDeposit`, `expectedTotalClaimableRedeem`) are read off-chain at batch construction and baked into calldata. Any state-changing tx in the delay window that moves either counter reverts the batch on execution — correct behavior, because the migration's assumptions are no longer valid.
- **`VaultAssertions`** should be deployed with no admin and no upgrade path. Its only entry point is `assertPostConditions(...)` (view-only, all reverts). Audit once, reuse forever.

### Layered enforcement

| Layer | When | What it catches | Bypass-able |
|---|---|---|---|
| Setter cross-invariants (`setLoans` / `setExchange`) | Per-setter | Wrong currency, broken pointer triplet | No |
| `finalize(...)` / `assertPostConditions(...)` in the batch | End of `executeBatch` | Pointer drift, guardian drift, missing `addLoansToNav`, missing role teardown, liability counter drift | No |
| `test/script/*.t.sol` | CI | Regressions in the migrator / assertions contract | No (gates merge) |
| Off-chain regression script (optional) | After execution | Fresh `updateNav` cycle; secondary cross-check | Yes |

The pattern: **on-chain `finalize` is the load-bearing defense**. Everything else is regression coverage.

---

## Off-chain regression checks (optional)

Only run these after a successful batch, as a second cross-check. They are **not** the primary defense — every invariant below except #13 is already enforced atomically by the in-batch `finalize` call.

1. `vault.loans() == expectedLoans`
2. `vault.loansNFT() == expectedLoansNFT`
3. `vault.exchange() == expectedExchange`
4. `vault.calculator() == expectedCalculator`
5. `ILoansNFT(vault.loansNFT()).LOANS_CONTRACT() == vault.loans()`
6. `ILoans(vault.loans()).currency() == vault.assetToken()`
7. `ILoansExchange(vault.exchange()).LOANS() == vault.loans()`
8. `ILoansExchange(vault.exchange()).LOANS_NFT() == vault.loansNFT()`
9. `ILoansExchange(vault.exchange()).CURRENCY() == vault.assetToken()`
10. `vault.shareToken().vault(vault.assetToken()) == vault`
11. `shareToken.hasRole(MINTER_ROLE, vault) && shareToken.hasRole(BURNER_ROLE, vault)`
12. `vault.navStart() == 0`
13. **Trigger a fresh full `updateNav` cycle; assert `lastNav` matches scenario-specific expectation.** Only on-chain signal that Path A's `addLoansToNav` ran correctly across many batches. Mandatory for Path A; gate any subsequent approval on its result.
14. `vault.totalPendingDepositAssets()` / `vault.totalClaimableRedeemAssets()` match pre-batch snapshots (Path A) or are zero (Path B).
15. Off-chain reconstruction of `_navLoanIds` from `LoanAddedToNav` / `LoanRemovedFromNav` events matches expectation.
16. Every curated NFT is unlocked: for each `id` in `_navLoanIds`, `loansNFT.getLocked(id) == address(0)`. Confirms no residual lock references the old exchange after an exchange swap (Scenario 1) or a `loans`/`loansNFT` swap (Scenario 3).

Any failed assertion ⇒ pause vault, investigate. In practice the batch would have reverted before reaching this script.
