# Loans NFT

## Goal

`LoansNFT` is the ERC721 representation of investor ownership in the protocol. The owner of `tokenId == loanId` is the loan's current investor and receives all future investor distributions. The contract layers ERC-5753-compatible locking on top of ERC721 so that protocol components such as `LoansExchange` can temporarily delegate transfer authority without surrendering wallet-level custody.

## Roles & Permissions

| Role                           | Permissions                                                             |
| ------------------------------ | ----------------------------------------------------------------------- |
| `LOANS_CONTRACT`               | `mint` (called by `Loans.create`)                                       |
| `ADMIN_ROLE`                   | `setBaseURI`, `pause`                                                   |
| `GUARDIAN_ROLE`                | `forceTransfer`, `pause`, `unpause`                                     |
| `PAUSER_ROLE`                  | `pause` only — least-privilege incident-response role                   |
| Token owner / approved address | `lock`, `approve`, `transferFrom`, `safeTransferFrom` (subject to lock) |
| Unlocker                       | `unlock`, `transferFrom` / `safeTransferFrom` while locked              |

Role memberships are not stored on `LoansNFT` itself; `ADMIN_ROLE`, `GUARDIAN_ROLE`, and `PAUSER_ROLE` are cached as immutable role identifiers in the constructor and resolved via `IGuardianAccessControl(LOANS_CONTRACT).hasRole(...)` at call time.

## Locking Model

`LoansNFT` implements ERC-5753-compatible locking:

- `lock(address unlocker, uint256 id)` — token owner, token-approved address, or approved operator designates an `unlocker` for a token. The token can no longer be transferred by anyone other than the `unlocker`. Allowing token-approved addresses to lock is an intentional deviation from the ERC-5753 reference implementation (owner or operator only): it lets integrators such as `LoansExchange` lock listed loans with narrow per-token approvals instead of requiring `setApprovalForAll` over the owner's entire collection, and grants no new power since a per-token approved address can already transfer the token outright.
- `unlock(uint256 id)` — only the current `unlocker` can clear the lock without transferring.
- `getLocked(uint256 tokenId)` — returns the current `unlocker`, or `address(0)` if unlocked.
- A successful transfer of a locked token automatically clears the lock and emits `Unlock`.
- While locked, `getApproved(tokenId)` returns the `unlocker` as the token's effective approved address.

The lock is used by `LoansExchange` to keep listed loan NFTs settlement-bound without escrow, including sale flows initiated by `PortfolioVault`. See [loans_exchange.md](loans_exchange.md) and [vault.md](vault.md).

## Ownership Nonce

`ownershipNonce(address)` is a monotonic per-address counter bumped once for the sender and once for the receiver of every mint, transfer, or burn that the contract processes. Integrators that need to detect any change to an address's NFT ownership set across multiple transactions can snapshot the nonce and re-read it later. The zero address is never bumped.

`PortfolioVault` uses this nonce to detect concurrent ownership changes during multi-block NAV computations and to restart the cycle if its loan set was mutated mid-flight.

## Guardian Recovery via `forceTransfer`

`forceTransfer(address from, address to, uint256 tokenId)` is a guardian-only escape hatch for unlocked NFTs stuck in a recipient that cannot move them on its own. The common case is a contract that was used as the buyer of an `acceptOffer` settlement but lacks the surface area to call `transferFrom` from itself. It is also available as a generic recovery path for any other unlocked ownership-stuck scenario.

Permissioning:

- only addresses with `GUARDIAN_ROLE` on the `Loans` contract may call `forceTransfer`
- subject to the existing guardian timelock governance

Validation:

- `tokenId` must exist (reverts `ERC721NonexistentToken` otherwise)
- `from` must match the current `ownerOf(tokenId)` (reverts `InvalidFrom` otherwise) — this guards the guardian against a stale `from` argument
- `to` must not be `address(0)` (reverts `InvalidTo`); `forceTransfer` is a rescue path, not a burn path
- `tokenId` must not be locked (reverts `TokenLocked`); protocol-specific locks must be cleared by the lock owner first, such as by cancelling an active exchange offer

Execution:

1. transfer the NFT to `to`, bypassing ERC721 approvals; ownership nonces for `from` and `to` are bumped exactly as for a normal transfer
2. emit the standard ERC721 `Transfer` event
3. if `to` is a contract, invoke `onERC721Received` and revert unless it returns the ERC-721 receiver magic value (reverts `ERC721InvalidReceiver` otherwise).
4. emit `ForceTransfer(from, to, tokenId)`

`forceTransfer` deliberately bypasses ERC721 approval, but it does not bypass active locks. A lock means another protocol component currently controls transfer authority; that component must clear the lock through its own state-aware flow before guardian recovery can move the token.

## Pause Restrictions

`LoansNFT` inherits OZ `Pausable` directly (it does not inherit `GuardianAccessControl`; pause/unpause authorization is resolved against the `Loans` contract's roles, like the rest of the contract's access control). It maintains its own pause state, independent of the `Loans` contract's — pausing one does not pause the other, so a full halt of the loan system requires pausing both.

Admin, guardian, or pauser can `pause` (immediate); only guardian can `unpause` (timelocked).

**Functions blocked when paused** (`whenNotPaused`, revert `EnforcedPause()`):

- `transferFrom` / both `safeTransferFrom` variants — no ownership changes during an incident, including by previously-approved operators or unlockers
- `approve`, `setApprovalForAll` — no new transfer authority can be granted
- `lock` — no new locks (a hostile lock makes the token unrecoverable until the unlocker cooperates)

**Functions NOT paused** (recovery paths must stay available during incidents):

- `unlock` — `LoansExchange.forceCancelOffer` (itself deliberately not pause-gated) relies on it to release listed loans
- `forceTransfer` — guardian recovery; calls the internal transfer funnel directly and is unaffected by the `transferFrom` gate
- `mint` — only reachable via `Loans.create`, which is governed by the `Loans` contract's own pause

**Only callable when paused**:

- `unpause` — Unpausing the contract (guardian only)

## Events and Errors

Events (in addition to standard ERC721 / ERC721Enumerable events):

- `BaseURIUpdated(string newBaseURI)`
- `Lock(address indexed unlocker, uint256 indexed id)` (from `ILockable`)
- `Unlock(uint256 indexed id)` (from `ILockable`)
- `ForceTransfer(address indexed from, address indexed to, uint256 indexed tokenId)`
- `Paused(address account)` / `Unpaused(address account)` (from OZ `Pausable`)

Errors (in addition to standard ERC721 errors):

- `Unauthorized()` (from `ILockable`) — used for constructor / mint / `setBaseURI` / `forceTransfer` / `lock` / `pause` / `unpause` access control
- `AlreadyLocked()`
- `InvalidUnlocker()`
- `NotUnlocker()`
- `TokenLocked()`
- `InvalidFrom()`
- `InvalidTo()`
- `EnforcedPause()` / `ExpectedPause()` (from OZ `Pausable`)

## Decisions

| Decision                         | Choice                                                                  | Rationale                                                                                                      |
| -------------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Lock standard                    | ERC-5753-compatible                                                     | Lets external integrators reason about locks via a public-standard surface                                     |
| Role caching                     | `ADMIN_ROLE`, `GUARDIAN_ROLE`, `PAUSER_ROLE` cached in constructor      | Single SLOAD-free role lookup; reuses the `Loans` access-control source of truth                               |
| `forceTransfer` recipient        | Non-zero address required                                               | Rescue path, not a burn path; burns are reserved for the normal `Loans` lifecycle                              |
| `forceTransfer` `from` arg       | Must match current owner                                                | Surfaces stale-input mistakes from the guardian instead of silently transferring whichever token shares the id |
| `forceTransfer` lock policy      | Revert while locked                                                     | Keeps protocol-specific lock cleanup inside the component that owns the lock state, such as `LoansExchange`    |
| `forceTransfer` receiver check   | Invokes `onERC721Received` on contract recipients                       | Consistent with the `Rescuable` safe-transfer rescue path; guarantees `to` can handle and further move the NFT |
| `forceTransfer` ownership nonces | Bumped via the standard `_update` override                              | Keeps downstream observers (notably `PortfolioVault`) consistent regardless of how the transfer happened       |
| Pause state                      | Own OZ `Pausable` state, auth delegated to `Loans` roles                | Independent per-contract pause matching the rest of the protocol, without duplicating role storage             |
| Pause scope                      | Transfers, approvals, and `lock` gated; `unlock` / `forceTransfer` live | Halts ownership changes and hostile locks during incidents while keeping guardian recovery paths operational   |
