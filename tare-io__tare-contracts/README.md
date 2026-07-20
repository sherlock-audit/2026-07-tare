# Tare Smart Contracts

Smart contracts, ABIs, and TypeScript bindings for the Tare protocol. Uses [Foundry](https://getfoundry.sh/) for smart contract development and [wagmi CLI](https://wagmi.sh/cli) for ABI/TypeScript codegen.

## Project Structure

- `contracts/` - Solidity smart contracts
- `src/` - TypeScript source (auto-generated ABIs, enums, deployment addresses)
- `test/` - Foundry test files
- `script/` - Solidity deployment scripts
- `cli/` - TypeScript CLI tooling (deploy, codegen, predict addresses)
- `specs/` - Protocol and contract specifications
- `deployments/` - Deployment artifacts per chain (e.g. `foundry/dev/`, `baseSepolia/dev/`)
- `dist/` - Built package output (CJS + ESM + type declarations)
- [`STYLEGUIDE.md`](STYLEGUIDE.md) - Solidity code style guide
- [`SECURITY.md`](SECURITY.md) - Known issues, trust assumptions, and design tradeoffs

## Package Exports

Published as `@tare-io/tare-contracts` on GitHub Package Registry.

```ts
import { loansAbi, smartAccountFactoryAbi } from "@tare-io/tare-contracts"
import { LoanStatus, PaymentType } from "@tare-io/tare-contracts/enums"
import { deployments } from "@tare-io/tare-contracts/deployments"
import { loansAbi } from "@tare-io/tare-contracts/abis"
```

## Commands

```bash
pnpm build            # Full build: predict addresses, codegen, tsup
pnpm build:forge      # Compile Solidity contracts only
pnpm test             # Run Foundry tests (forge test)
pnpm codegen          # Extract enums + generate ABIs + generate deployments
pnpm typecheck        # Run codegen + TypeScript type checking
pnpm deploy:local     # Deploy all contracts to local Anvil
```

## CLI

All tooling is accessed through the CLI at `cli/index.ts`.

```bash
pnpm tare-contracts <command> [options]
```

Global options:

| Option                      | Env variable       | Default      | Description                                                         |
| --------------------------- | ------------------ | ------------ | ------------------------------------------------------------------- |
| `--name <name>`             | —                  | `dev`        | Deployment name                                                     |
| `--chain <chain>`           | —                  | —            | Chain name (e.g. `foundry`, `baseSepolia`, `base`, `avalancheFuji`) |
| `--root <path>`             | —                  | Package root | Project root directory                                              |
| `--private-key <key>`       | `DEPLOYER_KEY`     | —            | Deployer private key                                                |
| `--account <name>`          | `DEPLOYER_ACCOUNT` | —            | Deployer keystore account name (e.g. `dp`)                          |
| `--deployer-addr <address>` | `DEPLOYER_ADDR`    | —            | Deployer address                                                    |

Either `--private-key` or `--account` must be provided (via flag or env variable) for commands that send transactions. The deployment config key is constructed as `{chain}-{name}` (e.g. `foundry-dev`, `baseSepolia-dev`). Deployment configs are defined in `cli/lib/deployment-configs.ts`.

### Deploy commands

```bash
pnpm tare-contracts deploy local                       # Deploy to local Anvil (chain defaults to foundry)
pnpm tare-contracts deploy loans --chain baseSepolia   # Deploy Loans contracts
pnpm tare-contracts deploy accounts --chain baseSepolia # Deploy Smart Accounts
```

`--chain` is required for `deploy loans` and `deploy accounts`, and defaults to `foundry` for `deploy local`.

### Approve originator

After deploying Loans and Smart Accounts separately, approve the originator:

```bash
pnpm tare-contracts approve-originator --chain baseSepolia --originator 0x...
```

### Create smart account

Deploy a smart account via `SmartAccountFactory`:

```bash
pnpm tare-contracts create-smart-account --chain baseSepolia \
  --owners 0xABC,0xDEF --threshold 1 \
  --delegates 0x111 --currencies 0x222 --trusted-recipients 0x333
```

| Option                             | Required | Description                                 |
| ---------------------------------- | -------- | ------------------------------------------- |
| `--owners <addresses>`             | Yes      | Comma-separated owner addresses             |
| `--threshold <number>`             | Yes      | Safe threshold                              |
| `--delegates <addresses>`          | No       | Comma-separated delegate addresses          |
| `--currencies <addresses>`         | No       | Comma-separated currency addresses          |
| `--trusted-recipients <addresses>` | No       | Comma-separated trusted recipient addresses |

### Other commands

```bash
pnpm tare-contracts extract-enums        # Generate src/enums.ts from Solidity
pnpm tare-contracts generate-deployments # Generate src/deployments.ts from deployment artifacts
pnpm tare-contracts predict-addresses    # Simulate local deploy to predict addresses
```

## Environment

The CLI automatically loads environment variables from `.env` at the project root. To use `.env.testing` instead, set `ENV=testing`:

```bash
ENV=testing pnpm tare-contracts deploy local
```

## Environment Variables

| Variable            | Description                                              |
| ------------------- | -------------------------------------------------------- |
| `DEPLOYER_ADDR`     | Deployer wallet address                                  |
| `DEPLOYER_KEY`      | Deployer private key (alternative to `DEPLOYER_ACCOUNT`) |
| `DEPLOYER_ACCOUNT`  | Cast wallet keystore name (e.g. `dp`)                    |
| `ETHERSCAN_API_KEY` | API key for contract verification on block explorers     |
| `BASE_SEPOLIA_RPC`  | RPC endpoint for Base Sepolia                            |
| `BASE_RPC`          | RPC endpoint for Base mainnet                            |
| `FUJI_RPC`          | RPC endpoint for Avalanche Fuji                          |
| `SOURCIFY_URL`      | Sourcify URL for local contract verification             |

Local testing variables are in `.env.testing` (committed):

| Variable        | Description                               |
| --------------- | ----------------------------------------- |
| `ANVIL_RPC`     | RPC URL for local Anvil instance          |
| `DEPLOYER_ADDR` | Deployer address for local deployment     |
| `DEPLOYER_KEY`  | Deployer private key for local deployment |

## Deploying Contracts

All deployments use CREATE3 (via CreateX) for deterministic addresses. The deployment address is derived from the package version, deployment name, and contract name.

Deployment configs in `cli/lib/deployment-configs.ts` define per-deployment settings (admin, USDC address, originator, etc.). Environment variables from `.env` files (via dotenv) can override these defaults.

### Local (Anvil)

1. Install dependencies:

```shell
pnpm install
```

2. Start Anvil:

```shell
anvil
```

3. In a separate terminal, deploy:

```shell
pnpm deploy:local
```

This will:

- Etch the CreateX factory onto Anvil
- Deploy MockUSDC, Safe singleton, SafeProxyFactory
- Deploy Loans (with deployer as temporary admin)
- Deploy SmartAccountFactory, TrustedCalls, TrustedSpender
- Deploy a hot proxy Safe (threshold-1 Gnosis Safe, owner = configured admin)
- Deploy an originator Smart Account (owned by hot safe) via SmartAccountFactory
- Register the smart account as approved originator on Loans
- Transfer Loans admin to the configured admin
- Write deployment artifacts to `deployments/foundry/dev/`

### Local (Anvil) — from npm package

Consumers of `@tare-io/tare-contracts` can deploy all contracts to a local Anvil instance without cloning the repo. The package bundles the Solidity sources, Foundry dependencies, and deployment scripts. Requires [Foundry](https://getfoundry.sh/) to be installed.

1. Start Anvil:

```shell
anvil
```

2. Deploy:

```shell
npx tare-contracts deploy local
```

Options:

| Flag        | Default                 | Description        |
| ----------- | ----------------------- | ------------------ |
| `--rpc-url` | `http://127.0.0.1:8545` | Anvil RPC endpoint |

For local deployments, `--private-key` and `--deployer-addr` default to Anvil account #8 if not provided.

The deployed addresses are deterministic and match the addresses returned by `pnpm tare-contracts predict-addresses` at build time.

### Testnet / Mainnet

1. Set up the `dp` account using cast:

```shell
cast wallet import dp -i
```

2. Copy `.env.example` to `.env` and fill out the values.

3. Deploy the contracts:

```shell
pnpm tare-contracts deploy loans --chain baseSepolia
pnpm tare-contracts deploy accounts --chain baseSepolia
```

Available chains: `baseSepolia`, `base`, `avalancheFuji`

Deployments must be configured in `cli/lib/deployment-configs.ts`. Use `--name <name>` to select a deployment (default: `dev`). The config key is `{chain}-{name}`.

## Codegen Pipeline

1. `pnpm extract-enums` - Parses Solidity sources, extracts enums and `ENTRY_*` constants into `src/enums.ts`
2. `pnpm generate:abis` - wagmi CLI reads Foundry `out/` artifacts, generates typed ABIs into `src/abis.ts`
3. `pnpm generate:deployments` - Reads deployment JSON artifacts and generates `src/deployments.ts`
4. `pnpm tsup` - Bundles `src/` into `dist/` (CJS + ESM + `.d.ts`)

## Releasing a New Version

1. Bump the `version` field in `package.json`
2. Deploy contracts (e.g. `pnpm tare-contracts deploy loans --chain baseSepolia` then `pnpm tare-contracts deploy accounts --chain baseSepolia`)
3. Commit the version bump and deployment artifacts
4. Submit a PR with the deployment
5. On merge to `main`, CI publishes the package to GitHub Packages (`npm.pkg.github.com`), tags, and creates a GitHub release

CI checks whether the version is already published — re-merging or replaying a build won't duplicate releases.

## License

The primary license for Tare Smart Contracts V1 is the Business Source License 1.1 (`BUSL-1.1`), see [LICENSE](./LICENSE). However:

- Interfaces (files in `contracts/interfaces/` and `contracts/misc/interfaces/`) are licensed under `GPL-2.0-or-later` so they can be freely used by integrators
- Interface files copied from public standards (`IERC1404.sol`, `IERC7540.sol`, `IERC7575.sol`, `IModuleManager.sol`) remain `MIT`

Each file's `SPDX-License-Identifier` header is authoritative. On the Change Date (2030-07-10), the BUSL-licensed code converts to `GPL-2.0-or-later`.
