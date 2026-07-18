---
name: debug-tx
description: Debug reverted onchain transactions by unwrapping Safe wrapper layers (execTransaction, TrustedCalls, MultiSend) and simulating inner calls to find the real revert reason. Use when a transaction shows "GS013", "transaction reverted", or a generic Safe revert and you need the actual custom error. Trigger on "debug tx", "debug transaction", "why did this revert", "transaction failed", "GS013", "revert reason", "debug revert".
---

# Debug Reverted Transaction

You are a specialist at diagnosing why a Safe Smart Account transaction reverted on an EVM chain.

## When to Use

- A user mentions a transaction that reverted with "GS013" or a generic "Transaction reverted"
- A user asks why a specific transaction hash failed
- A user wants to decode the inner revert reason from a Safe-wrapped transaction

## Prerequisites

The CLI tool `tare-contracts debug-tx` must be available. It is built into the `@tare-io/tare-contracts` package.

## Steps

### 1. Get the Transaction Hash

Ask the user for the transaction hash if not already provided.

### 2. Run the Debug Command

Run the CLI command in a terminal:

```bash
cd <tare-contracts-root> && pnpm tare-contracts debug-tx <txHash> --rpc-url <rpcUrl>
```

- For local Anvil: `--rpc-url http://127.0.0.1:8545` (the default)
- For JSON output: add `--json` flag before `debug-tx`

### 3. Interpret the Output

The tool outputs:

- **Call stack**: The full unwrapped call path (Safe → TrustedCalls → Target contract)
- **Revert reason**: The decoded custom error name and arguments
- **Inner calls**: For MultiSend batches, which specific call in the batch failed

### 4. Explain to the User

Translate the decoded error into a human-readable explanation. Common errors:

- `CallNotTrusted()` — The function selector is not registered as a trusted call in the TrustedCalls module
- `NotDelegateCall()` — A delegatecall was used where a regular call was expected
- `Unauthorized()` — The caller doesn't have the required role
- `InvalidStatus(current, expected)` — The loan is not in the expected state for this operation
- `InsufficientBalance(...)` — Not enough funds in the relevant account
