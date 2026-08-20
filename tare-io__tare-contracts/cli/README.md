# tare-contracts CLI

Command-line tool for deploying and managing Tare protocol contracts.

## Installation

The CLI is available as `tare-contracts` when the package is installed:

```bash
pnpm add @tare-io/tare-contracts
```

Or run directly from the repo:

```bash
pnpm tare-contracts <command>
```

## Global Options

| Option                      | Description                                                    | Default                    |
| --------------------------- | -------------------------------------------------------------- | -------------------------- |
| `--name <name>`             | Deployment name                                                | `dev`                      |
| `--chain <chain>`           | Chain name (`foundry`, `baseSepolia`, `base`, `avalancheFuji`) | —                          |
| `--root <path>`             | Project root                                                   | auto-detected              |
| `--private-key <key>`       | Deployer private key                                           | `DEPLOYER_KEY` env var     |
| `--account <name>`          | Foundry keystore account name                                  | `DEPLOYER_ACCOUNT` env var |
| `--deployer-addr <address>` | Deployer address                                               | `DEPLOYER_ADDR` env var    |
| `--json`                    | Output structured JSON to stdout                               | `false`                    |

The `--chain` and `--name` options combine to form a deployment identifier (e.g., `--chain baseSepolia --name dev` resolves to `baseSepolia-dev`).

## JSON Output

When `--json` is passed, all commands emit a single JSON object to stdout:

```json
{
  "status": "ok",
  "command": "command-name",
  "data": { ... },
  "txHash": "0x..."
}
```

On error:

```json
{
  "status": "error",
  "command": "...",
  "data": { "message": "error description" }
}
```

Progress and diagnostic output goes to stderr, keeping stdout clean for parsing.

When running through `pnpm` scripts (for example `pnpm tare-contracts ...` from the repo), `pnpm` may print script-run banner lines to stdout before the CLI JSON payload. For JSON pipelines (`jq`, etc.), use `pnpm --silent` to keep stdout parseable:

```bash
ENV=testing pnpm --silent tare-contracts --chain foundry --json <command> ... | jq ...
```

If you run the installed binary directly (`tare-contracts ...`), this `pnpm` wrapper output does not apply.

### Transaction hashes

Write commands return transaction hashes in the output:

- **Direct EOA calls** (`castSend`): single `txHash` field on the envelope.
- **Safe executions** (`safeExec`): `txHashes` array in `data`, typically containing 2 hashes (`approveHash` + `execTransaction`).
- **Nested Safe executions** (`nestedSafeExec`): `txHashes` array combining the outer Safe's hashes plus the inner `execTransaction`.
- **`setup-smart-accounts`**: each step includes its own `txHashes` array.

## Commands

### deploy

Deploy contracts to a target network.

#### `deploy local`

Deploy all contracts to a local Anvil instance.

```bash
tare-contracts deploy local [-r, --rpc-url <url>]
```

Deploys MockUSDC, Safe infrastructure, Loans, Accounts (SmartAccountFactory, TrustedCalls, TrustedSpender, Forwarder), and transfers admin. Uses the default Anvil account.

#### `deploy loans`

Deploy Loans contracts to a remote network.

```bash
tare-contracts deploy loans --chain baseSepolia --deployer-addr 0x... --private-key 0x...
```

#### `deploy accounts`

Deploy Smart Account infrastructure to a remote network.

```bash
tare-contracts deploy accounts --chain baseSepolia --deployer-addr 0x... --private-key 0x...
```

#### `deploy forwarder`

Deploy the Forwarder relay every role SA authorizes, and record it in the roles manifest so
`setup-smart-accounts` picks it up without a flag. `deploy local` already deploys one into the
accounts component, so this is for every other chain — run it before `setup-smart-accounts`.

```bash
pnpm tare-contracts --chain avalanche --name production deploy forwarder \
  --owner 0x...
```

- `--owner <address>` (required): the constructor's `initialOwner` — the address that may rotate
  authorized senders. Required so a deployment can never silently keep the deployer as owner; name
  the Admin Safe on a live chain. Must be a contract unless it is the deployer itself.
- `--sender <address...>`: the authorized sender EOA(s) the LMS relay signs with. `setAuthorizedSenders`
  is owner-only, so this is accepted only when `--owner` is the deployer; otherwise deploy without it
  and run `forwarder set-senders`.
- `--currency <address>`: the one target the Forwarder refuses to forward calls to, so a bare token
  transfer can never be relayed. Defaults to `USDC` from the loans manifest, then the config.
- Writes its own `forwarder` deployment component, which `generate-deployments` prefers over the
  accounts component's `Forwarder`, and records `forwarder` in the roles manifest. Recording will
  not clobber a different recorded address — use `manifest set forwarder` to replace one.
- The CREATE3 salt includes the package.json version; re-deploying under the same deployment name
  requires a version bump, or the create reverts with `CreateCollision`.

#### `deploy cctp-bridge`

Deploy the `CctpBridgeModule` custody module. Base mainnet only — the module's route
(Base USDC → Avalanche via CCTP v2) is hardcoded.

```bash
pnpm tare-contracts --chain base --name production deploy cctp-bridge \
  --safe 0x... \
  --mint-recipient 0x...
```

- `--safe`: the intake Safe whose USDC the module bridges (must already exist on Base).
- `--mint-recipient`: destination recipient on Avalanche. It is baked into the module as an
  immutable and a wrong value burns funds irrecoverably — verify it independently after deploy.
- Global `--chain` / `--name` flags must come **before** the `deploy cctp-bridge` subcommand.
- Requires `BASE_RPC`, `ETHERSCAN_API_KEY`, and a signer (`--account`/`DEPLOYER_ACCOUNT` plus
  `DEPLOYER_ADDR`, or `--private-key`).
- The CREATE3 salt includes the package.json version; re-deploying under the same deployment
  name requires a version bump, or the create reverts with `CreateCollision`.
- After deploy: enable the module on the Safe (threshold-gated), then run a small canary
  `bridge(0)` before routing real funds. See `specs/cctp-bridge-module.md`.

---

### setup-smart-accounts

Configure all eight role smart accounts from a manifest: Forwarder delegation, approvals, vault wiring, address-book registrations, and final ownership transition to `{ operationalManagementSafe, forwarder, guardianSafe }` with threshold `2`.

```bash
tare-contracts setup-smart-accounts \
  --chain foundry \
  --input /tmp/smart-accounts.setup.json \
  [--dry-run] \
  [--skip-preconditions] \
  --private-key 0x...
```

#### Options

- `--input <path>`: required JSON manifest containing infra safes + the eight SA addresses.
- `--dry-run`: evaluate step checks and report `dry-run`/`skipped` without sending transactions.
- `--skip-preconditions`: bypass strict bootstrap-state checks (required for re-running after partial/completed setup).
- `--final-threshold <n>`: SA threshold after the ownership transition, and the value the postcondition gate asserts each SA's threshold against (default `2`; local dev uses `1`).
- `--allow-extra-owners`: make the postcondition gate verify the expected owner set as a subset of the actual owners instead of the exact set (local dev, where the deployer stays an owner).
- `--forwarder <address>`: the relay every role SA authorizes, overriding the manifest's `forwarder`. Defaults to the roles manifest's `forwarder` (recorded by [`deploy forwarder`](#deploy-forwarder)), then `Forwarder` in the `forwarder` or `accounts` deployment component — the latter is what `deploy local` populates.
  The Forwarder takes an owner slot on every role SA, which is what lets an authorized sender confirm a Safe transaction with a `v = 1` pre-validated signature; with `--final-threshold 2` it is one required signature rather than sufficient on its own.

After a non-dry run, the command re-reads every postcondition (owners, threshold, modules, delegates, allowances, operator flags, registrations) and **fails with exit code 1** if any does not hold — a completed run never reports `ok` while a smart account is misconfigured.

#### Manifest schema

```json
{
  "operationalManagementSafe": "0x...",
  "guardianSafe": "0x...",
  "originatorSa": "0x...",
  "borrowerSa": "0x...",
  "investorSa": "0x...",
  "servicerSa": "0x...",
  "shareholderSa": "0x...",
  "portfolioManagerSa": "0x...",
  "investorManagerSa": "0x...",
  "calculatingAgentSa": "0x...",
  "offramp": "0x...",
  "forwarder": "0x..."
}
```

`offramp` and `forwarder` are optional. All other fields are required. The command validates address format, non-zero values, duplicate SA addresses, and infra-safe distinctness.

#### Phase order

1. Per-role configuration for all eight SAs (`originator`, `borrower`, `investor`, `servicer`, `shareholder`, `portfolioManager`, `investorManager`, `calculatingAgent`)
2. Originator peer registrations (`Borrower`, `Investor`, `Servicer`)
3. Ownership transition for all eight SAs

#### Main actions performed

- Common per-SA: `TrustedCalls.addDelegate(forwarder)`, `TrustedSpender.addDelegate(forwarder)`, `enableModule(TrustedCalls)`, `USDC.approve(TrustedSpender, MAX)`
- Borrower/investor/servicer: `USDC.approve(Loans, MAX)`
- Borrower (optional): `TrustedSpender.setAllowance(..., offramp, MAX)` when `offramp` is present
- Investor: `LoansNFT.setApprovalForAll(LoansExchange, true)` and `Loans.registerAddress(Investor, portfolioVault)` (the seller-side book; the buyer-side entry in the vault's book lands in the `grant-roles` Timelock batch)
- Shareholder: `USDC.approve(PortfolioVault, MAX)`, `VaultShareToken.approve(PortfolioVault, MAX)`, `PortfolioVault.setOperator(forwarder, true)`
- Originator: register borrower/investor/servicer peers in the originator SA address book
- Ownership transition: `addOwnerWithThreshold(forwarder, 1)` then `addOwnerWithThreshold(guardianSafe, 2)`

#### Output

The command returns grouped step results by category (`relayDelegation`, `moduleActivation`, `approvals`, `vaultWiring`, `disbursement`, `addressBook`, `ownership`) plus per-role verification checks.

```json
{
  "steps": {
    "approvals": [{ "step": "USDC.approve(Loans, MAX) from investor", "status": "completed", "txHashes": ["0x..."] }],
    "ownership": [{ "step": "investor.addOwnerWithThreshold(guardianSafe, 2)", "status": "skipped" }]
  },
  "verification": {
    "investor": {
      "ownerSet == {opsMgmt, forwarder, guardianSafe}": true,
      "threshold": 2,
      "Loans.isRegisteredForRole(SA, Investor, portfolioVault)": true
    }
  }
}
```

#### Re-runs

After a successful run, preconditions will fail by design (owners/threshold/allowances are already in final state). Use `--skip-preconditions` for idempotent re-runs.

---

### approve-originator

Manage approved originators on the Loans contract.

#### `approve-originator set`

```bash
tare-contracts approve-originator set --chain baseSepolia --originator 0x... --private-key 0x...
```

#### `approve-originator check`

```bash
tare-contracts approve-originator check --chain baseSepolia --originator 0x...
```

Returns `{ approved: true/false }`.

---

### create-smart-account

Deploy a new smart account via SmartAccountFactory.

```bash
tare-contracts create-smart-account \
  --chain baseSepolia \
  --owners 0xAAA,0xBBB \
  --threshold 1 \
  [--delegates 0xCCC] \
  [--currencies 0xUSDC] \
  [--trusted-recipients 0xDDD] \
  --private-key 0x...
```

Returns the deployed `smartAccountAddress` extracted from the `SmartAccountDeployed` event.

---

### address-book

Manage the Loans contract address book (role-based access control).

#### `address-book register`

Register an address for a role. Three modes:

```bash
# Direct (sender's own address book)
tare-contracts address-book register --chain baseSepolia --role Borrower --addr 0x...

# Admin on-behalf-of (registers in another address book)
tare-contracts address-book register --chain baseSepolia --role Borrower --addr 0x... --on-behalf-of 0x...

# Via Safe (sender is an owner of the Safe, registers in the Safe's address book)
tare-contracts address-book register --chain baseSepolia --role Borrower --addr 0x... --smart-account 0x...
```

**Roles:** `Borrower`, `Originator`, `Investor`, `Servicer`

#### `address-book check`

```bash
tare-contracts address-book check --chain baseSepolia --role Borrower --addr 0x... --owner 0x...
```

Returns `{ registered: true/false }`.

---

### approve-currency

Manage ERC20 currency approvals on smart accounts. Executes via `SafeExec` (sender must be an owner of the smart account).

#### `approve-currency set`

```bash
tare-contracts approve-currency set \
  --chain baseSepolia \
  --smart-account 0x... \
  [--spender 0x...] \
  [--amount <uint256>] \
  --private-key 0x...
```

- `--spender` defaults to the Loans contract address.
- `--amount` defaults to max uint256.

#### `approve-currency check`

```bash
tare-contracts approve-currency check --chain baseSepolia --smart-account 0x... [--spender 0x...]
```

Returns `{ allowance, isMaxApproval }`.

---

### forwarder

Manage the Forwarder relay after `deploy forwarder`.

#### `forwarder set-senders`

```bash
tare-contracts --chain avalanche --name production forwarder set-senders \
  --sender 0x... [--sender 0x...] \
  [--forwarder 0x...] \
  --account dp
```

- Replaces the **whole** authorized-sender set — anything omitted stops being able to relay.
- `setAuthorizedSenders` is owner-only, so the route is derived from the Forwarder's own `owner()`:
  a direct send when the signer is the owner, otherwise `SafeExec` through the owning Safe while it
  is still threshold-1. A multi-sig owner goes through the Safe UI instead.
- `--forwarder` defaults to the roles manifest, then the `forwarder`/`accounts` deployment component.
- Re-reads `isAuthorizedSender` for every sender afterwards and fails if one did not take — an
  unauthorized relayer otherwise only surfaces as every relayed call reverting.

#### `forwarder check`

```bash
tare-contracts --chain avalanche --name production forwarder check
```

Returns `{ forwarder, owner, currencyGuard, senders }`.

---

### set-allowance

Manage TrustedSpender allowances.

#### `set-allowance set`

```bash
tare-contracts set-allowance set \
  --chain baseSepolia \
  --from 0x... \
  --to 0x... \
  [--token 0x...] \
  [--amount <uint256>] \
  [--smart-account 0x...] \
  --private-key 0x...
```

- `--token` defaults to the Loans currency (USDC).
- `--amount` defaults to max uint256.
- `--smart-account` executes via Safe (for admin Safe execution).

#### `set-allowance check`

```bash
tare-contracts set-allowance check --chain baseSepolia --from 0x... --to 0x... [--token 0x...]
```

Returns `{ allowance, isMaxAllowance }`.

---

### grant-roles

Bundle the setup-time guardian role grants into a single
`TimelockController.scheduleBatch` + `executeBatch` pair, scheduled from the
Proposer Safe via `SafeExec.s.sol` and executed from the deployer EOA (open
executor).

```bash
tare-contracts grant-roles \
  --chain avalanche --name production \
  --input ./role-grants.setup.json \
  [--dry-run] \
  --account dp
```

Protocol addresses (`Loans`, `PortfolioVault`, `NavCalculator`,
`VaultShareToken`, `TimelockController`) are read from the deployment artifacts
under `deployments/<chain>/<name>/{vault,timelock}/latest.json`. The manifest
carries only deploy-specific inputs:

```json
{
  "proposerSafe": "0x...",
  "salt": "avalanche-production:setup-grants:v1",

  "originatorSa": "0x...",
  "investorSa": "0x...",
  "portfolioManagerSa": "0x...",
  "investorManagerSa": "0x...",
  "calculatingAgentSa": "0x...",
  "whitelisterSafe": "0x..."
}
```

All eight fields are required. The six grants, batched in this order:

1. `Loans.approveOriginator(originatorSa)`
2. `PortfolioVault.grantRole(PORTFOLIO_MANAGER, portfolioManagerSa)`
3. `PortfolioVault.grantRole(INVESTOR_MANAGER, investorManagerSa)`
4. `NavCalculator.grantRole(CALCULATING_AGENT, calculatingAgentSa)`
5. `VaultShareToken.grantRole(WHITELISTER_ROLE, whitelisterSafe)`
6. `PortfolioVault.registerAddress(investorSa)` — registers the investor SA as
   Investor in the vault's own Loans address book; `LoansExchange.acceptOffer`
   checks both parties' books, so without this entry every Funder → vault
   settlement reverts `SellerNotRegistered`

**Idempotent.** Before scheduling, the command checks whether all six grants
are already in place; if so it exits `0` with `{ scheduled: 0, executed: 0,
skipped: 6 }` and submits nothing. `salt` is hashed to a deterministic
`bytes32`, so a partial-failure retry must bump the salt (e.g. `:v2`) to avoid
colliding with the previous batch's operation hash.

`--dry-run` prints the encoded `scheduleBatch` calldata, the operation id, and
the validation/idempotency report without submitting transactions. It also warns
when `timelock.getMinDelay() > 0` (the grants would schedule but `executeBatch`
could not succeed until the delay elapses).

Output:

```json
{
  "status": "ok",
  "command": "grant-roles",
  "data": {
    "scheduled": 6,
    "executed": 6,
    "skipped": 0,
    "operationId": "0x...",
    "scheduleTxHash": "0x...",
    "executeTxHash": "0x..."
  }
}
```

---

### Codegen Commands

These commands are used during the build process and don't require `--chain`.

#### `extract-enums`

Extract Solidity enums and constants to `src/enums.ts`.

```bash
tare-contracts extract-enums
```

#### `generate-deployments`

Generate `src/deployments.ts` from deployment JSON artifacts.

```bash
tare-contracts generate-deployments
```

## Environment Variables

| Variable           | Description                                                 |
| ------------------ | ----------------------------------------------------------- |
| `DEPLOYER_KEY`     | Default private key for `--private-key`                     |
| `DEPLOYER_ACCOUNT` | Default keystore account for `--account`                    |
| `DEPLOYER_ADDR`    | Default deployer address for `--deployer-addr`              |
| `ANVIL_RPC`        | Anvil RPC URL (for foundry chain)                           |
| `BASE_SEPOLIA_RPC` | RPC URL for Base Sepolia                                    |
| `BASE_RPC`         | RPC URL for Base mainnet                                    |
| `FUJI_RPC`         | RPC URL for Avalanche Fuji                                  |
| `ENV`              | Set to `testing` to load `.env.testing` instead of `.env`   |
| `SOURCIFY_URL`     | If set, verify local deployments with Sourcify after deploy |

## Safe Execution

Commands that interact with Safe smart accounts use the `SafeExec.s.sol` forge script, which:

1. Reads the Safe's current nonce
2. Computes the transaction hash via `getTransactionHash`
3. Calls `approveHash` on the Safe
4. Calls `execTransaction` with the approved-hash signature

This requires the `--private-key` signer to be an owner of the target Safe.

For **nested Safe execution** (e.g., the Ops Mgmt Safe owns a SmartAccount), the CLI:

1. Uses `SafeExec` on the outer Safe to call `approveHash` on the inner Safe
2. Calls `execTransaction` on the inner Safe with the outer Safe's signature
