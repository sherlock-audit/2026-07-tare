# TrustedSpender Module Specification

## Overview

A minimal allowance module that enables delegates to transfer tokens (ERC20 and ERC721) from Safe accounts up to predefined limits. Allowances are defined for specific token/from/to combinations, and delegates can execute transfers within these limits. The contract uses `GuardianAccessControl` (OpenZeppelin `AccessControl`) for role-based access control.

## Core Concepts

### Delegate Management

- Each Safe can have multiple delegates
- Delegates are authorized to execute transfers on behalf of the Safe
- Only Safe owners or Guardians can add delegates and set allowances
- Safe owners, Admins, and Guardians can remove delegates

### Allowance Model

The contract supports two parallel allowance models:

**ERC20 (`Allowance`)** — per-route spending cap with expiry.

- Allowances are set for specific routes: `(token, safe, recipient)`
- Each unique combination has its own spending limit and validity period
- Infinite allowance: `type(uint208).max` (never decreases)
- Limited allowance: Decreases with each transfer
- Each `setAllowance` call fully overwrites the previous amount and `validUntil` for that route
- `validUntil` must be strictly in the future at set time (reverts with `InvalidAllowanceDeadline` otherwise)
- `validUntil = type(uint48).max` means no expiry (perpetual)
- Any other `validUntil` value requires `block.timestamp <= validUntil` at transfer time

**ERC721 (`NFTAllowance`)** — blanket per-route flag with expiry.

- Allowances are set for specific routes: `(collection, safe, recipient)`
- A single boolean `allowed` flag authorizes any tokenId of `collection` to move from `safe` to `recipient`
- No per-tokenId allowlist and no count-based cap (matches `setApprovalForAll` semantics at the route level)
- Validity semantics for `validUntil` are identical to ERC20 (must be strictly in the future at set time; `type(uint48).max` perpetual; otherwise enforced at transfer time)
- `executeNFTTransfer` moves the token with `transferFrom`, not `safeTransferFrom`. Recipients here are Safe accounts, which do not implement `onERC721Received`, so a safe transfer would revert on the receiver check — `LoansExchange` moves loan NFTs between the same accounts with a plain `transferFrom` for the same reason. The receiver check adds nothing this contract needs: the recipient is not arbitrary, it is pinned in advance by the per-route allowance, which only the owning Safe or a guardian can set.
- Revocation is done by setting `allowed = false`

## Data Structures

```solidity
// Inherits from Rescuable (which extends GuardianAccessControl)
contract TrustedSpender is Rescuable {
    struct Allowance {
        uint208 amount;    // spending limit (packs with validUntil into 1 slot)
        uint48 validUntil; // expiry timestamp (type(uint48).max = no expiry)
    }

    struct NFTAllowance {
        bool allowed;      // blanket flag covering any tokenId of the collection on this route
        uint48 validUntil; // expiry timestamp (type(uint48).max = no expiry)
    }

    // safe => delegate => isDelegate
    mapping(address => mapping(address => bool)) public delegates;

    // token => from (safe) => to (recipient) => allowance
    mapping(address token => mapping(address from => mapping(address to => Allowance))) internal _allowances;

    // collection => from (safe) => to (recipient) => NFT allowance
    mapping(address collection => mapping(address from => mapping(address to => NFTAllowance))) internal _nftAllowances;

    // Custom errors
    error ZeroAddress();
    error UnauthorizedCaller();
    error AllowanceExpired();
    error InvalidAllowanceDeadline();
    error NFTTransferNotAllowed();
}
```

### Roles & Permissions

The contract inherits `GuardianAccessControl` (via `Rescuable`) which provides OpenZeppelin `AccessControl` with an at-least-one-guardian invariant enforced on-chain (`renounceRole` always reverts and the last remaining guardian cannot be revoked).

| Role             | Permissions                                                                               |
| ---------------- | ----------------------------------------------------------------------------------------- |
| `GUARDIAN_ROLE`  | `pause`, `unpause`, `rescueERC20Tokens`, `rescueERC721Tokens`, `setRecoveryAddress`       |
| `ADMIN_ROLE`     | `pause`                                                                                   |
| `PAUSER_ROLE`    | `pause` only — least-privilege incident-response role                                     |
| Safe or Guardian | `addDelegate`, `setAllowance`, `setNFTAllowance` (per-Safe management)                    |
| Safe or Admin    | `removeDelegate` (per-Safe management — defensive action)                                 |
| Delegate         | `executeTransfer`, `executeNFTTransfer` (must be registered delegate for the source Safe) |

**Role Admin Hierarchy**:

| Role            | Role Admin                          |
| --------------- | ----------------------------------- |
| `GUARDIAN_ROLE` | `GUARDIAN_ROLE` (self-administered) |
| `ADMIN_ROLE`    | `GUARDIAN_ROLE`                     |
| `PAUSER_ROLE`   | `GUARDIAN_ROLE`                     |

## Core Functions

### Pause Restrictions

The contract inherits OZ `Pausable` via `GuardianAccessControl`. When paused, transfer execution reverts with `EnforcedPause()`. Admin, guardian, or pauser can pause; only guardian can unpause.

**Functions blocked when paused** (`whenNotPaused`):

- `executeTransfer` — Executing an ERC20 token transfer
- `executeNFTTransfer` — Executing an ERC721 transfer
- `rescueERC20Tokens` — ERC20 recovery (inherited from `Rescuable`)
- `rescueERC721Tokens` — ERC721 recovery (inherited from `Rescuable`)
- `pause` — Pausing the contract (admin, guardian, or pauser; reverts if already paused)

**Functions NOT paused** (administrative, always operational):

- `addDelegate` — Adding a delegate for a Safe
- `removeDelegate` — Removing a delegate from a Safe
- `setAllowance` — Setting ERC20 spending limits
- `setNFTAllowance` — Setting ERC721 per-route allowances
- `setRecoveryAddress` — Setting rescue destination
- `setRoleAdmin` — Role hierarchy configuration
- `grantRole` / `revokeRole` — OZ AccessControl role management (`renounceRole` is disabled and always reverts)

**Only callable when paused**:

- `unpause` — Unpausing the contract (guardian only)

#### pause

```solidity
function pause() external // requires admin, guardian, or pauser
```

**Purpose**: Pause all transfer operations
**Behavior**:

- Calls OZ `Pausable._pause()`, emitting `Paused(address account)`
- All `executeTransfer` calls will revert with `EnforcedPause()` while paused
- Administrative functions (add/remove delegates, set allowances) remain functional

#### unpause

```solidity
function unpause() external onlyRole(GUARDIAN_ROLE)
```

**Purpose**: Resume transfer operations
**Behavior**:

- Calls OZ `Pausable._unpause()`, emitting `Unpaused(address account)`
- Transfers can resume normally

### Delegates

#### addDelegate

```solidity
function addDelegate(address safe, address delegate) external safeOrGuardian(safe)
```

**Purpose**: Add a delegate for a Safe account
**Parameters**:

- `safe`: The Safe account address
- `delegate`: Address to authorize as delegate

**Validation**:

- `safe` must not be zero address
- `delegate` must not be zero address
- Reverts with `ZeroAddress()` if either is zero

#### removeDelegate

```solidity
function removeDelegate(address safe, address delegate) external safeOrAdmin(safe)
```

**Purpose**: Remove a delegate from a Safe account
**Parameters**:

- `safe`: The Safe account address
- `delegate`: Address to remove as delegate

### Allowances

#### setAllowance

```solidity
function setAllowance(
    address token,
    address from,
    address to,
    uint208 amount,
    uint48 validUntil
) external safeOrGuardian(from)
```

**Purpose**: Set spending limit and validity period for a specific token/from/to route

**Parameters**:

- `token`: Token address
- `from`: Safe account that holds the funds
- `to`: Recipient address that can receive funds
- `amount`: Maximum spendable amount (`type(uint208).max` for unlimited)
- `validUntil`: Timestamp until which the allowance is valid (`type(uint48).max` for no expiry)

**Validation**:

- `from` must not be zero address
- `to` must not be zero address
- `validUntil` must be strictly greater than `block.timestamp`
- Reverts with `ZeroAddress()` if `from` or `to` is zero
- Reverts with `InvalidAllowanceDeadline()` if `validUntil` is not in the future

**Behavior**:

- Stores amount and validUntil in `_allowances[token][from][to]`
- Fully overwrites any existing allowance (both amount and validUntil)

### executeTransfer

```solidity
function executeTransfer(
    address token,
    address from,
    address to,
    uint256 amount
) external
```

**Purpose**: Execute a transfer using an existing allowance

**Parameters**:

- `token`: Token to transfer
- `from`: Safe account to transfer from
- `to`: Recipient address
- `amount`: Amount to transfer

**Authorization**:

- `msg.sender` must be a delegate of the `from` Safe

**Behavior**:

1. Verify contract is not paused
2. Verify `msg.sender` is a delegate of `from`
3. Check sufficient allowance exists in `_allowances[token][from][to]`
4. Check allowance has not expired (`block.timestamp <= validUntil`)
5. If stored `allowance.amount` != `type(uint208).max`, reduce by transfer amount
6. Execute transfer using `IERC20(token).safeTransferFrom(from, to, amount)`
7. Revert if any check fails

### NFT Allowances

#### setNFTAllowance

```solidity
function setNFTAllowance(
    address collection,
    address from,
    address to,
    bool allowed,
    uint48 validUntil
) external safeOrGuardian(from)
```

**Purpose**: Set blanket NFT transfer authorization for a specific collection/from/to route.

**Parameters**:

- `collection`: ERC721 collection address
- `from`: Safe account that holds the NFTs
- `to`: Recipient address that can receive NFTs
- `allowed`: Whether delegates may transfer any tokenId of `collection` from `from` to `to`
- `validUntil`: Timestamp until which the allowance is valid (`type(uint48).max` for no expiry)

**Validation**:

- `from` and `to` must not be zero (reverts `ZeroAddress`)
- `validUntil` must be strictly greater than `block.timestamp` (reverts `InvalidAllowanceDeadline`)

**Behavior**: Fully overwrites the previous `(allowed, validUntil)` pair stored in `_nftAllowances[collection][from][to]`. Setting `allowed = false` revokes the route.

#### executeNFTTransfer

```solidity
function executeNFTTransfer(
    address collection,
    address from,
    address to,
    uint256 tokenId
) external
```

**Purpose**: Execute an ERC721 transfer using an existing NFT allowance.

**Authorization**:

- `msg.sender` must be a delegate of the `from` Safe

**Behavior**:

1. Verify contract is not paused
2. Verify `msg.sender` is a delegate of `from`
3. Check `_nftAllowances[collection][from][to].allowed == true` (reverts `NFTTransferNotAllowed` otherwise)
4. Check allowance has not expired (`block.timestamp <= validUntil`)
5. Execute transfer using `IERC721(collection).safeTransferFrom(from, to, tokenId)`

Notes:

- Uses `safeTransferFrom`, so contract recipients without an `IERC721Receiver` implementation will revert.
- Safe must have called `IERC721(collection).setApprovalForAll(TrustedSpender, true)` beforehand; otherwise the ERC721 transfer reverts in the token contract.
- The allowance state is **not** decremented on use — it remains valid until `validUntil` or until explicitly revoked.

#### getNFTAllowance

```solidity
function getNFTAllowance(
    address collection,
    address from,
    address to
) external view returns (bool allowed, uint48 validUntil)
```

**Returns**: The raw `(allowed, validUntil)` pair stored on the route (does **not** check expiry — use `isNFTTransferAllowed` for that).

#### isNFTTransferAllowed

```solidity
function isNFTTransferAllowed(address collection, address from, address to) external view returns (bool)
```

**Returns**: `true` iff `allowed == true` and `block.timestamp <= validUntil`.

### Public Getters

#### getAllowance

```solidity
function getAllowance(
    address token,
    address from,
    address to
) external view returns (uint256 amount, uint48 validUntil)
```

**Purpose**: Get allowance for a specific route

**Parameters**:

- `token`: Token address
- `from`: Safe account
- `to`: Recipient address

**Returns**: Amount (upcast to uint256) and validUntil timestamp

#### isDelegate

```solidity
function isDelegate(address safe, address delegate) external view returns (bool)
```

**Purpose**: Check if an address is a delegate for a Safe

**Parameters**:

- `safe`: Safe account address
- `delegate`: Potential delegate address

**Returns**: True if delegate is authorized for the Safe

### Admin Functions

#### rescueERC20Tokens

```solidity
function rescueERC20Tokens(address token, uint256 amount) external whenNotPaused onlyRole(GUARDIAN_ROLE) returns (uint256 rescued)
```

**Purpose**: Recover ERC20 tokens accidentally sent to this contract

**Parameters**:

- `token`: ERC20 token address to rescue
- `amount`: Maximum amount to rescue (capped at balance)

**Returns**: The actual amount of tokens rescued

**Behavior**:

- Only callable by guardian
- Transfers up to `amount` of the specified token to the recovery address
- Returns 0 if no tokens are present
- Reverts if recovery address is not set

#### rescueERC721Tokens

```solidity
function rescueERC721Tokens(address token, uint256 tokenId) external whenNotPaused onlyRole(GUARDIAN_ROLE)
```

**Purpose**: Recover an ERC721 token accidentally sent to this contract

**Parameters**:

- `token`: ERC721 token contract address
- `tokenId`: The token ID to rescue

**Behavior**:

- Only callable by guardian
- Transfers the specified NFT to the recovery address
- Reverts if recovery address is not set

## Implementation Details

### Authorization Check

```solidity
// For Safe-specific functions (adding delegates, setting allowances)
modifier safeOrGuardian(address safe) {
    require(msg.sender == safe || hasRole(GUARDIAN_ROLE, msg.sender), "Unauthorized");
    _;
}

// For Safe-specific functions (removing delegates — defensive action, admin allowed)
modifier safeOrAdmin(address safe) {
    require(msg.sender == safe || _isAdminOrGuardian(msg.sender), "Unauthorized");
    _;
}

// For admin-or-guardian functions (pause) - from GuardianAccessControl
onlyAdminOrGuardian  // modifier on function signature

// For guardian-only functions (unpause, rescue) - from AccessControl
onlyRole(GUARDIAN_ROLE)
```

### Delegate Verification

```solidity
require(delegates[from][msg.sender], "Not a delegate");
```

### Allowance Checking and Update

```solidity
Allowance storage allowance = _allowances[token][from][to];
require(allowance.amount >= amount, InsufficientAllowance());
require(block.timestamp <= allowance.validUntil, AllowanceExpired());

if (allowance.amount != type(uint208).max) {
    allowance.amount -= uint208(amount);
}
```

### Transfer Execution

The contract uses the **token approval pattern** for executing transfers:

- Safe approves this contract to spend tokens via `IERC20.approve()`
- Contract uses `transferFrom()` to move tokens from Safe to recipient

## Events

```solidity
event DelegateAdded(address indexed safe, address indexed delegate);
event DelegateRemoved(address indexed safe, address indexed delegate);
event AllowanceSet(
    address indexed token,
    address indexed from,
    address indexed to,
    uint256 amount,
    uint48 validUntil
);
event NFTAllowanceSet(
    address indexed collection,
    address indexed from,
    address indexed to,
    bool allowed,
    uint48 validUntil
);
event NFTTransferExecuted(
    address indexed collection,
    address indexed from,
    address indexed to,
    uint256 tokenId,
    address delegate
);
// Paused and Unpaused events are inherited from OZ Pausable
// event Paused(address account);
// event Unpaused(address account);
```

## Example Usage

### Setup Phase

```solidity
// Deploy with initial guardian and recovery address
TrustedSpender spender = new TrustedSpender(guardian, recoveryAddress);

// Safe owner adds a delegate (called by Safe or admin)
spender.addDelegate(safeAddress, delegateAddress);

// Safe owner sets unlimited USDC allowance to specific recipient (no expiry)
spender.setAllowance(
    usdcAddress,     // token
    safeAddress,     // from (safe)
    vendorAddress,   // to (recipient)
    type(uint208).max, // unlimited
    type(uint48).max  // no expiry
);

// Guardian can also set allowances for any Safe (with a 1-year validity for example)
vm.prank(guardianAddress);
spender.setAllowance(
    daiAddress,      // DAI token
    safeAddress,     // from
    payrollAddress,  // to
    10000e18,        // limit (10,000 DAI)
    uint48(block.timestamp + 365 days) // valid for 1 year
);
```

### Execution Phase

```solidity
// Delegate executes USDC transfer (unlimited allowance)
spender.executeTransfer(
    usdcAddress,
    safeAddress,
    vendorAddress,
    1000e6  // Allowance remains unlimited
);

// Delegate executes DAI transfer (limited allowance)
spender.executeTransfer(
    daiAddress,
    safeAddress,
    payrollAddress,
    1000e18  // Allowance reduces from 10,000 to 9,000 DAI
);

// This would fail - no allowance set for this route
spender.executeTransfer(
    usdcAddress,
    safeAddress,
    randomAddress,  // Different recipient - different allowance key
    100e6
);
```

### Emergency Pause

```solidity
// Admin detects suspicious activity
vm.prank(adminAddress);
spender.pause();

// Delegate tries to transfer - this will fail
vm.prank(delegateAddress);
spender.executeTransfer(
    usdcAddress,
    safeAddress,
    vendorAddress,
    100e6  // Reverts with "Contract is paused"
);

// Guardian can still update allowances during pause
vm.prank(guardianAddress);
spender.setAllowance(
    usdcAddress,
    safeAddress,
    vendorAddress,
    500e6,           // Reduced limit
    type(uint48).max // no expiry
);

// Admin resumes operations
vm.prank(adminAddress);
spender.unpause();

// Delegate can now transfer with new limit
spender.executeTransfer(
    usdcAddress,
    safeAddress,
    vendorAddress,
    100e6  // Success, allowance now 400e6
);
```
