# Solidity Style Guide

This style guide builds on top of [Solidity’s official style guide](https://docs.soliditylang.org/en/latest/style-guide.html). We expect all smart contract code to follow the official style guide, with the additional guidelines outlined below overriding the official guide where applicable.

# Code Layout

## Indentation

Use 2 spaces per indentation level.

## Pragma & Solidity Compiler Version

Make sure all Solidity files use the right SPDX License Identifier.
Source files written by Tare must **all** use the **same, locked** version pragma. The current version is `0.8.33` — update this value when upgrading the compiler.

## Imports

Use a blank between imports internal to the codebase and external dependencies.

Use named imports.

✅:

```solidity
import {MyContract} from "contracts/MyContract.sol";
```

❌:

```solidity
import "../MyContract.sol";
```

## Declarations in Contracts vs Interfaces

Declarations of the following must be done in an Interface:

- Events
- Structs
- Enums
- Errors

## Order of elements

Inside a Contract, elements should be laid out in the following order:

- Library imports (e.g `using WadRayMath for uint256;`)
- State variables, grouped by visibility and mutability (`constant` and `immutable` should precede standard state variables)
- Modifiers
- Constructor
- Other functions

## Function Ordering

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.33;
contract A {
    constructor() {
        // ...
    }

    receive() external payable { // if exists
        // ...
    }

    fallback() external { // if exists
        // ...
    }

    // External functions
    // ...

    // Public functions
    // ...

    // Internal functions
    // ...

    // Private functions
    // ...
}
```

Within each of these visibility groups, `view` and `pure` functions should be placed at the end.

# Comments

Comments should provide any additional context and motivation - the WHY - especially when it’s not necessarily obvious from the code itself. As an exception, long tests can benefit from inline comments to detail steps for example.
Comments on functions should gives a brief description of the purpose of the function.

The following elements must have [NatSpec comments](https://docs.soliditylang.org/en/latest/natspec-format.html):

- Functions, **regardless of their visibility**
- Contracts
- Modifiers

Additionally, the following can be decorated with NatSpec comments if necessary:

- Events
- Errors

NatSpec comments should be preferably written in Interfaces, with elements in contracts inheriting the comment from them using `@inheritdoc`.

Use double-asterisk block comments (`/** ... */`) instead of triple slashes (`/// ...`) for multi-line NatSpec. Single-line NatSpec may use triple slashes — especially for `/// @inheritdoc ...` and other one-tag comments.

✅:

```solidity
/// @inheritdoc IExample
function set(uint x) public returns (uint previous) { ... }

/// @notice The underlying asset token used to settle deposits.
IERC20 public immutable assetToken;
```

✅:

```solidity
/**
 * @notice Store `x`.
 * @param x the new value to store
 * @return previous the previous value of `storedData`
 * @dev updates the state variable `storedData` and returns the previous value
 */
function set(uint x) public returns (uint previous) {
   previous = storedData;
   storedData = x;
}

```

❌:

```solidity
/// @notice Store `x`.
/// @param x the new value to store
/// @return previous the previous value of `storedData`
/// @dev updates the state variable `storedData` and returns the previous value
function set(uint x) public returns (uint previous) {
    previous = storedData;
    storedData = x;
}
```

Use inline comments (// …) in the body of functions when needed.

Assembly/Yul code must include comments.

# Naming Conventions

## Naming Standards

| Component             | Convention                                  | Example                |
| --------------------- | ------------------------------------------- | ---------------------- |
| Contracts & Libraries | PascalCase (CapWords)                       | `VaultManager.sol`     |
| Interfaces            | I + PascalCase                              | `IVault.sol`           |
| Events                | PascalCase (Past Tense, subjectVerb format) | `AssetDeposited`       |
| Errors                | PascalCase                                  | `InsufficientBalance`  |
| Functions             | camelCase (mixedCase)                       | `executeLiquidation()` |
| State Variables       | camelCase                                   | `totalAssets`          |
| Constants             | ALL_CAPS_UNDERSCORE                         | `MAX_LOAN_TO_VALUE`    |
| Modifiers             | camelCase                                   | `onlyAuthorized`       |

If there's a naming conflict between variables, for example if `loans` is already taken, and the declaration of a local variable with the same name would shadow another declaration then an underscore should pre-pended to the name to differentiate the two (i.e `loans_`);

## Mappings

Provide the key name and value name in mappings:

✅:

```solidity
mapping(uint64 loanId => address borrower) public borrowers;
```

❌:

```solidity
	// loanId => borrower address
	mapping(uint64 => address) public borrowers;
```

## Named arguments

Prefer passing the name of arguments explicitly for clarity.

✅:

```solidity
	_createInternalEntry({
		loanId: loanId,
		from: ACC_CASH,
		to: ACC_UNFUNDED_COMMITMENT
	})
```

❌:

```solidity
	_createInternalEntry(
		loanId,
		ACC_CASH,
		ACC_UNFUNDED_COMMITMENT
	)
```

## Function Parameter Ordering

Place the primary entity identifier first (e.g., `loanId`), followed by core parameters, and callback/ref/metadata parameters last.

✅:

```solidity
function accrue(uint64 loanId, int128 amount, uint48 timestamp, bytes32 ref) external;
```

❌:

```solidity
function accrue(int128 amount, bytes32 ref, uint64 loanId, uint48 timestamp) external;
```

## Naming Prefix of Non-External Elements

Internal and private functions must be prefixed with an underscore (\_).

✅:

```solidity
  uint256 internal _totalSupply;
  function _calculateFee(uint256 amount) internal returns (uint256) {
    // ...
  }
```

❌:

```solidity
uint256 internal totalSupply;
function calculateFee(uint256 amount) internal returns (uint256) {
    // ...
}
```

## Tests

### Test Contracts

Test contracts should use the following naming convention: `<ContractName>_<FunctionBeingTested>Test`

### Test Functions

Test functions should be named using the following format: `test_FunctionName_Outcome_OptionalContext` and `test_FunctionName_Reverts_Context` when the function is expected to revert.

✅:

```solidity
function test_CreateLoan_Reverts_WhenOriginatorNotApproved() public { ... }
function test_Accrue_IsCallableAsServicer() public { ... }
```

❌:

```solidity
function testCreateLoanRevertsWhenoriginatornotapproved() public { ... }
function test_accrueIsCallableAsServicer() public { ... }
```

**Use variables for values in tests.**

✅:

```solidity
 loans.applyWaterfall(loanId, miscFee, SERVICER_FEE, INVESTOR_INTEREST, PRINCIPAL_REPAYMENT, timeNow, REF);
```

❌:

```solidity
 loans.applyWaterfall(loanId, 0, 10e6, 345e6, 879230000000000, uint48(block.timestamp), "");
```

### File Size & Organization

Split long test files at around 600 lines. One file per logical feature area or function, not one massive file.

When two functions share most of their behavior (e.g. `acceptOffer` / `acceptOfferUnchecked`), use an abstract base contract with a virtual `_doAction()` method. Write shared tests once in the abstract contract and override in concrete contracts for variant-specific behavior.

### Test Setup & Helpers

Use `setUp()` and helper functions to eliminate duplicated setup lines across tests. Helpers use underscore prefix: `_createActiveLoan()`, `_setupInitialNav()`. Provide overloads with sensible defaults.

✅:

```solidity
function _setupInitialNav() internal {
  _setupInitialNav(DEFAULT_LOAN_VALUATION);
}
```

### Assertions

Always assert against exact expected values. Prefer `assertEq(x, EXPECTED_VALUE)` over `assertTrue(x > 0)` or `assertTrue(x != 0)`.

Expect specific custom errors — never bare `vm.expectRevert()` unless the revert comes from a third-party contract whose error isn't importable.

✅:

```solidity
vm.expectRevert(ILoansExchange.InvalidBuyer.selector);
```

❌:

```solidity
vm.expectRevert();
```

When testing events, use `vm.expectEmit` with the full event signature and expected parameters.

### Fuzz Testing

Prefer fuzz inputs when the function accepts a range of values. Use `bound()` to constrain ranges and `vm.assume()` to skip invalid states. Test the widest reasonable input range. Define a `MAX_FUZZ_AMOUNT` constant to cap values that could overflow in intermediate math.

✅:

```solidity
function test_AsyncDeposit_FullHappyPath(uint256 depositAmount, uint256 loanValuation) public {
  depositAmount = bound(depositAmount, 1, MAX_FUZZ_AMOUNT);
  loanValuation = bound(loanValuation, 0, MAX_FUZZ_AMOUNT);
  _setupInitialNav(loanValuation);
  _assumeNonZeroShares(depositAmount);
  // ...
}
```

### Access Control

For role-gated functions, test the authorized role(s) and at least one unauthorized caller separately. Test admin override separately when an admin bypass exists.

### State Verification

After state-changing operations, assert the full resulting state (balances, mappings, counters) — not just the return value. For multi-step async flows (request → approve → claim), verify intermediate state at each step.

### Invariant Testing

Use test modifiers to enforce cross-cutting invariants automatically. The modifier runs the test body via `_;` then asserts the invariant.

✅:

```solidity
modifier accountingEquationHolds() {
  _;
  assertEq(_getLoanTotalBalance(loanId), 0, "Accounting equation violated");
}

function test_Fund_CreatesCorrectEntry() public accountingEquationHolds { ... }
```

# Errors

Use custom errors instead of strings:

✅:

```solidity
	require(msg.sender == safe, UnauthorizedCaller());
```

❌:

```solidity
	require(msg.sender == safe, "TrustedCalls: unauthorized");
```

# Modifiers

Modifiers are helpful to avoid duplicated code. They improve readability. As such, do not create a modifier if it is only used in one place; especially when the content of the modifier is a one-liner: what could be 1 line of code turns into 5.

# Misc.

- Use underscores for large integers that are at least 4 figures (e.g 10000 ⇒ 10_000)
- Prefer scientific notation for values such as USDC amounts (e.g 45890000 ⇒ 45.89e6)

## Variable initialization

It is unnecessary to provide default values when initializing a variable:

✅:

```solidity
uint256 x;
```

❌:

```solidity
uint256 x = 0;
```

# Gas-efficiency Conventions

- For functions that are only intended for external interaction, `external` is strictly preferred over `public`.
- **Struct Packing**: The order and the types of the variables within a `struct` should be chosen to minimize the number of 32-byte slots used. If variables are frequently read or written together, pack them in the same slot if possible.
- **Storage Variable Ordering**: The same slot-minimizing principle applies to contract-level state variables. Group smaller types together to pack them into fewer slots.
- Values that do not change after deployment should be marked as `immutable` or `constant` to be stored in the bytecode.
- Use a variable to store and cache the length of the array that is being iterated over in a `for` loop.
- Use `++i` instead of `i++` in loops.
- Use `calldata` for read-only external function parameters.
- When ordering `if` conditions, put the most likely paths first based on business logic.
- Reading from storage is expensive — prevent identical storage reads by caching unchanging storage slots and passing/using cached values

# Security-related Conventions

- Use the **Checks-Effects-Interactions pattern**
- Use `nonReentrant` modifier before other modifiers

## Sources of inspiration

- https://github.com/Cyfrin/solskill/blob/main/skills/solidity/SKILL.md
- https://github.com/coinbase/solidity-style-guide
