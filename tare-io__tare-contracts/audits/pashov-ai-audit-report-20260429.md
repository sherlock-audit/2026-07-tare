# 🔐 Security Review — tare-contracts

---

## Scope

|                                  |                                                                                                                                                                                                            |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Mode**                         | default (full repo)                                                                                                                                                                                        |
| **Files reviewed**               | `Loans.sol` · `LoansExchange.sol` · `LoansLedger.sol`<br>`LoansNFT.sol` · `NavCalculator.sol` · `PortfolioVault.sol`<br>`SmartAccountFactory.sol` · `TrustedCalls.sol` · `TrustedSpender.sol`<br>`VaultShareToken.sol` · `misc/GuardianAccessControl.sol` · `misc/LoansAuth.sol`<br>`misc/Rescuable.sol` · `script/DeployLoans.s.sol` · `script/DeployLocal.s.sol`<br>`script/DeploySmartAccounts.s.sol` · `script/DeployTimelock.s.sol` · `script/DeployVault.s.sol`<br>`script/SafeExec.s.sol` |
| **Confidence threshold (1-100)** | 80                                                                                                                                                                                                         |

---

## Findings

[85] **1. NAV double-count when sale offer is accepted mid-batch updateNav**

`PortfolioVault.updateNav` · Confidence: 85 · [agents: 3]

**Description**
`createSaleOffer` lacks `_requireIdleNav()`, and the resulting offer can be settled by the buyer directly on `LoansExchange.acceptOffer` without any callback into the vault, so a vault-listed loan NFT can be transferred out of the vault while `updateNav` is partway through batched accumulation — `pendingNav` then double-counts the loan's discounted face value alongside the sale proceeds that are already sitting in `assetToken.balanceOf(vault)` at finalization, inflating `lastNav` and mispricing the next `approveDeposit` / `approveRedemption`.

**Fix**

Snapshot the vault's loan IDs at `navStart`, iterate the snapshot instead of re-reading `tokenOfOwnerByIndex` per batch, and verify at finalize that the snapshot still matches the live set; if anything moved in or out, revert and require the manager to restart with a fresh snapshot.

Add storage and an error:

```solidity
uint64[] private navSnapshot;
error NavInvalidated();
```

On the first batch of a NAV cycle, capture the snapshot:

```solidity
if (navStart == 0) {
    navStart = uint48(block.timestamp);
    uint256 n = loansNFT.balanceOf(address(this));
    for (uint256 i; i < n; ++i) {
        navSnapshot.push(uint64(loansNFT.tokenOfOwnerByIndex(address(this), i)));
    }
}
```

Iterate the snapshot inside the batch loop:

```diff
- uint256 total = loansNFT.balanceOf(address(this));
+ uint256 total = navSnapshot.length;
  ...
- loanIds[i] = uint64(loansNFT.tokenOfOwnerByIndex(address(this), cursor + i));
+ loanIds[i] = navSnapshot[cursor + i];
```

At finalize, before computing `lastNav`, verify the set is still intact:

```solidity
if (loansNFT.balanceOf(address(this)) != navSnapshot.length) revert NavInvalidated();
for (uint256 i; i < navSnapshot.length; ++i) {
    if (loansNFT.ownerOf(navSnapshot[i]) != address(this)) revert NavInvalidated();
}
```

The `balanceOf` check catches anything that entered the vault; the per-token `ownerOf` walk catches anything that left. Together they pin the set.

On successful finalize, clear the snapshot alongside the existing reset:

```diff
  navStart = 0;
  navCursor = 0;
  pendingNav = 0;
+ delete navSnapshot;
```

Add a reset path for the manager to restart after `NavInvalidated`:

```solidity
function resetNavComputation() external onlyRole(PORTFOLIO_MANAGER) {
    navStart = 0;
    navCursor = 0;
    pendingNav = 0;
    delete navSnapshot;
    emit NavReset();
}
```

The existing `_requireIdleNav` on `acceptSaleOffer`, `transferLoans`, and the setter functions remains untouched — those are the vault-internal paths that mutate the loan set. `createSaleOffer` does not need gating since it does not transfer NFTs; offers settled by the buyer mid-NAV are handled by the snapshot-verify check at finalize.

---

[85] **2. Approved NFT operator can lock-and-drain investor cashflows**

`LoansNFT.lock` · Confidence: 85 · [agents: 3]

**Description**
`LoansNFT.lock` authorizes via `_isAuthorized(tokenOwner, msg.sender, id)`, which passes for any per-token approvee or operator-for-all and lets the caller name an arbitrary `unlocker`; the unlocker can then call `Loans.investorWithdrawByUnlocker` (which only checks `getLocked == msg.sender`) to receive all currently-claimable interest and principal directly. An operator the owner approved for a routine listing can quietly drain accrued cashflow without ever taking ownership of the NFT.

**Acknowledged**

Once the owner has granted `approve`, the simpler `transferFrom(owner, attacker, id)` + `investorWithdraw` path is strictly easier and yields full ownership plus all future cashflows, so a rational attacker never bothers with the lock+drain detour. The only marginal gain from lock+drain is stealth (NFT still appears in the owner's wallet) but the loss is identical. The finding collapses into standard ERC721 semantics — approval grants transfer authority, and transfer authority is fatal here — rather than an `LoansNFT`-specific escalation.

---

[85] **3. SmartAccountFactory global nonce strands counterfactually-pre-funded Safes**

`SmartAccountFactory.deploySmartAccount` · Confidence: 85 · [agents: 2]

**Description**
`saltNonce` derives from a single shared `nonce` storage counter while `predictSmartAccountAddress` accepts `_nonce` as a caller-supplied parameter; any unrelated `deploySmartAccount` between a user's prediction and their own deploy increments the global counter, producing a different actual Safe address and stranding any assets pre-funded to the originally predicted address.

**Fix**

```diff
- uint256 public nonce;
+ mapping(address => uint256) public nonces;
  ...
  function deploySmartAccount(...) external returns (address smartAccount) {
-     uint256 saltNonce = uint256(keccak256(abi.encodePacked(msg.sender, nonce)));
-     nonce++;
+     uint256 saltNonce = uint256(keccak256(abi.encodePacked(msg.sender, nonces[msg.sender])));
+     nonces[msg.sender]++;
      ...
  }
```

---

[75] **4. Servicer-rewritten borrower address pulls USDC from any approver**

`Loans.updateBorrower` · Confidence: 75

**Description**
`updateBorrower` only validates the new borrower against the servicer's own `LoansAuth` book, and `LoansAuth.registerAddress` is permissionless per-caller, so a servicer can register any address `V` as `Roles.Borrower` in their own book, rewrite `borrowers[loanId] = V`, then call `receiveBorrowerPayment` which pulls USDC from `V`'s allowance via `safeTransferFrom`; the puller can then route those tokens to themselves through `applyWaterfall(servicingFees=X)` + `servicerWithdraw`. `V` only needs a non-zero USDC allowance to the Loans contract (e.g. because they borrow on a different loan).

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | NAV double-count when sale offer is accepted mid-batch updateNav |
| 2 | [85] | Approved NFT operator can lock-and-drain investor cashflows |
| 3 | [85] | SmartAccountFactory global nonce strands counterfactually-pre-funded Safes |
| 4 | [75] | Servicer-rewritten borrower address pulls USDC from any approver |

---

## Leads

Note: These have been reviewed and either acknowledged or deemed false positives, but feel free to explore them further, maybe we missed something...

- **Zero-NAV bootstrap deadlock** — `PortfolioVault.approveDeposit` — Code smells: with no loans yet, `lastNav = balanceOf − totalPendingDepositAssets − totalClaimableRedeemAssets + 0` always lands at 0 after the first `requestDeposit`, and `approveDeposit` then divides by zero (Panic 0x12). User funds are recoverable via `cancelDepositRequest`, but the vault cannot bootstrap without out-of-band asset injection or a pre-seeded loan portfolio.

- **SHAREHOLDER revoke locks pending deposit USDC** — `PortfolioVault.cancelDepositRequest` — Code smells: `_requireInvestor(controller)` and `_requireInvestor(receiver)` both gate on `SHAREHOLDER_ROLE`, whose admin is `WHITELISTER_ROLE`. A whitelister revoking the user's role while a deposit is pending blocks the user from cancelling and from naming any other receiver, locking the USDC inside the vault until the role is restored.

- **USDC blacklist DoS at disburse** — `Loans.disburse` — Code smells: `currency.safeTransfer(borrowers[loanId], netDisbursedAmount)` reverts if the borrower address is on USDC's blacklist (or becomes blacklisted post-create), and the only recovery path (`updateBorrower`) requires the new borrower to be registered in the servicer's address book — if the servicer is offline, investor principal is parked in `ACC_CASH` with no on-chain refund route.

- **Rescuable drains operational currency without invariant updates** — `Rescuable.rescueTokens` — Code smells: no allowlist excludes the contract's working currency; `rescueTokens(currency, type(uint256).max)` on `Loans` drains every `ACC_CASH(loanId)` backing, on `PortfolioVault` drains `assetToken` backing `claimableRedeemAssets` and `shareToken` backing `pendingRedeemShares`, and counter-deductions in `updateNav` are not updated by the rescue, so subsequent NAV finalization underflow-reverts and bricks deposits/redemptions.

- **Asymmetric add/remove on the trusted-call registry** — `TrustedCalls.addTrustedCall` vs `removeTrustedCall` — Code smells: add is gated on `onlyRole(GUARDIAN_ROLE)` while remove is `onlyAdminOrGuardian`. A non-guardian admin can wipe trusted entries that they cannot replace, DoS-ing every Safe that depends on them until a guardian intervenes; restoration is asymmetric and not self-curable.

- **Originator A can create loans bound to Originator B's address book** — `Loans.create` — Code smells: caller is gated on `isAdminOrApprovedOriginator(msg.sender)` but the `originator` parameter is independent; an approved originator A can pass `originator = B` and use B's address book for the borrower/investor/servicer registration checks, minting a loan NFT to a Y who never authorised A. Servicing rights stay with B, so impact is bounded to spam / nuisance loans against unrelated investors.

- **setVault leaves stale MINTER/BURNER on the old vault** — `VaultShareToken.setVault` — Code smells: roles are granted only in the constructor; `setVault` rotates `_vault` but does not revoke MINTER_ROLE/BURNER_ROLE from the old vault nor grant them to the new vault, so the new vault's `approveDeposit/approveRedemption` will revert and the old vault retains uncapped mint/burn authority over share supply.

- **Address book entries are mutable mid-lifecycle** — `LoansAuth.registerAddress / unregisterAddress` — Code smells: any caller can flip role bits in `addressBook[msg.sender][addr]`; once a loan is created against an originator's book, the originator (or the servicer for `updateBorrower`-style paths) can later `unregisterAddress` and brick subsequent role-update calls until the address is re-added.

- **setBaseURI is admin-only while everything else accepts guardian** — `LoansNFT.setBaseURI` — Code smells: the function gates on `hasRole(ADMIN_ROLE, msg.sender)` only — guardian is treated as the strictly more powerful role elsewhere. A deployment that has a guardian but no admin permanently freezes NFT metadata.

- **Servicer can freeform-reallocate non-cash ledger balances** — `Loans.createLedgerEntries` — Code smells: only invariants are `from != ACC_CASH`, `to != ACC_CASH`, `amount > 0`. No whitelist of plausible (from, to) pairs; combined with `servicerWithdraw` (which pays cash for `ACC_SERVICER_FEE_PAID` balances out of the loan's own cash pool), a servicer appears to be able to shift value from investor-payable accounts into servicer-fee accounts and then withdraw real USDC from the loan's cash. Flagged as LEAD pending confirmation that this is bounded by the documented "trusted servicer" model.

- **TrustedSpender / TrustedCalls give admin parity with every onboarded Safe** — `TrustedSpender.setAllowance / addDelegate`, `TrustedCalls.addDelegate` — Code smells: `safeOrAdmin(safe)` lets ADMIN_ROLE/GUARDIAN_ROLE configure allowances and delegates for any Safe that has approved the module. A single admin compromise drains every Safe onboarded to TrustedSpender; concrete blast-radius observation rather than a self-contained exploit.

- **Per-claim 1-wei dust strands inside claimable pools** — `PortfolioVault.deposit / mint / redeem / withdraw` — Code smells: all four claim paths round DOWN, so when `claimableShares != claimableAssets` (the typical post-approval state) partial claims at minimum granularity revert via the `assets > 0 && shares > 0` guards in `_claimDeposit`/`_claimRedeem`, leaving up to 1 wei stranded per cycle in the four `claimable*` pools.

- **applyPortfolioAdjustment intermediate overflow** — `NavCalculator.applyPortfolioAdjustment` — Code smells: `(rawValue * portfolioFactor) / WAD_UNIT` with `portfolioFactor` capped at `3e18`. Aggregate `rawValue` is unbounded (no per-loan or aggregate cap on `principal + interest` int128 values), so a malicious or maxed-out loan could push the multiplication past `uint256.max ≈ 1.16e77` and revert the entire NAV finalization. Practically unreachable for USDC-scale portfolios but worth a `mulDiv` swap or hard cap.

- **int128 accumulator overflow on batched withdrawals** — `Loans.investorWithdraw / servicerWithdraw / originatorWithdraw` — Code smells: `int128 totalTransfer = 0` accumulates per-loan int128 payouts across an unbounded `loanIds` array; a single near-`int128.max` per-loan balance would revert the whole batch under 0.8 checked arithmetic. Hardening only at realistic USDC scale.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
