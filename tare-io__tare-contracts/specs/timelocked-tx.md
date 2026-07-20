# Timelocked Operations

## Overview

Critical operations on the Tare protocol are timelocked using OpenZeppelin's [TimelockController](https://docs.openzeppelin.com/contracts/5.x/api/governance#TimelockController). All protocol contracts use OpenZeppelin `AccessControl` with a shared `GuardianAccessControl` base that defines `GUARDIAN_ROLE` and `ADMIN_ROLE`. The TimelockController is set as the guardian on these contracts, enforcing a mandatory delay between proposing and executing sensitive operations.

A dedicated Proposer Safe is the sole **proposer** on the TimelockController, and the Admin Safe is the sole **canceller** (the `CANCELLER_ROLE` that OpenZeppelin auto-grants to proposers is revoked at deploy time). Execution is **open** (`address(0)` is granted the executor role) by default, meaning anyone can trigger execution after the timelock has passed — the security guarantee comes from the delay, not the executor.

## Why a Guardian Role

The protocol uses a two-tier access model via `GuardianAccessControl` (built on OpenZeppelin `AccessControl`):

- **Guardian (TimelockController):** Critical operations with a publicly visible delay — can be cancelled during the waiting period
- **Admin (Safe wallet):** Retains immediate access to operational functions (pause, revoke roles, remove delegates) for fast emergency response
- **Pauser (`PAUSER_ROLE`):** Optional least-privilege role that can only `pause` — intended for onboarding 3rd-party incident-response services. Administered by the guardian; not granted at deployment

Functions that need to be callable by both admins and guardians use the `onlyAdminOrGuardian` modifier. Functions restricted to guardians only use `onlyRole(GUARDIAN_ROLE)`. `GUARDIAN_ROLE` is the role admin for `ADMIN_ROLE`, meaning only guardians can grant or revoke admin access.

This two-tier model ensures emergencies can be handled instantly while the most dangerous operations (granting admin rights, approving originators/servicers, rescuing tokens, whitelisting calls) require a timelock delay.

## Architecture

```
┌───────────────┐    schedule()     ┌─────────────────────┐    execute()     ┌────────────────────┐
│ Proposer Safe │ ──────────────▶ │  TimelockController  │ ──────────────▶ │  Loans /           │
│  (Proposer)   │                   │  (Guardian on target │                 │  TrustedCalls /    │
└───────────────┘                   │   contracts)         │                 │  TrustedSpender    │
┌───────────────┐    cancel()       │                      │                 │                    │
│  Admin Safe   │ ──────────────▶ │                      │                 │                    │
│  (Canceller)  │                   └─────────────────────┘                 └────────────────────┘
│               │                            │
│               │                     Anyone executes after the
│               │                     delay (open executor)
│               │
└── Admin Safe also has ADMIN_ROLE ──▶ Immediate pause, revokeRole, etc.
```

### TimelockController Role Setup

| TimelockController Role | Assigned To                                                   | Purpose                        |
| ----------------------- | ------------------------------------------------------------- | ------------------------------ |
| `PROPOSER_ROLE`         | Proposer Safe                                                 | Schedule timelocked operations |
| `CANCELLER_ROLE`        | Admin Safe (the auto-grant to proposers is revoked at deploy) | Cancel pending operations      |
| `EXECUTOR_ROLE`         | `address(0)` — open execution (a restricted set is supported) | Execute operations after delay |
| `DEFAULT_ADMIN_ROLE`    | TimelockController itself (self-administered)                 | Manage roles and delay         |

### Contract Role Setup

Each target contract inherits `GuardianAccessControl` which provides `GUARDIAN_ROLE`, `ADMIN_ROLE`, and `PAUSER_ROLE` (all `bytes32` constants). The constructor calls `_initGuardian(initialGuardian)` to set up the role admin hierarchy and grant the initial guardian.

- **Admin** — The Admin Safe address, granted `ADMIN_ROLE` by the guardian post-deployment. Has immediate access to operational functions.
- **Guardian** — The TimelockController address, granted `GUARDIAN_ROLE`. Required for critical functions.

The deployment script performs these grants and revokes the deployer's `GUARDIAN_ROLE` in the same broadcast, leaving the contracts with only the configured admin and guardian:

```
// Performed in-script after construction:
grantRole(GUARDIAN_ROLE, timelockControllerAddress)
grantRole(ADMIN_ROLE, adminSafeAddress)
revokeRole(GUARDIAN_ROLE, deployer)  // deployer gives up guardian
```

## Guardian Functions (Timelocked)

Functions protected by `onlyRole(GUARDIAN_ROLE)` can only be called by the guardian address (TimelockController). Since all calls from the TimelockController go through the schedule → delay → execute flow, these functions are inherently timelocked.

### TrustedCalls

| Function                          | New Modifier                 | Why Timelocked                                                                                   |
| --------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------ |
| `addTrustedCall(address, bytes4)` | `onlyRole(GUARDIAN_ROLE)`    | Whitelisting new functions for delegate execution — a malicious addition could enable fund theft |
| `unpause()`                       | `onlyRole(GUARDIAN_ROLE)`    | Resuming operations after an emergency should be deliberate                                      |
| `rescueTokens(address)`           | `onlyRole(GUARDIAN_ROLE)`    | Token recovery — potential fund extraction vector                                                |
| `grantRole(ADMIN_ROLE, addr)`     | `GUARDIAN_ROLE` (role admin) | Granting admin rights — the most sensitive operation                                             |
| `grantRole(GUARDIAN_ROLE, addr)`  | `GUARDIAN_ROLE` (role admin) | Granting guardian rights is itself a critical operation                                          |
| `revokeRole(GUARDIAN_ROLE, addr)` | `GUARDIAN_ROLE` (role admin) | Removing a guardian is a critical operation that only another guardian should perform            |

### Loans (including LoansAuth)

| Function                          | Modifier                     | Why Timelocked                                                                        |
| --------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------- |
| `rescueTokens(address, uint256)`  | `onlyRole(GUARDIAN_ROLE)`    | Token recovery — potential fund extraction vector                                     |
| `updateServicer(uint64, address)` | `onlyRole(GUARDIAN_ROLE)`    | Changing a loan's servicer affects who controls loan operations                       |
| `approveOriginator(address)`      | `onlyRole(GUARDIAN_ROLE)`    | Whitelisting originators who can create loans — grants significant protocol access    |
| `approveServicer(address)`        | `onlyRole(GUARDIAN_ROLE)`    | Whitelisting servicers who can manage loan operations                                 |
| `grantRole(ADMIN_ROLE, addr)`     | `GUARDIAN_ROLE` (role admin) | Granting admin rights                                                                 |
| `grantRole(GUARDIAN_ROLE, addr)`  | `GUARDIAN_ROLE` (role admin) | Granting guardian rights is itself a critical operation                               |
| `revokeRole(GUARDIAN_ROLE, addr)` | `GUARDIAN_ROLE` (role admin) | Removing a guardian is a critical operation that only another guardian should perform |

### LoansExchange

| Function                          | Modifier                     | Why Timelocked                                                                        |
| --------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------- |
| `rescueTokens(address)`           | `onlyRole(GUARDIAN_ROLE)`    | Token recovery — potential fund extraction vector                                     |
| `forceCancelOffer(uint64)`        | `onlyGuardian`               | Stuck-offer recovery — clears live offer state and unlocks listed loan NFTs           |
| `grantRole(ADMIN_ROLE, addr)`     | `GUARDIAN_ROLE` (role admin) | Granting admin rights                                                                 |
| `grantRole(GUARDIAN_ROLE, addr)`  | `GUARDIAN_ROLE` (role admin) | Granting guardian rights is itself a critical operation                               |
| `revokeRole(GUARDIAN_ROLE, addr)` | `GUARDIAN_ROLE` (role admin) | Removing a guardian is a critical operation that only another guardian should perform |

### TrustedSpender

| Function                          | Modifier                     | Why Timelocked                                                                        |
| --------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------- |
| `unpause()`                       | `onlyRole(GUARDIAN_ROLE)`    | Resuming operations should be deliberate                                              |
| `rescueTokens(address)`           | `onlyRole(GUARDIAN_ROLE)`    | Token recovery — potential fund extraction vector                                     |
| `grantRole(ADMIN_ROLE, addr)`     | `GUARDIAN_ROLE` (role admin) | Granting admin rights                                                                 |
| `grantRole(GUARDIAN_ROLE, addr)`  | `GUARDIAN_ROLE` (role admin) | Granting guardian rights is itself a critical operation                               |
| `revokeRole(GUARDIAN_ROLE, addr)` | `GUARDIAN_ROLE` (role admin) | Removing a guardian is a critical operation that only another guardian should perform |

## Admin Functions (Immediate — No Timelock)

The admin role retains immediate access to operational and emergency functions. No changes to existing admin permissions are needed for functions not listed above.

### TrustedCalls

| Function                             | Modifier                     | Rationale                                         |
| ------------------------------------ | ---------------------------- | ------------------------------------------------- |
| `pause()`                            | admin, guardian, or pauser   | Emergency pause must be instant                   |
| `removeTrustedCall(address, bytes4)` | `onlyAdminOrGuardian`        | Removing a whitelisted call is a defensive action |
| `addDelegate(address, address)`      | `safeOrAdmin`                | Adding delegate access requires quick action      |
| `removeDelegate(address, address)`   | `safeOrAdmin`                | Revoking delegate access should be immediate      |
| `revokeRole(ADMIN_ROLE, addr)`       | `GUARDIAN_ROLE` (role admin) | Revoking admin rights — guardian-controlled       |

### Loans (including LoansAuth)

| Function                            | Modifier                                                         | Rationale                                                                                                   |
| ----------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `setLoansNFT(address)`              | `onlyAdminOrGuardian`                                            | One-time setup during deployment, called by deployer who has admin rights                                   |
| `revokeRole(ADMIN_ROLE, addr)`      | `GUARDIAN_ROLE` (role admin)                                     | Revoking admin rights — guardian-controlled                                                                 |
| `revokeOriginator(address)`         | `onlyAdminOrGuardian`                                            | Revoking an approved originator is a defensive action                                                       |
| `revokeServicer(address)`           | `onlyAdminOrGuardian`                                            | Revoking an approved servicer is a defensive action                                                         |
| `registerAddressOnBehalfOf(...)`    | `onlyAdminOrGuardian`                                            | Operational address book management                                                                         |
| `unregisterAddressOnBehalfOf(...)`  | `onlyAdminOrGuardian`                                            | Operational address book management                                                                         |
| All `onlyServicerOrAdmin` functions | `onlyServicerOrAdmin`                                            | Admin override for routine servicer operations remains immediate                                            |
| `create(...)`                       | `_isAdminOrGuardian` or approved originator that is `msg.sender` | Approved originators can create their own loans immediately; admin/guardian override also remains immediate |

### LoansExchange

| Function                       | Modifier                     | Rationale                                   |
| ------------------------------ | ---------------------------- | ------------------------------------------- |
| `setMaxLoansPerOffer(uint64)`  | `onlyAdminOrGuardian`        | Configuration change for offer limits       |
| `revokeRole(ADMIN_ROLE, addr)` | `GUARDIAN_ROLE` (role admin) | Revoking admin rights — guardian-controlled |

### TrustedSpender

| Function                           | Modifier                     | Rationale                                    |
| ---------------------------------- | ---------------------------- | -------------------------------------------- |
| `pause()`                          | admin, guardian, or pauser   | Emergency pause must be instant              |
| `removeDelegate(address, address)` | `safeOrAdmin`                | Revoking delegate access should be immediate |
| `revokeRole(ADMIN_ROLE, addr)`     | `GUARDIAN_ROLE` (role admin) | Revoking admin rights — guardian-controlled  |

## Recovery Wallet

To increase security of fund recovery, both `Loans` and `TrustedCalls` (and `TrustedSpender`) add a **recovery wallet** — a pre-set address where rescued tokens are always sent, regardless of `msg.sender`.

### Current Problem

Today, `rescueTokens` sends tokens to `msg.sender`. This is problematic for two reasons:

1. **Funds would be stuck in the TimelockController.** Since `rescueTokens` is now a guardian function, `msg.sender` is the TimelockController contract. Sending tokens there would trap them — the TimelockController has no mechanism to forward arbitrary ERC20 tokens.

### Solution

A dedicated `recoveryWallet` address is stored on contracts that implement the recovery-wallet pattern. `rescueTokens` on those contracts sends to `recoveryWallet` instead of `msg.sender`. `LoansExchange` is an exception in the current design: loan-offer recovery uses `forceCancelOffer(uint64)` rather than a recovery wallet.

### Functions

#### setRecoveryWallet

```
setRecoveryWallet(address wallet)
```

**Purpose:** Set the address where rescued tokens are sent.

**Authorization:** `onlyRole(GUARDIAN_ROLE)` (timelocked via TimelockController).

**Validation:**

- `wallet` must not be `address(0)`

**Behavior:**

- Stores `recoveryWallet = wallet`
- Emits `RecoveryWalletSet(wallet)`

**Applies to:** `Loans`, `TrustedCalls`, `TrustedSpender`

#### rescueTokens (Modified)

Current:

```solidity
// TrustedCalls / TrustedSpender
function rescueTokens(address token) external onlyRole(GUARDIAN_ROLE) {
    IERC20(token).safeTransfer(msg.sender, amount);  // sends to caller
}
```

New:

```solidity
function rescueTokens(address token, uint256 amount) external onlyRole(GUARDIAN_ROLE) {
    require(recoveryWallet != address(0), RecoveryWalletNotSet());
    IERC20(token).safeTransfer(recoveryWallet, amount);
    emit TokensRescued(token, recoveryWallet, amount);
}
```

**Behavior:**

- Sends tokens to `recoveryWallet` instead of `msg.sender`
- Requires `recoveryWallet != address(0)`
- Emits `TokensRescued(token, recoveryWallet, amount)`

## Batching Multiple Timelocked Operations

The TimelockController natively supports batching via `scheduleBatch` / `executeBatch`. Multiple admin calls can be grouped into a single timelocked operation — they share one delay period and execute atomically (all-or-nothing).

### Example: Cross-Contract Batch

```
1. Admin Safe → TimelockController.scheduleBatch(
     targets:  [loans, trustedCalls, trustedSpender],
     values:   [0, 0, 0],
     payloads: [
       abi.encodeCall(Loans.setAdmin, (newAdminAddress)),
       abi.encodeCall(TrustedCalls.setAdmin, (newAdminAddress)),
       abi.encodeCall(TrustedSpender.setAdmin, (newAdminAddress))
     ],
     predecessor: bytes32(0),
     salt:        bytes32(uniqueSalt),
     delay:       172800
   )

2. After delay, executeBatch grants admin on all three contracts atomically
```

### Ordering with Predecessors

The `predecessor` parameter enables sequencing: operation B can require operation A to be completed first. This is useful when a later batch depends on state changes from an earlier one (e.g., first grant admin, then configure settings under that admin). Both operations go through their own independent delay.

## Contract Changes Required

### GuardianAccessControl.sol (base contract)

Shared base contract for all protocol contracts, built on OpenZeppelin `AccessControl`:

- **Constants:**
  - `bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE")`
  - `bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE")`
  - `bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE")`

- **Initialization:** `_initGuardian(address initialGuardian)` sets up the role admin hierarchy and grants the initial guardian:
  - `_setRoleAdmin(GUARDIAN_ROLE, GUARDIAN_ROLE)` — self-administered
  - `_setRoleAdmin(ADMIN_ROLE, GUARDIAN_ROLE)` — guardians control admins
  - `_setRoleAdmin(PAUSER_ROLE, GUARDIAN_ROLE)` — guardians control pausers
  - `_grantRole(GUARDIAN_ROLE, initialGuardian)`

- **Helpers:**
  - `onlyAdminOrGuardian` — modifier that reverts if caller has neither `ADMIN_ROLE` nor `GUARDIAN_ROLE`
  - `_isAdminOrGuardian(address)` — returns true if address has either role

- **Pause:** `pause()` is callable by admin, guardian, or `PAUSER_ROLE` holders — the pauser is a least-privilege pause-only role for incident response. `unpause()` remains guardian-only.

- **Self-removal protection:** `renounceRole` is disabled and always reverts with `RenounceRoleDisabled`. Revocations track a guardian count, and revoking the last remaining guardian reverts with `LastGuardian` — the contract can never be left without a guardian. A guardian can still be revoked (including by itself) as long as another guardian remains.

### Rescuable.sol

Inherits `GuardianAccessControl`. Provides `rescueTokens` and `rescueNFT` gated by `onlyRole(GUARDIAN_ROLE)`, sending to a pre-set `recoveryWallet`.

### TrustedCalls.sol

1. Inherits `Rescuable` (which provides `GuardianAccessControl`)
2. **Guardian-only functions:** `addTrustedCall`, `unpause`, `rescueTokens` — `onlyRole(GUARDIAN_ROLE)`
3. **Admin-or-guardian functions:** `removeTrustedCall` — `onlyAdminOrGuardian`; `pause` — admin, guardian, or pauser
4. **Recovery wallet:** `setRecoveryWallet(address)` — `onlyRole(GUARDIAN_ROLE)`

### TrustedSpender.sol

1. Inherits `Rescuable` (which provides `GuardianAccessControl`)
2. **Guardian-only functions:** `unpause`, `rescueTokens` — `onlyRole(GUARDIAN_ROLE)`
3. **Pause:** `pause` — admin, guardian, or pauser
4. **Recovery wallet:** same pattern as TrustedCalls

### Loans.sol (including LoansAuth)

1. `LoansAuth` inherits `GuardianAccessControl`
2. **Guardian-only functions:** `rescueTokens`, `updateServicer`, `approveOriginator`, `approveServicer` — `onlyRole(GUARDIAN_ROLE)`
3. **Admin-or-guardian functions:** `revokeOriginator`, `revokeServicer`, `setLoansNFT`, `registerAddressOnBehalfOf`, `unregisterAddressOnBehalfOf` — `onlyAdminOrGuardian`
4. **Recovery wallet:** `setRecoveryWallet(address)` — `onlyRole(GUARDIAN_ROLE)`

### LoansExchange.sol

1. Inherits `Rescuable` (which provides `GuardianAccessControl`)
2. **Guardian-only functions:** `rescueTokens` — `onlyRole(GUARDIAN_ROLE)`, `forceCancelOffer` — `onlyGuardian`
3. **Admin-or-guardian functions:** `setMaxLoansPerOffer` — `onlyAdminOrGuardian`
4. **No `rescueNFT`:** Stuck listed loan offers must be recovered through `forceCancelOffer(uint64)` because listed loans remain owned by the seller while locked.

## Deployment

### TimelockController Deployment

The TimelockController is deployed via the `deploy timelock` CLI preset, which accepts explicit proposer / canceller / executor sets:

```bash
pnpm tare-contracts deploy timelock \
  --chain <chain> --name <name> \
  --min-delay <seconds> \
  --proposer <proposerSafe> \
  --canceller <adminSafe> \
  --executor 0x0000000000000000000000000000000000000000   # open execution (default)
```

The deploy script configures exact role sets: proposers receive `PROPOSER_ROLE`, cancellers receive `CANCELLER_ROLE`, and executors receive `EXECUTOR_ROLE` (`address(0)` means open execution). Proposers and cancellers must be two disjoint sets — the script reverts on any overlap — and the `CANCELLER_ROLE` auto-granted to proposers by the OZ constructor is always revoked. The deployer's transient `DEFAULT_ADMIN_ROLE` is renounced in the same broadcast, leaving the TimelockController self-administered. The script reverts if any post-deploy role or delay assertion fails, and writes a `latest.json` deployment artifact.

> **Note:** Open execution is the default and matches the production runbook — the security guarantee comes from the delay. A restricted executor set can be configured instead by passing specific `--executor` addresses.

### Setup Sequence

1. Deploy `TimelockController` via `deploy timelock` with the Proposer Safe as sole proposer, the Admin Safe as sole canceller, and open execution
2. Deploy each contract (`Loans`, `TrustedCalls`, `TrustedSpender`, `LoansExchange`) via its deploy script. The script must be run with `DEPLOY_ADMIN` and `DEPLOY_GUARDIAN` env vars set to the Admin Safe and TimelockController respectively (both non-zero and distinct from the deployer). For each contract the script then performs in the same broadcast:
   - `grantRole(GUARDIAN_ROLE, timelockControllerAddress)` — set timelock as guardian
   - `grantRole(ADMIN_ROLE, adminSafeAddress)` — grant admin to Safe
   - `revokeRole(GUARDIAN_ROLE, deployer)` — deployer gives up guardian
3. Set recovery wallets on each contract (via guardian/timelock)

### Delay Configuration

The minimum delay is set at deployment and can only be changed by the TimelockController itself (via a timelocked `updateDelay` call). Proposers can schedule a delay change by targeting `TimelockController.updateDelay(newDelay)`, but the change can only be executed after the **current** delay has passed — not the proposed new one. This prevents an attacker from shortening the delay and immediately exploiting the reduced window.

Recommended starting value: **48 hours**.

## Example Workflows

### Adding a New Trusted Call (Timelocked)

```
1. Admin Safe signers approve a Safe transaction that calls:
   TimelockController.schedule(
     target: trustedCallsAddress,
     value:  0,
     data:   abi.encodeCall(TrustedCalls.addTrustedCall, (newTarget, newSelector)),
     predecessor: bytes32(0),
     salt:   bytes32(uniqueSalt),
     delay:  172800  // 48 hours
   )

2. 48 hours pass — monitoring bots and Safe owners review the pending operation

3. Anyone calls:
   TimelockController.execute(
     target: trustedCallsAddress,
     value:  0,
     data:   abi.encodeCall(TrustedCalls.addTrustedCall, (newTarget, newSelector)),
     predecessor: bytes32(0),
     salt:   bytes32(uniqueSalt)
   )

4. TimelockController calls trustedCalls.addTrustedCall(newTarget, newSelector) as guardian
```

## Security Considerations

- **Two-tier model: guardian + admin.** All contracts use `GuardianAccessControl` (OpenZeppelin `AccessControl`). `GUARDIAN_ROLE` is for critical operations that go through the timelock. `ADMIN_ROLE` is for operational/emergency actions. Functions callable by both use the `onlyAdminOrGuardian` modifier.
- **Timelock delay is the core security guarantee.** All guardian-only operations have a public waiting period. The delay must be long enough for monitoring and response (recommended: ≥ 24 hours).
- **Admin cannot escalate to guardian.** `GUARDIAN_ROLE` is the role admin for `ADMIN_ROLE`, but admins cannot grant themselves guardian. Only existing guardians can grant or revoke guardian access.
- **On-chain last-guardian protection.** `GuardianAccessControl` disables `renounceRole` (always reverts) and blocks revoking the last remaining guardian, so the contracts can never drop to zero guardians and permanently lose guardian-gated functions.
- **Recovery wallet prevents `rescueTokens` abuse.** Even if a timelocked `rescueTokens` call executes, funds go to the pre-set recovery wallet — not the attacker's address.
- **Open execution by default.** `address(0)` is granted `EXECUTOR_ROLE` at deploy time, so anyone can trigger execution after the delay — this is safe because the security comes from the delay, not from who presses the button. A restricted executor set can be configured at deploy time instead if tighter control is needed.
- **Self-administered TimelockController.** The `DEFAULT_ADMIN_ROLE` on the TimelockController is held by the TimelockController itself, meaning its own role changes must also go through the timelock.

## References

- [OpenZeppelin TimelockController](https://docs.openzeppelin.com/contracts/5.x/api/governance#TimelockController)
- [Gnosis Safe](https://docs.safe.global/)
