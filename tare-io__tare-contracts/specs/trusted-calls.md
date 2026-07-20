# TrustedCalls Module Specification

## Overview

A Safe module that enables delegates to execute whitelisted functions on behalf of Safe accounts without requiring multisig approval. This module maintains a global registry of trusted function calls that can be executed by Safe-specific delegates, enabling fast day-to-day operations while protecting high-risk transactions with a multisig.

![Overview of overall smart account spec](./Authentication_Safe.svg)

## Core Concepts

### Delegate Management

- Each Safe can have multiple delegates
- Delegates are authorized to execute trusted calls on behalf of their assigned Safe
- Only Safe owners and guardians can add delegates
- Safe owners, admins, and guardians can remove delegates

### Trusted Calls Model

- Trusted calls are globally whitelisted function selectors
- Each call is identified by: `(contractAddress, functionSelector)`
- All delegates across all Safes can execute any trusted call
- Only admins can add/remove trusted calls

### Multi-Safe Architecture

- Single module instance serves multiple Safes
- Trusted calls are shared across all Safes
- Each Safe maintains its own delegate list

### Default Whitelisted Calls

The deployment script (`DeploySmartAccountsLibrary`) registers the following functions as trusted calls. These are the operations that delegates (hot wallets) can execute on behalf of Safes without requiring multisig approval.

**Loans contract (14 calls):**

| Function                 | Purpose                                            |
| ------------------------ | -------------------------------------------------- |
| `create`                 | Create a new loan                                  |
| `accrue`                 | Record interest/fee accrual                        |
| `fund`                   | Pull investor capital into the loan                |
| `disburse`               | Disburse funded capital to borrower                |
| `pay` | Record and pull a borrower payment                 |
| `applyWaterfall`         | Allocate payment across fee/interest/principal     |
| `servicerWithdraw`       | Withdraw servicer fees                             |
| `investorWithdraw`       | Withdraw investor principal and interest           |
| `originatorWithdraw`     | Withdraw originator fees                           |
| `updateLoanData`         | Update loan status and dates                       |
| `chargeMiscFee`          | Charge a miscellaneous fee to borrower             |
| `createLedgerEntries`    | Create internal ledger corrections                 |
| `refundBorrower`         | Refund overpayments to borrower                    |
| `returnFunds`            | Return funds from servicer to loan                 |

**LoansExchange contract (3 calls):**

| Function      | Purpose                          |
| ------------- | -------------------------------- |
| `createOffer` | Create a loan sale/purchase offer|
| `acceptOffer` | Accept an existing offer         |
| `cancelOffer` | Cancel an existing offer         |

**PortfolioVault contract (13 calls):**

| Function               | Purpose                                             |
| ---------------------- | --------------------------------------------------- |
| `updateNav`            | Update on-chain NAV with new factors                |
| `collectCashflows`     | Collect loan cashflows into the vault               |
| `acceptSaleOffer`      | Buy a loan bundle by accepting an exchange offer    |
| `createSaleOffer`      | List vault-owned loan NFTs for sale on the exchange |
| `cancelSaleOffer`      | Cancel a sale offer previously created by the vault |
| `requestDeposit`       | Submit an async deposit request for a controller    |
| `deposit`              | Claim an approved deposit (3-arg ERC-7540 overload) |
| `approveDeposit`       | Approve a pending deposit at the current price      |
| `cancelDepositRequest` | Cancel a pending deposit and return assets          |
| `requestRedeem`        | Submit an async redeem request for a controller     |
| `redeem`               | Claim an approved redemption (3-arg ERC-7540 overload) |
| `approveRedemption`    | Approve a pending redemption at the current price   |
| `cancelRedeemRequest`  | Cancel a pending redeem and return shares           |

The async deposit/redeem calls are safe to whitelist even though delegates are shared across all
Safes because every path can only move value to an address holding `SHAREHOLDER_ROLE`:

- Asset payouts (`redeem`, `cancelDepositRequest`) call `_requireInvestor(receiver)`, which reverts
  unless `receiver` holds `SHAREHOLDER_ROLE`.
- Share payouts (`deposit`, `cancelRedeemRequest`) transfer the share token, whose `_update` hook
  reverts on any recipient lacking `SHAREHOLDER_ROLE`.
- Request functions (`requestDeposit`, `requestRedeem`) only move assets/shares *into* the vault and
  credit a `controller` that must hold `SHAREHOLDER_ROLE`.
- `approveDeposit` / `approveRedemption` are `INVESTOR_MANAGER`-gated and never transfer to an
  external address (they mint to / burn from the vault and shuffle pending→claimable).

`SHAREHOLDER_ROLE` is administered by `WHITELISTER_ROLE` (see `VaultShareToken`), which is itself on
the never-whitelist list, so a compromised delegate cannot enrol an attacker-controlled address.
The residual risk is limited to redistribution and griefing *within* the trusted shareholder set
(e.g. sending a claim to a different whitelisted shareholder, or locking/cancelling pending
requests) — value can never leave the whitelisted set. The 2-arg `deposit`/`mint`/`withdraw`
overloads, which would move value to an unchecked recipient, are intentionally left off the
whitelist and revert unconditionally on-chain regardless.



### Functions That Must Never Be Whitelisted

The following categories of functions must never be added as trusted calls. Whitelisting any of these would allow a compromised delegate to escalate privileges or extract funds unilaterally.

**ERC20 token operations:**
- `IERC20.approve` / `IERC20.increaseAllowance` — would let a delegate grant arbitrary spenders access to the Safe's token balance
- `IERC20.transfer` — would let a delegate send tokens to any address

**Address book and role management (Loans):**
- `registerAddress` / `unregisterAddress` — would let a delegate add attacker-controlled addresses as trusted borrowers, investors, or servicers
- `approveOriginator` / `removeOriginator` — would let a delegate authorize malicious originators
- `approveServicer` / `removeServicer` — would let a delegate authorize malicious servicers

**Access control:**
- `grantRole` / `revokeRole` / `renounceRole` — would let a delegate modify admin/guardian permissions
- `transferOwnership` — would let a delegate seize ownership of contracts

**Safe management:**
- `addOwnerWithThreshold` / `removeOwner` / `changeThreshold` — would let a delegate take over the Safe itself
- `enableModule` / `disableModule` — would let a delegate install malicious modules or remove security modules
- `setGuard` — would let a delegate remove transaction guards

**NFT operations (LoansNFT):**
- `transferFrom` / `safeTransferFrom` — would let a delegate reassign loan ownership, redirecting future cashflows
- `approve` / `setApprovalForAll` — would let a delegate authorize an arbitrary spender to pull NFTs out of the Safe later (equivalent attack to direct transfer)
- `lock` — would let a delegate lock a loan NFT to an attacker, who can then drain proceeds via `investorWithdraw` (the locked-batch route sends funds to the unlocker)

**TrustedCalls / TrustedSpender self-management:**
- `addDelegate` / `removeDelegate` (both modules) — would let a delegate add additional attacker-controlled delegates (privilege escalation) or remove legitimate ones (operational denial-of-service). Delegate management must always require multisig
- `setAllowance` (TrustedSpender) — would let a delegate authorize transfers to arbitrary recipients with arbitrary amounts, defeating the entire purpose of the pre-approved recipient list

**PortfolioVault (ERC-7540):**
- `setOperator` — would let a delegate authorize an attacker as the Safe's operator on the vault, granting them control over deposit/redeem/mint/withdraw flows on behalf of the Safe

**Contract dependency / wiring setters:**
- `Loans.setLoansNFT` — would let a delegate point the loans contract at a malicious NFT implementation, breaking ownership accounting
- `PortfolioVault.setCalculator` — would let a delegate redirect NAV computation to an attacker-controlled oracle returning arbitrary values
- `PortfolioVault.setLoans` / `setExchange` — would let a delegate swap protocol dependencies for attacker-controlled contracts that fake balances, cashflows, or settlement
- `VaultShareToken.setVault` — would let a delegate point the share token at a malicious vault, allowing arbitrary mint/burn of shares
- `PortfolioVault.setMaxNavAge` / `setMaxNavComputationTime` — would let a delegate weaken NAV freshness guards, enabling stale-NAV attacks on async deposits/redeems

These are typically gated by `GUARDIAN_ROLE` on-chain, but must never be added as trusted calls regardless: whitelisting them shifts a multisig-gated configuration change into a single-delegate action.

**General principle:** any function that is rarely needed, can be deferred to a multisig without operational impact, or whose misuse could result in unbounded loss, privilege escalation, or redirection of funds, **must not be whitelisted** — even if it is not explicitly listed above. The categories above are illustrative, not exhaustive: when in doubt, leave it off the whitelist.

## Data Structures

```solidity
// Inherits from GuardianAccessControl (OpenZeppelin AccessControl)
contract TrustedCalls is Rescuable {
    // safe => delegate => isDelegate
    mapping(address => mapping(address => bool)) public delegates;

    // Trusted calls registry (global)
    // Key: keccak256(abi.encodePacked(contractAddress, functionSelector))
    mapping(bytes32 => bool) public trustedCalls;

}
```

### Roles & Permissions

The contract inherits `GuardianAccessControl` (via `Rescuable`) which provides OpenZeppelin `AccessControl` with an at-least-one-guardian invariant enforced on-chain (`renounceRole` always reverts and the last remaining guardian cannot be revoked).

| Role             | Permissions                                                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| `GUARDIAN_ROLE`  | `addTrustedCall`, `addTrustedCalls`, `removeTrustedCall`, `pause`, `unpause`, `rescueERC20Tokens`, `rescueERC721Tokens`, `setRecoveryAddress` |
| `ADMIN_ROLE`     | `removeTrustedCall`, `pause`                                                                         |
| `PAUSER_ROLE`    | `pause` only — least-privilege incident-response role                                                |
| Safe or Guardian | `addDelegate` (per-Safe delegate management)                                                         |
| Safe or Admin    | `removeDelegate` (per-Safe delegate management)                                                      |
| Delegate         | `executeTrustedCall`, `executeTrustedCallBatch` (must be registered delegate for the target Safe)     |

**Role Admin Hierarchy**:

| Role            | Role Admin                          |
| --------------- | ----------------------------------- |
| `GUARDIAN_ROLE` | `GUARDIAN_ROLE` (self-administered) |
| `ADMIN_ROLE`    | `GUARDIAN_ROLE`                     |
| `PAUSER_ROLE`   | `GUARDIAN_ROLE`                     |

## Core Functions

### Pause Restrictions

The contract inherits OZ `Pausable` via `GuardianAccessControl`. When paused, execution and registration functions revert with `EnforcedPause()`. Admin, guardian, or pauser can pause; only guardian can unpause.

**Functions blocked when paused** (`whenNotPaused`):

- `executeTrustedCall` — Single trusted call execution
- `executeTrustedCallBatch` — Batch trusted call execution
- `addTrustedCall` — Adding to the trusted registry
- `addTrustedCalls` — Batch adding to the trusted registry
- `rescueERC20Tokens` — ERC20 recovery (inherited from `Rescuable`)
- `rescueERC721Tokens` — ERC721 recovery (inherited from `Rescuable`)
- `pause` — Pausing the contract (admin, guardian, or pauser; reverts if already paused)

**Functions NOT paused** (administrative, always operational):

- `removeTrustedCall` — Removing from the trusted registry
- `addDelegate` — Adding a delegate for a Safe
- `removeDelegate` — Removing a delegate from a Safe
- `setRecoveryAddress` — Setting rescue destination
- `setRoleAdmin` — Role hierarchy configuration
- `grantRole` / `revokeRole` — OZ AccessControl role management (`renounceRole` is disabled and always reverts)

**Only callable when paused**:

- `unpause` — Unpausing the contract (guardian only)

#### pause

```solidity
function pause() external // requires admin, guardian, or pauser
```

**Purpose**: Pause all trusted call executions
**Behavior**:

- Calls OZ `Pausable._pause()`, emitting `Paused(address account)`
- All `executeTrustedCall`, `executeTrustedCallBatch`, `addTrustedCall`, and `addTrustedCalls` calls will revert with `EnforcedPause()` while paused
- Administrative functions (delegates, trusted call removal) remain functional

#### unpause

```solidity
function unpause() external onlyRole(GUARDIAN_ROLE)
```

**Purpose**: Resume trusted call executions
**Behavior**:

- Calls OZ `Pausable._unpause()`, emitting `Unpaused(address account)`

### Delegates

#### addDelegate

```solidity
function addDelegate(address safe, address delegate) external safeOrGuardian(safe)
```

**Purpose**: Add a delegate for a Safe account
**Parameters**:

- `safe`: The Safe account address
- `delegate`: Address to authorize as delegate

#### removeDelegate

```solidity
function removeDelegate(address safe, address delegate) external safeOrAdmin(safe)
```

**Purpose**: Remove a delegate from a Safe account
**Parameters**:

- `safe`: The Safe account address
- `delegate`: Address to remove as delegate

### Trusted Calls Management

#### addTrustedCall

```solidity
function addTrustedCall(address target, bytes4 selector) external onlyRole(GUARDIAN_ROLE)
```

**Purpose**: Add a function to the trusted calls registry

**Parameters**:

- `target`: Contract address containing the function
- `selector`: 4-byte function selector

**Validation**:

- `selector` must not be `bytes4(0)` (reverts with `InvalidSelector()`)

**Behavior**:

- Computes key as `keccak256(abi.encodePacked(target, selector))`
- Sets `trustedCalls[key] = true`
- Available to all delegates across all Safes

#### removeTrustedCall

```solidity
function removeTrustedCall(address target, bytes4 selector) external // requires admin or guardian
```

**Purpose**: Remove a function from the trusted calls registry

**Parameters**:

- `target`: Contract address
- `selector`: Function selector to remove

**Behavior**:

- Computes key as `keccak256(abi.encodePacked(target, selector))`
- Sets `trustedCalls[key] = false`

### executeTrustedCall

```solidity
function executeTrustedCall(
    address safe,
    address target,
    bytes calldata data
) external returns (bool success, bytes memory returnData)
```

**Purpose**: Execute a trusted call on behalf of a Safe

**Parameters**:

- `safe`: Safe account to execute from
- `target`: Target contract address
- `data`: Encoded function call data (complete calldata including selector + parameters)

**Authorization**:

- `msg.sender` must be a delegate of the specified Safe

**Calldata Validation**:
The function decodes the `data` parameter to verify the call is trusted:

1. **Extract selector**: `bytes4 selector = bytes4(data[:4])`
   - Takes the first 4 bytes of the calldata
   - This is the function selector (keccak256 hash of function signature, truncated to 4 bytes)
2. **Compute trust key**: `bytes32 key = keccak256(abi.encodePacked(target, selector))`
   - Combines target contract address with function selector
   - Creates unique identifier for this specific function on this specific contract
3. **Check trust registry**: `require(trustedCalls[key], "Call not trusted")`
   - Verifies this function has been whitelisted by an admin

**Safe Module Execution**:
After validation, the module executes the transaction via Safe's module interface:

```solidity
IModuleManager(payable(safe)).execTransactionFromModuleReturnData(
    target,           // to: destination contract
    0,                // value: no ETH sent
    data,             // data: full calldata (selector + params)
    Enum.Operation.Call  // operation: regular call (not delegatecall)
)
```

This method:

- Bypasses Safe's normal signature requirements (module is pre-authorized)
- Executes the transaction from the Safe's address
- Returns success status and any return data from the target function

**Full Execution Flow**:

1. Check contract is not paused
2. Verify `msg.sender` is a delegate of the specified `safe`
3. Extract function selector from first 4 bytes of `data`
4. Verify target+selector combination is in trusted calls registry
5. Call `execTransactionFromModuleReturnData` on the Safe to execute the transaction
6. Return success status and any return data

### executeTrustedCallBatch

```solidity
function executeTrustedCallBatch(
    address safe,
    address[] calldata targets,
    bytes[] calldata data
) external returns (bytes[] memory results)
```

**Purpose**: Execute multiple trusted calls on behalf of a Safe in a single transaction. Reverts atomically if any call fails.

**Parameters**:

- `safe`: Safe account to execute from (shared across all calls)
- `targets`: Array of target contract addresses, one per call
- `data`: Array of encoded function call data, one per call (each includes selector + parameters)

**Authorization**:

- `msg.sender` must be a delegate of the specified Safe (checked once)
- `targets` and `data` arrays must have equal length
- At least one call must be provided

**Full Execution Flow**:

1. Check contract is not paused
2. Verify `msg.sender` is a delegate of the specified `safe`
3. Verify `targets` and `data` have matching lengths
4. Verify batch is non-empty
5. For each call:
   a. Extract function selector from first 4 bytes of `data[i]`
   b. Verify `targets[i]` + selector combination is in trusted calls registry
   c. Call `execTransactionFromModuleReturnData` on the Safe
   d. Require success (revert entire batch on failure)
   e. Store return data in `results[i]`
6. Return array of return data from each call

### Public Getters

#### isTrustedCall

```solidity
function isTrustedCall(address target, bytes4 selector) external view returns (bool)
```

**Purpose**: Check if a function is trusted

**Parameters**:

- `target`: Contract address
- `selector`: Function selector

**Returns**: True if the function is trusted

#### getTrustKey

```solidity
function getTrustKey(address target, bytes4 selector) public pure returns (bytes32)
```

**Purpose**: Compute the trust registry key for a target/selector combination

**Parameters**:

- `target`: Contract address
- `selector`: Function selector

**Returns**: The keccak256 hash used as the key in the trustedCalls mapping

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

### Authorization Checks

```solidity
// For guardian-only functions - inherited from GuardianAccessControl
onlyRole(GUARDIAN_ROLE)

// For admin-or-guardian functions
onlyAdminOrGuardian  // modifier on function signature

// For Safe-specific functions (adding delegates)
modifier safeOrGuardian(address safe) {
    require(msg.sender == safe || hasRole(GUARDIAN_ROLE, msg.sender), "Unauthorized");
    _;
}

// For Safe-specific functions (removing delegates — defensive action, admin allowed)
modifier safeOrAdmin(address safe) {
    require(msg.sender == safe || _isAdminOrGuardian(msg.sender), "Unauthorized");
    _;
}
```

### Delegate Verification

```solidity
require(delegates[safe][msg.sender], "Not a delegate");
```

### Trusted Call Verification

```solidity
bytes4 selector = bytes4(data[:4]);
bytes32 key = keccak256(abi.encodePacked(target, selector));
require(trustedCalls[key], "Call not trusted");
```

### Module Execution

The contract uses Safe's module pattern for executing transactions:

- Module is enabled on Safe via `enableModule()`
- Module calls `Safe.execTransactionFromModule()` to execute transactions
- Safe trusts the module to validate and execute appropriately

## Events

```solidity
event DelegateAdded(address indexed safe, address indexed delegate);
event DelegateRemoved(address indexed safe, address indexed delegate);
event TrustedCallAdded(address indexed target, bytes4 selector);
event TrustedCallRemoved(address indexed target, bytes4 selector);
event Paused(address indexed by);
event Unpaused(address indexed by);
```

## Installing the Module on a Safe

### Prerequisites

- Safe must be deployed and operational
- Module must be deployed
- Transaction must be signed by Safe threshold of owners

### Method 1: Direct Contract Call

To enable a module, the Safe owners must execute a transaction calling `enableModule` on the Safe:

```solidity
// Function signature
function enableModule(address module) external authorized

// Example transaction data
bytes memory data = abi.encodeWithSignature("enableModule(address)", moduleAddress);

// Execute via Safe (requires owner signatures)
safe.execTransaction(
    address(safe),           // to: Safe itself
    0,                       // value: 0
    data,                    // data: enableModule call
    Enum.Operation.Call,     // operation type
    0,                       // safeTxGas
    0,                       // baseGas
    0,                       // gasPrice
    address(0),              // gasToken
    payable(0),              // refundReceiver
    signatures               // owner signatures
);
```

### Method 2: Using Safe Transaction Builder

1. Go to Safe Web UI
2. Navigate to Apps → Transaction Builder
3. Create new transaction with:
   - **To Address**: Your Safe address
   - **ABI**: Safe ABI (or paste function signature)
   - **Function**: `enableModule`
   - **module (address)**: Module contract address
4. Create and sign transaction with required owners
5. Execute once threshold is reached

### Verification

After installation, verify the module is enabled:

```solidity
// Check if module is enabled
bool isEnabled = safe.isModuleEnabled(moduleAddress);

// Get list of all enabled modules
address[] memory modules = safe.getModulesPaginated(SENTINEL_MODULES, 10);
```

### Removing a Module

To disable a module (requires owner signatures):

```solidity
safe.execTransaction(
    address(safe),
    0,
    abi.encodeWithSignature("disableModule(address,address)", prevModule, moduleAddress),
    Enum.Operation.Call,
    // ... gas parameters and signatures
);
```

Note: `prevModule` is the previous module in the linked list (or `SENTINEL_MODULES` if first).

## Example Usage

### Complete Setup Flow

```solidity
// 1. Deploy module with initial admin
TrustedCallsModule module = new TrustedCallsModule();
module.rely(adminAddress);

// 2. Admin adds trusted function calls
module.addTrustedCall(
    loansContract,      // target
    0x12345678         // example
);

module.addTrustedCall(
    loansContract,
    0x87654321         // example
);

// 3. Enable module on Safe (requires owner signatures)
// This is done via one of the methods described above
// For example, using direct call:
bytes memory enableData = abi.encodeWithSignature("enableModule(address)", address(module));
safe.execTransaction(
    address(safe),
    0,
    enableData,
    Enum.Operation.Call,
    // ... signatures from Safe owners
);

// 4. Safe adds a delegate (requires owner signatures)
safe.execTransaction(
    address(module),
    0,
    abi.encodeWithSignature("addDelegate(address,address)", address(safe), hotWallet),
    Enum.Operation.Call,
    // ... signatures from Safe owners
);
```

### Execution Phase

```solidity
// Delegate executes trusted call
vm.prank(hotWallet);
module.executeTrustedCall(
    safeAddress,
    loansContract,
    abi.encodeWithSignature("recordPayment(uint256,uint256)", loanId, amount)
);

// This would fail - function not trusted
vm.prank(hotWallet);
module.executeTrustedCall(
    safeAddress,
    loansContract,
    abi.encodeWithSignature("withdrawFunds()")  // Reverts: "Call not trusted"
);

// This would fail - not a delegate
vm.prank(randomAddress);
module.executeTrustedCall(
    safeAddress,
    loansContract,
    abi.encodeWithSignature("recordPayment(uint256,uint256)", loanId, amount)
    // Reverts: "Not a delegate"
);
```

## References

- [Safe Module Documentation](https://docs.safe.global/advanced/smart-account-modules)
- [Safe Module Tutorial](https://docs.safe.global/advanced/smart-account-modules/smart-account-modules-tutorial)
- Authorization Pattern (Tare Contracts)
