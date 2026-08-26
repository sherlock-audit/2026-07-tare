# Production Deployment Runbook — Avalanche C-Chain (43114)

This is the production playbook for deploying the Tare protocol to Avalanche
C-Chain mainnet. The model is: **Timelock as guardian from day 1 on every
contract**, a Proposer Safe that is both the sole Timelock proposer and a
multisig co-owner of every role smart account after §6, the Admin Safe (which
holds `ADMIN_ROLE` everywhere) as the sole Timelock canceller, a Whitelister
Safe that holds `WHITELISTER_ROLE` on `VaultShareToken`. The Forwarder is added
as the third co-owner of every role smart account during §6. The Timelock
starts with `minDelay = 0` for the setup window then is raised to 36 hours as
the final hardening step.

For a local-fork rehearsal of this sequence, see
[anvil_rehearsal_runbook.md](anvil_rehearsal_runbook.md).

## Deployment model at a glance

```
Proposer Safe ──proposer──► Timelock ──guardian──► Loans, LoansNFT, LoansExchange,
(threshold-1                (minDelay              TrustedCalls, TrustedSpender,
 during setup,               0 → 36h;              SmartAccountFactory,
 M-of-N after §10;           admin = self          PortfolioVault, VaultShareToken,
 PROPOSER_ROLE only)         after renounce)       NavCalculator

Admin Safe ──canceller──► Timelock
Admin Safe ──ADMIN_ROLE on every contract──► (all of the above)

Whitelister Safe ──WHITELISTER_ROLE on VaultShareToken──► grants SHAREHOLDER_ROLE
(M-of-N, day 1)                                            to vault depositors

executors = OPEN (anyone can call Timelock.execute after the delay)

Operational Management Safe (threshold-1, bootstrap sole owner during §5–§6)
        │
        └── creates and signs setup for every role SA:
            Originator SA   Borrower SA   Investor SA   Servicer SA
            Shareholder SA  Portfolio Mgr SA  Investor Mgr SA  Calculating Agent SA

After §6 each role SA has 3 owners:
    { Operational Management Safe, Forwarder, Proposer Safe }, threshold 2/3

Forwarder (authorized sender EOAs) ──delegate (TrustedCalls / TrustedSpender)──► role SAs
Proposer Safe                ──multisig co-owner authorizing high-risk SA ops──► role SAs
```

**Why only `Loans.approveOriginator` plus the vault/calculator role grants need
the Timelock during setup.** Every other setup call has a non-guardian route:

- Module/delegate wiring goes through the SA's own `safeOrGuardian(safe)` modifier
  (`contracts/TrustedCalls.sol`, `contracts/TrustedSpender.sol`) — the SA self-call
  satisfies it.
- ERC-20 / ERC-721 / ERC-7540 approvals and operator grants are owner calls —
  the SA is the owner. None of them are whitelistable as trusted calls
  ([specs/trusted-calls.md §"Functions That Must Never Be Whitelisted"](../trusted-calls.md#functions-that-must-never-be-whitelisted)),
  so every one of them must land at SA setup time (§6) — no relay can retrofit
  them later.
- `Loans.registerAddress(role, addr)` is permissionless and writes to
  `addressBook[msg.sender]` — the originator SA self-call is the right address
  book. The one address book that cannot be written by a self-call is the
  **vault's own** (the PortfolioVault is a contract, not a Safe): its
  `registerAddress` is manager/admin/guardian-gated, so the buyer-side
  exchange entry rides the Timelock batch below.

The Timelock-routed calls below (`approveOriginator`, the three role grants on
the vault/calculator, `WHITELISTER_ROLE` on the share token, and the vault's
address-book registration of the investor SA) are all guardian-callable and
are batched into a single `scheduleBatch` + `executeBatch` pair. The
`SHAREHOLDER_ROLE` grant is `onlyRole(WHITELISTER_ROLE)`
and is executed from the Whitelister Safe, not through Timelock.

## 1. Pre-flight <a id="1-pre-flight"></a>

### 1.0 Repo state & package version

🔶 Start from `main` at the latest commit, with a clean tree:

```bash
git checkout main && git pull
git status --porcelain          # must print nothing
git rev-parse HEAD origin/main  # (optional) both hashes must match
```

🔶 Then create the deployment branch:

```bash
git checkout -b <branch_name>
```

🔶 Before starting anything else, bump the `version` field in `package.json` and
make it the first commit on the branch. The release workflow
(`.github/workflows/release-package.yml`) only publishes on push to `main`
when the `package.json` version is not already on the registry — bumping up
front reserves the version for this deployment and guarantees the §11 merge
triggers a publish.

```bash
npm version patch --no-git-tag-version   # or minor, per semver impact
git commit -am "chore: bump version for avalanche production deployment"
```

### 1.1 Safes

Create the following Gnosis Safes on Avalanche via [app.safe.global](https://app.safe.global)
**before** starting:

| Safe                        | Role(s)                                                                                                                                    | Owners/threshold for the deploy  | Final state                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------- | -------------------------- |
| Admin Safe                  | `ADMIN_ROLE` on every protocol contract; `CANCELLER_ROLE` on Timelock                                                                      | sole deployer EOA, threshold = 1 | M-of-N (raised in §10)     |
| Proposer Safe               | `PROPOSER_ROLE` on Timelock (only); also added as a multisig co-owner of every role SA after §6 (authorizes high-risk SA ops post-handoff) | sole deployer EOA, threshold = 1 | M-of-N (raised in §10)     |
| Whitelister Safe            | `WHITELISTER_ROLE` on `VaultShareToken` (grants `SHAREHOLDER_ROLE` to vault depositors)                                                    | M-of-N from day 1                | unchanged                  |
| Operational Management Safe | bootstrap sole owner of every role SA during §5–§6; co-owner after the ownership transition                                                | sole deployer EOA, threshold = 1 | M-of-N (operator decision) |

The Admin Safe, Proposer Safe, and Operational Management Safe start at
threshold = 1 because `script/SafeExec.s.sol` requires
`safe.isOwner(msg.sender) && threshold == 1`. The Admin Safe and Proposer Safe
are rotated to their final owner sets at the very end (§10), once all
SafeExec-driven setup is done. The role SAs' third co-owner is the Forwarder
(§4), not a Safe — it needs no threshold and no rotation of its own; it is itself
owned by the Admin Safe, so §10.1 covers it. The Operational Management Safe
threshold is raised separately per operator policy after the SA handoff.

The Whitelister Safe is deployed at its final M-of-N threshold from day 1 and
acts on `VaultShareToken` through the normal Safe UI flow — it is never used
through `SafeExec.s.sol`.

### 1.2 Config skeleton

`cli/lib/deployment-configs.ts` contains the `avalanche` chain and the
`avalanche-production` deployment config skeleton; the `admin` and `guardian`
placeholder addresses still need to be filled in — see §3.

Before deploying anything, verify the static values that are **not** filled in
later. A wrong value here (e.g. a non-mainnet USDC, a bad Safe singleton, or a
duplicated `deploymentId`) silently corrupts every artifact and is only
discovered after irreversible mainnet txs.

👀 Inspect the `avalanche-production` entry and check the values against the live chain:

```bash
# chains.avalanche must point at real mainnet infra.
cast chain-id --rpc-url $AVALANCHE_RPC                                   # 43114
cast call 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E "symbol()(string)" --rpc-url $AVALANCHE_RPC   # USDC
# Canonical Safe v1.4.1 infra must have code on mainnet:
cast code 0x41675C099F32341bf84BFc5382aF534df5C7461a --rpc-url $AVALANCHE_RPC | head -c 4   # SafeSingleton → 0x60…
cast code 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 --rpc-url $AVALANCHE_RPC | head -c 4   # SafeProxyFactory
cast code 0x9641d764fc13c8b624c04430c7356c1c7c8102e2 --rpc-url $AVALANCHE_RPC | head -c 4   # MultiSendCallOnly
```

For reference, addresses deployed by Safe are listed in [this registry](https://contractscan.xyz/bundle?name=Safe+1.4.1&addresses=0xfd0732dc9e303f09fcef3a7388ad10a83459ec99,0x9b35af71d77eaf8d7e40252370304687390a1a52,0x38869bf66a61cf6bdb996a6ae40d5853fd43b526,0x9641d764fc13c8b624c04430c7356c1c7c8102e2,0x41675c099f32341bf84bfc5382af534df5c7461a,0x29fcb43b46531bca003ddc8fcb67ffe91900c762,0x4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67,0xd53cd0ab83d845ac265be939c57f53ad838012c9,0x3d4ba2e0884aa488718476ca2fb8efc291a46199,0x526643F69b81B008F46d95CD5ced5eC0edFFDaC6,0xfF83F6335d8930cBad1c0D439A841f01888D9f69,0xBD89A1CE4DDe368FFAB0eC35506eEcE0b1fFdc54).

👀 Confirm by eye in `cli/lib/deployment-configs.ts`:

- `chains.avalanche.chainId == "43114"` and `rpc()` reads `AVALANCHE_RPC`.
- `avalanche-production.chain == "avalanche"`, `shortName == "production"`.
- `usdc == 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` (native USDC by Circle).
- `deploymentId` (`100043114`) is unique — not shared with any other entry.
- `blockExplorerUrl == "https://snowscan.xyz"`, `loansBaseURI` is the prod URL.
- `admin` / `guardian` are still the `0x000…000` placeholders at this point
  (filled in §3).

### 1.3 Env

🔶 Import the deployer key into a keystore:

```bash
cast wallet import dp -i      # paste deployer EOA private key, set a password
```

`.env`:

```
DEPLOYER_ADDR=0xYOUR_DEPLOYER_EOA
DEPLOYER_ACCOUNT=dp
RELAYER_EOA=0xYOUR_LMS_RELAYER_EOA       # public address only; the deployer does not need its key
AVALANCHE_RPC=<private-avalanche-mainnet-rpc-url>   # ask another developer for our Quicknode RPC URL
ETHERSCAN_API_KEY=<etherscan-v2-key>     # Etherscan V2 covers 43114 via Snowscan
# Every CLI command below reads these instead of repeated --chain/--name flags.
TARE_CHAIN=avalanche
TARE_DEPLOYMENT_NAME=production
# Do NOT set DEPLOYER_KEY — its presence overrides --account dp (see cli/index.ts).
```

With `TARE_CHAIN`/`TARE_DEPLOYMENT_NAME` set, the `--chain avalanche
--name production` pair is implied on every `pnpm tare-contracts` invocation
below, and each command reads/records addresses in the deployment's **roles
manifest** (`deployments/avalanche/production/roles/latest.json` plus a
version-pinned copy, maintained automatically) instead of shell variables.

> **Stale shell exports override `.env`.** The CLI loads `.env` via dotenv,
> which never overrides variables already exported in the shell — a leftover
> `TARE_DEPLOYMENT_NAME=staging` or `TARE_CHAIN` from a previous session
> silently retargets every command at the wrong deployment (and its RPC).
> Before starting, check `env | grep TARE_` in the terminal you will use and
> `unset` anything stale, or run the deployment from a fresh shell.

**Do NOT use a public RPC URL** (e.g. `https://api.avax.network/ext/bc/C/rpc`)
for the deployment — public endpoints rate-limit and drop requests mid
`forge script --broadcast`, which can leave a deploy half-landed. Use the
Tare team's private Avalanche mainnet endpoint (preferably Alchemy); ask another developer for the
URL. Never commit it.

### 1.4 Sanity checks

👀 Source the env, build, and check chain + deployer balance:

```bash
set -a; source .env; set +a
forge clean && forge build
cast chain-id --rpc-url $AVALANCHE_RPC                # expect 43114
cast balance $DEPLOYER_ADDR --rpc-url $AVALANCHE_RPC --ether
# Expect at least ~5 AVAX for deployer; top up if not.
```

🔶 Start from a clean roles manifest. `manifest set` merges field-by-field
into any existing `roles/latest.json`, so a manifest left over from a previous
deployment silently carries its fields (role SAs, `salt`, retired fields) into
this one — and §5 `create-role-accounts` would then _skip_ creating the SAs it
finds already recorded. Delete any leftover file (its version-pinned copy
remains in git as the durable record) and confirm the CLI sees none:

```bash
git rm --ignore-unmatch deployments/avalanche/production/roles/latest.json
pnpm tare-contracts manifest show   # must report no manifest
```

🔶 Record each Safe address (created in the Safe UI, §1.1) into the roles
manifest — `manifest set` checksums the address and verifies it has code
on chain:

```bash
pnpm tare-contracts manifest set adminSafe 0x...
pnpm tare-contracts manifest set proposerSafe 0x...
# The Proposer Safe is also the multisig co-owner of every role SA after §6:
pnpm tare-contracts manifest set guardianSafe 0x...        # same address as proposerSafe
pnpm tare-contracts manifest set whitelisterSafe 0x...
pnpm tare-contracts manifest set operationalManagementSafe 0x...
pnpm tare-contracts manifest set offramp 0x... --eoa       # Brale offramp for the borrower
pnpm tare-contracts manifest show                          # verify by eye
# `forwarder` is not set by hand — `deploy forwarder` (§4) records it.
```

The commands in §2–§9 resolve every governance address from this manifest;
the only shell vars still exported below are for raw `cast` verification
snippets.

## 2. Deploy Timelock <a id="2-deploy-timelock"></a>

🔶 Deploy the Timelock (`--proposer`/`--canceller` default to the manifest's
`proposerSafe`/`adminSafe`; executor defaults to the zero address — open
execution):

```bash
pnpm tare-contracts deploy timelock --min-delay 0
```

The `deploy timelock` script asserts post-deploy (exact-set, no extras):

- `getMinDelay() == 0`
- `PROPOSER_ROLE` holders = `{PROPOSER_SAFE}` only
- `CANCELLER_ROLE` holders = `{ADMIN_SAFE}` only (auto-grant from
  `PROPOSER_ROLE` is revoked during deploy)
- `EXECUTOR_ROLE` holders = `{address(0)}` only (open execution)
- `DEFAULT_ADMIN_ROLE` holders = `{Timelock}` only (deployer's transient
  setup-admin role is renounced at the end of the script)

Artifact: `deployments/avalanche/production/timelock/latest.json` — the §4
deploy scripts and §7 `grant-roles` read the Timelock address from it directly.

🔶 Record (for the raw `cast` verification snippets below only):

```bash
export TIMELOCK=$(jq -r '.contracts.TimelockController' deployments/avalanche/production/timelock/latest.json)
export ADMIN_SAFE=$(pnpm -s tare-contracts manifest show --json | jq -r '.data.adminSafe')
```

## 3. Commit Timelock address to config <a id="3-commit-guardian-to-config"></a>

In [cli/lib/deployment-configs.ts](../../cli/lib/deployment-configs.ts), edit the
`avalanche-production` entry to replace the `0x000…000` placeholders:

```ts
"avalanche-production": {
  ...
  admin: "0xADMIN_SAFE",      // value of $ADMIN_SAFE
  guardian: "0xTIMELOCK",     // value of $TIMELOCK from step 2
  ...
}
```

Commit on the deployment branch. The §4 deploy scripts resolve these role
holders from the recorded artifacts first (roles manifest `adminSafe`, §2
timelock manifest) with the config as fallback — but the published config must
still carry the real addresses: it is the durable record consumers and future
operators read.

👀 Verify the two filled-in values before committing — these gate every role grant
in the deployment, so a typo here is unrecoverable:

```bash
# Resolve the config exactly as the CLI does (tsx evaluates the TS module).
npx tsx -e '
  import { getDeploymentConfig } from "./cli/lib/deployment-configs.ts";
  const c = getDeploymentConfig("avalanche-production");
  console.log("admin   ", c.admin);
  console.log("guardian", c.guardian);
'

echo "expected admin (Admin Safe): $ADMIN_SAFE"
echo "expected guardian (Timelock): $TIMELOCK"
```

Both must match (case-insensitive), be non-zero, and `guardian` must equal the
Timelock deployed in §2 — not the Admin Safe. The §4 deploy scripts and the §9
`verify-deployment` hard gate both assume this.

## 4. Deploy protocol <a id="4-deploy-protocol"></a>

Order matters: `accounts` reads the vault manifest for the `PortfolioVault`
address (`DeploySmartAccounts.s.sol` reads
`deployments/<chain>/<name>/vault/latest.json`), and `vault` reads the loans
manifest. So deploy **loans → vault → accounts**.

🔶 Deploy all three (`--admin` defaults to the manifest's `adminSafe`,
`--guardian` to the §2 timelock artifact — the static config values from §3
are the fallback, not the source):

```bash
pnpm tare-contracts deploy loans    --deployer-addr $DEPLOYER_ADDR --account dp
pnpm tare-contracts deploy vault    --deployer-addr $DEPLOYER_ADDR --account dp
pnpm tare-contracts deploy accounts --deployer-addr $DEPLOYER_ADDR --account dp
```

Each script runs with `--verify`; if Etherscan verification fails, the broadcast
still succeeds — re-verify manually (see §9.2). Artifacts under
`deployments/avalanche/production/{loans,accounts,vault}/latest.json` — the
commands in §5–§8 read every protocol address from these directly; no
hand-copying into shell vars.

🔶 Read every address you need later straight from those artifacts (no
hand-copying):

```bash
export DEPLOY_DIR=deployments/avalanche/production

export LOANS=$(jq -r '.contracts.Loans'               $DEPLOY_DIR/loans/latest.json)
export USDC=$(jq -r '.contracts.USDC'                 $DEPLOY_DIR/loans/latest.json)
export PORTFOLIO_VAULT=$(jq -r '.contracts.PortfolioVault'     $DEPLOY_DIR/vault/latest.json)
export VAULT_SHARE_TOKEN=$(jq -r '.contracts.VaultShareToken'  $DEPLOY_DIR/vault/latest.json)
export NAV_CALCULATOR=$(jq -r '.contracts.NavCalculator'       $DEPLOY_DIR/vault/latest.json)
export TRUSTED_CALLS=$(jq -r '.contracts.TrustedCalls'         $DEPLOY_DIR/accounts/latest.json)
export TRUSTED_SPENDER=$(jq -r '.contracts.TrustedSpender'     $DEPLOY_DIR/accounts/latest.json)
export SMART_ACCOUNT_FACTORY=$(jq -r '.contracts.SmartAccountFactory' $DEPLOY_DIR/accounts/latest.json)
```

🔶 Deploy the **Forwarder** — the relay every SA authorizes in §6. Only
`deploy local` folds one into the `accounts` component, so on a live chain it is
its own deploy. It records `forwarder` in the roles manifest, so §5–§6 need no
extra flag:

```bash
pnpm tare-contracts --chain avalanche --name production deploy forwarder \
  --owner $ADMIN_SAFE --account dp
export FORWARDER=$(jq -r '.contracts.Forwarder' $DEPLOY_DIR/forwarder/latest.json)
```

`--owner` is mandatory and is the constructor's `initialOwner` — the address
that may rotate authorized senders. Naming the Admin Safe here is what keeps the
deployer off the slot; there is no post-deploy handoff to remember, and §10.1
carries the power to the final signer set along with everything else the Admin
Safe holds. `--currency` defaults to the loans manifest's USDC and is the one
target the Forwarder refuses to forward to, so a bare USDC transfer can never be
relayed.

🔶 Authorize the relayer EOA. `setAuthorizedSenders` is owner-only, so this runs
from the Admin Safe — still threshold-1 with the deployer as sole owner until
§10.1, so `SafeExec.s.sol` can drive it. `set-senders` resolves the owner from
the Forwarder itself and fails if the senders did not take:

```bash
pnpm tare-contracts --chain avalanche --name production forwarder set-senders \
  --sender $RELAYER_EOA --account dp

pnpm tare-contracts --chain avalanche --name production forwarder check
```

`--sender` is the relayer/signer EOA the LMS signs with (its GCP HSM-backed
signer) — the only address allowed to forward — and replaces the whole sender set
rather than adding to it. The Forwarder relays nothing until this step lands.
Losing the relaying key is recovered by re-running this command from the Admin
Safe with a replacement; it is an EOA, not a Safe, so there is no threshold to
rotate.

Each deploy script grants `GUARDIAN_ROLE` to `$TIMELOCK`, grants `ADMIN_ROLE`
to `$ADMIN_SAFE`, and revokes the deployer's transient `GUARDIAN_ROLE` on
the contracts it deployed. After §4 the deployer holds **no** privileged
roles on any contract.

## 5. Create smart accounts <a id="5-create-smart-accounts"></a>

Eight SAs, one per role, all owned at creation by the Operational Management
Safe (sole owner, threshold 1). The Forwarder and Proposer Safe become
co-owners only in §6 as the final step of `setup-smart-accounts`.

🔶 One `create-role-accounts` invocation creates all eight SAs and upserts them
into the roles manifest (the governance Safe fields and `offramp` were already
recorded in §1.4; the grant-roles `salt` defaults to
`avalanche-production:setup-grants:v1`):

```bash
pnpm tare-contracts create-role-accounts --account dp
```

The roles manifest is a committed deployment artifact, one per deployment,
living beside the deploy-script manifests under
`deployments/<chain>/<name>/roles/`. It feeds BOTH `setup-smart-accounts` (§6)
and `grant-roles` (§7), so it carries the superset of both commands' fields —
the governance Safes, the salt, and all eight role SAs. Each loader ignores
fields it does not recognise, so one file drives both steps. Every writer
maintains `latest.json` **and** the version-pinned `<pkg-version>.json`
automatically.

The command is idempotent: a re-run skips roles already recorded in the
manifest and only creates the missing ones. `guardianSafe` is the multisig
added as a co-owner of every role SA in §6 — in production this is the same
Safe as the Proposer Safe, so `guardianSafe` and `proposerSafe` intentionally
hold the same address (recorded together in §1.4). The manifest is committed
with the rest of the `deployments/avalanche/production/*` artifacts in §11 —
no standalone commit here.

## 6. Configure smart accounts <a id="6-configure-smart-accounts"></a>

A single `setup-smart-accounts` invocation configures all eight SAs from the
manifest written in §5, executing every step as a SA self-call signed by the
threshold-1 Operational Management Safe (via `SafeExec.s.sol`). The Admin Safe
is not involved, and the Timelock is not involved — each step has a
non-guardian route.

🔶 Configure all eight SAs (`--input` defaults to the roles manifest):

```bash
pnpm tare-contracts setup-smart-accounts --account dp
```

What runs per SA (all idempotent — a re-run reports `skipped` on satisfied
steps; protocol addresses come from the deployment artifacts written in §4):

- Common (every SA): `TrustedCalls.addDelegate(SA, $FORWARDER)`,
  `TrustedSpender.addDelegate(SA, $FORWARDER)`,
  `enableModule(TrustedCalls)`, `USDC.approve(TrustedSpender, MAX)`. These
  largely report `skipped` because `SmartAccountFactory.configureSmartAccount`
  already performed them at SA creation
  ([contracts/SmartAccountFactory.sol:88-130](../../contracts/SmartAccountFactory.sol)).
- Borrower: `USDC.approve(Loans, MAX)`; if `offramp` is set in the manifest,
  `TrustedSpender.setAllowance(USDC, $BORROWER_SA, $OFFRAMP, MAX, ∞)`.
- Investor: `USDC.approve(Loans, MAX)`,
  `LoansNFT.setApprovalForAll(LoansExchange, true)`, and
  `Loans.registerAddress(Roles.Investor, PortfolioVault)`. The approval lets
  the investor SA sell on `LoansExchange`; the registration is the seller-side
  address-book entry paired with the vault-side entry in §7.6.
- Servicer: `USDC.approve(Loans, MAX)` (required for `Loans.returnFunds`).
- Shareholder: `USDC.approve(PortfolioVault, MAX)` +
  `VaultShareToken.approve(PortfolioVault, MAX)` +
  `PortfolioVault.setOperator($FORWARDER, true)` (lets the relay drive
  deposit/redeem/claim flows on behalf of the shareholder; `setOperator` is on
  the never-whitelist list for `TrustedCalls`, so this must land here).
- Portfolio Manager / Investor Manager / Calculating Agent: common steps only.
- Originator (after all role steps): `Loans.registerAddress(Roles.Borrower, $BORROWER_SA)`,
  `Loans.registerAddress(Roles.Investor, $INVESTOR_SA)`,
  `Loans.registerAddress(Roles.Servicer, $SERVICER_SA)`.
- **Final phase, every SA:** ownership transition via two
  `addOwnerWithThreshold` calls — `(forwarder, 1)` then `(guardianSafe, 2)`.
  After this, each SA has owners
  `{operationalManagementSafe, forwarder, guardianSafe}` with threshold `2`. In
  production `guardianSafe == $PROPOSER_SAFE`. The Forwarder's slot is what lets
  an authorized sender confirm a Safe transaction with a `v = 1` pre-validated
  signature; at threshold `2` it is one required signature, not sufficient alone.

The command's verification block at the end is the deployment gate for this
step: if any approval, operator, or address-book entry is missing, do not
proceed to §7. None of these operations can be retrofitted by a relay
([specs/trusted-calls.md](../trusted-calls.md#functions-that-must-never-be-whitelisted));
recovery requires a SA multisig session.

## 7. Privileged role grants (Timelock + Whitelister) <a id="7-approve-originator-timelock-routed"></a>

Every guardian-routed call in the setup is batched into a single
`TimelockController.scheduleBatch` + `executeBatch` pair from the **Proposer
Safe** (the sole `PROPOSER_ROLE` holder); anyone can execute after `minDelay`
(which is `0` during setup). The single `onlyRole(WHITELISTER_ROLE)` call
(7.7) happens from the Whitelister Safe through the normal Safe UI.

The seven setup-time grants are:

| #   | Target               | Function                                              | Caller              |
| --- | -------------------- | ----------------------------------------------------- | ------------------- |
| 7.1 | `$LOANS`             | `approveOriginator($ORIGINATOR_SA)`                   | Timelock (guardian) |
| 7.2 | `$PORTFOLIO_VAULT`   | `grantRole(PORTFOLIO_MANAGER, $PORTFOLIO_MANAGER_SA)` | Timelock (guardian) |
| 7.3 | `$PORTFOLIO_VAULT`   | `grantRole(INVESTOR_MANAGER, $INVESTOR_MANAGER_SA)`   | Timelock (guardian) |
| 7.4 | `$NAV_CALCULATOR`    | `grantRole(CALCULATING_AGENT, $CALCULATING_AGENT_SA)` | Timelock (guardian) |
| 7.5 | `$VAULT_SHARE_TOKEN` | `grantRole(WHITELISTER_ROLE, $WHITELISTER_SAFE)`      | Timelock (guardian) |
| 7.6 | `$PORTFOLIO_VAULT`   | `registerAddress($INVESTOR_SA)`                       | Timelock (guardian) |
| 7.7 | `$VAULT_SHARE_TOKEN` | `grantRole(SHAREHOLDER_ROLE, $SHAREHOLDER_SA)`        | Whitelister Safe    |

7.6 is the buyer-side half of the exchange wiring: it registers the investor
SA as Investor in the vault's own Loans address book.
`LoansExchange.acceptOffer` checks both parties' books (§6 already wrote the
seller side), so without this entry every Funder → vault settlement reverts
`SellerNotRegistered`.

### 7.1–7.6 Single batched Timelock op

The six guardian grants are driven by `grant-roles`, reading the same
committed roles manifest as §6 (its `proposerSafe`, `salt`, and the five role
SAs plus `whitelisterSafe` are the fields this command consumes).

🔶 Run the single command (`--input` defaults to the roles manifest):

```bash
pnpm tare-contracts grant-roles --account dp
```

What the command does, in order, against the deployment artifacts written in
§2 and §4 (Timelock, Loans, PortfolioVault, VaultShareToken, NavCalculator):

1. Reads the role IDs (`PORTFOLIO_MANAGER`, `INVESTOR_MANAGER`,
   `CALCULATING_AGENT`, `WHITELISTER_ROLE`) from the contracts.
2. Encodes the six inner calls listed in the table above.
3. Calls `TimelockController.scheduleBatch(...)` from `proposerSafe` via
   `SafeExec.s.sol` with the manifest's `salt` and `delay = 0`.
4. Waits for one block.
5. Calls `TimelockController.executeBatch(...)` (open executor; uses the
   deployer EOA).
6. Verifies each grant landed (`hasRole` / `isRegisteredForRole` checks). Any
   missing grant fails the command.

The command is idempotent: re-running it with the same `salt` after every
grant is already in place returns all-`skipped` and exits 0. If a re-run is
needed after a partial failure, bump the salt to `:v2` (etc.) so the new
schedule does not collide with the previous batch's operation hash —
`manifest set` keeps the version-pinned copy in sync automatically:

```bash
pnpm tare-contracts manifest set salt "avalanche-production:setup-grants:v2"
```

The salt only namespaces the operation hash **within a single
TimelockController instance**, so a fresh deployment (new Timelock in §2)
always starts back at `:v1` — there is nothing to collide with, and a `:vN`
bump in the manifest should only ever signal that this deployment's earlier
batch failed and was re-scheduled.

If the batch reverts on-chain, the entire batch rolls back — fix the offending
manifest field (`manifest set <field> <value>`) and re-run with a bumped `salt`.

### 7.7 `SHAREHOLDER_ROLE` on VaultShareToken — from the Whitelister Safe

This is the only setup-time grant that does **not** go through the Timelock.
`WHITELISTER_ROLE` is the admin of `SHAREHOLDER_ROLE`
([contracts/VaultShareToken.sol:61](../../contracts/VaultShareToken.sol)) and
the Whitelister Safe was granted that role as part of the batch in §7.1–7.6.

In production the Whitelister Safe is M-of-N, so this runs through the Safe
UI.

🔶 Read the target addresses and role hash first:

```bash
export VAULT_SHARE_TOKEN=$(jq -r '.contracts.VaultShareToken' deployments/avalanche/production/vault/latest.json)
export SHAREHOLDER_SA=$(pnpm -s tare-contracts manifest show --json | jq -r '.data.shareholderSa')
export ROLE_SH=$(cast call $VAULT_SHARE_TOKEN "SHAREHOLDER_ROLE()(bytes32)" --rpc-url $AVALANCHE_RPC)
echo $ROLE_SH
```

Then, from the Whitelister Safe in the Safe UI at [app.safe.global](https://app.safe.global),
create and execute a transaction with:

- **To**: `$VAULT_SHARE_TOKEN`
- **Function**: `grantRole(bytes32 role, address account)`
- **Args**: `role = $ROLE_SH`, `account = $SHAREHOLDER_SA`

👀 Confirm:

```bash
cast call $VAULT_SHARE_TOKEN "hasRole(bytes32,address)(bool)" $ROLE_SH $SHAREHOLDER_SA --rpc-url $AVALANCHE_RPC
# Expect: true
```

The shareholder SA can now successfully call
`PortfolioVault.requestDeposit` (§6 already set the USDC approval, share-token
approval, and operator).

### 7.8 Donate the vault seed <a id="7-8-seed-vault"></a>

`requestDeposit` works after §7.7, but the **first** `approveDeposit` (and
`approveRedemption`) would still revert with `ZeroNav()`.

The deploy script already minted the `DEAD_SHARES` (§4 / the vault constructor),
but dead shares alone do not move NAV. Donate the seed now; §12 finalizes the
initial NAV through LMS after its relayer is provisioned. Both actions must
complete **before** the first deposit or redemption is approved.

🔶 **Donate exactly 1 USDC to the vault from a wallet.** A plain ERC-20 transfer
is enough — the vault has no receive hook, the donation simply lands in
`assetToken.balanceOf(vault)` and is picked up by the next `updateNav`. Any
funded wallet can send it. The seed is permanent and unrecoverable: at this
point only the unredeemable `DEAD_SHARES` exist, so the donation accrues
entirely to them.

> **The seed size fixes the initial share price — pick it deliberately, not arbitrarily.**
> While `totalSupply == DEAD_SHARES`, the first finalized NAV alone sets the
> conversion rate: `price = seedNav / DEAD_SHARES` (asset base units per share),
> and the first real deposit mints `shares = assets × DEAD_SHARES / seedNav`.
> A seed that is too tiny makes each share worth a sub-wei amount, so fractional
> share balances round to `0` assets on redemption (`convertToAssets` /
> `approveRedemption`); a seed that is too large raises the minimum approvable
> deposit (`approveDeposit` reverts via `require(shares > 0)` below
> `⌈seedNav / DEAD_SHARES⌉` asset base units). With `DEAD_SHARES = 1e18`,
> 6-decimal USDC, and 18-decimal shares, **seeding exactly 1 USDC (`1e6`) yields
> the clean `1 USDC → 1 whole share` starting price** (`1e18 / 1e6 = 1e12`
> shares per base unit). If the asset's decimals ever differ, rescale the seed
> to preserve this 1:1 price. **The same sensitivity recurs any time
> `totalSupply` returns to `DEAD_SHARES`** (e.g. after every real shareholder
> has fully redeemed) — treat re-bootstrapping with the same deliberation.

Read the vault balance before opening the wallet transaction:

```bash
cast call $USDC "balanceOf(address)(uint256)" $PORTFOLIO_VAULT --rpc-url $AVALANCHE_RPC
```

In the wallet, verify all four values before signing:

- Network: Avalanche C-Chain (`43114`).
- Token: native USDC (`$USDC`, expected
  `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`).
- Recipient: `$PORTFOLIO_VAULT`.
- Amount: exactly 1 USDC (`1_000_000` base units).

👀 Record the transaction hash and, once confirmed, verify on Snowscan that it
transferred exactly `1_000_000` USDC base units to `$PORTFOLIO_VAULT`.

Do not approve a deposit or redemption yet. The seed becomes usable only after
the LMS-driven NAV finalization in §12.1.

## 8. Harden: raise Timelock minDelay 0 → 36h <a id="8-harden"></a>

Setup window closes here. A Timelock self-call schedules `updateDelay(129600)`
on itself, then anyone executes it. After this, every future guardian op carries
a 36-hour delay (and the Admin Safe — as canceller — has 36 hours to cancel any
malicious proposal).

🔶 Schedule and execute the delay update — `update-timelock-delay` encodes the
`updateDelay` self-call, schedules it from the Proposer Safe, executes it
(open executor), and fails unless `getMinDelay()` ends up at the target.
It refuses to run once the delay is already non-zero (the immediate
schedule+execute pair only works during the setup window):

```bash
pnpm tare-contracts update-timelock-delay --min-delay 129600 --account dp
```

> **Why this is safe to do as an immediate schedule+execute.** During the entire setup
> window the Proposer Safe can schedule + immediately execute any guardian
> operation. The blast radius is bounded by who controls the Proposer Safe
> (currently the deployer EOA). The Admin Safe is the only mitigation — it can
> cancel any scheduled op via its `CANCELLER_ROLE`. Window closes the moment
> this `updateDelay` executes.

## 9. Verify deployment (hard gate) <a id="9-verify-deployment"></a>

### 9.1 Onchain verification (`verify-deployment`)

👀 Run the on-chain verifier. `$WHITELISTER_SAFE` is the §1.1 Whitelister Safe:
take the value from your deployment notes — deliberately **not** from the roles
manifest, since the verifier's expectations must be independent of what the
deploy wrote. An empty variable here makes the shell drop the word and the
next flag gets swallowed as its value (`Expected 0 arguments but got 1`), so
export it explicitly first:

```bash
export WHITELISTER_SAFE=0x...   # from your deployment notes (§1.1)

pnpm tare-contracts verify-deployment \
  --rpc-url $AVALANCHE_RPC \
  --deployer $DEPLOYER_ADDR \
  --admin $ADMIN_SAFE \
  --guardian $TIMELOCK \
  --whitelister $WHITELISTER_SAFE \
  --timelock-min-delay 129600
```

(`--admin`/`--guardian`/`--whitelister` stay explicit here on purpose — the
verifier is the hard gate, so its expected values should not be read from the
same manifest the deploy wrote. The eight role SAs and their expected owner
Safes are the exception: they can only come from the committed roles manifest
(`roles/latest.json`), which the verifier loads itself — a missing or invalid
roles manifest fails the gate. The exact expected Forwarder sender set is read
from `$RELAYER_EOA`; `--forwarder-sender` remains an explicit override.)

This is a hard gate: do not proceed if any phase fails. Asserted, among other
things:

- Every controlled contract grants `GUARDIAN_ROLE` to `$TIMELOCK`; the deployer
  is confirmed not to hold it.
- Every controlled contract grants `ADMIN_ROLE` to `$ADMIN_SAFE`; the deployer
  is confirmed not to hold it.
- Deployer holds no privileged role anywhere.
- `$TIMELOCK`'s `getMinDelay() == 129600` and its `DEFAULT_ADMIN_ROLE` is held
  by itself only. **Note:** the proposer/canceller/executor **sets** are _not_
  re-checked here — `TimelockController` is not `AccessControlEnumerable`, so
  there is no on-chain way to enumerate role members. That exact-set invariant
  is asserted at deploy time by `DeployTimelock.s.sol` (see §2), which checks
  each expected holder via `hasRole` plus negative cross-role / deployer checks.
- Loans address book is consistent: originator approved, borrower/investor/
  servicer registered on the originator's book.
- Smart accounts (all eight) have the right owner set
  (`{ $OPS_MGMT_SAFE, $FORWARDER, $PROPOSER_SAFE }`, threshold 2/3), the
  right modules, delegates, ERC-20/ERC-721/ERC-7540 allowances and operator
  flags from §6. Any mismatch — including a stale bootstrap owner or a
  threshold still at 1 — fails the gate. The expected threshold defaults to 2
  (`--sa-threshold`), and the owner set is asserted exactly unless
  `--sa-allow-extra-owners` is passed (local dev only, where the deployer
  stays an owner).
- `Forwarder.owner() == $ADMIN_SAFE` — sender rotation sits with the Admin Safe,
  not the deployer.
- `Forwarder.getAuthorizedSenders()` equals `{ $RELAYER_EOA }` exactly (or the
  exact set passed through repeated `--forwarder-sender` values).
- Privileged role grants from §7 are present:
  - `Loans.isRegisteredForRole($LOANS, Originator, $ORIGINATOR_SA) == true`
  - `PortfolioVault.hasRole(PORTFOLIO_MANAGER, $PORTFOLIO_MANAGER_SA) == true`
  - `PortfolioVault.hasRole(INVESTOR_MANAGER, $INVESTOR_MANAGER_SA) == true`
  - `NavCalculator.hasRole(CALCULATING_AGENT, $CALCULATING_AGENT_SA) == true`
  - `VaultShareToken.hasRole(WHITELISTER_ROLE, $WHITELISTER_SAFE) == true`
  - `VaultShareToken.hasRole(SHAREHOLDER_ROLE, $SHAREHOLDER_SA) == true`
  - `Loans.isRegisteredForRole($PORTFOLIO_VAULT, Investor, $INVESTOR_SA) == true`
    (the buyer-side exchange entry from 7.6)

👀 **Manual complete-role review.** For each contract that stores
`AccessControl` roles — `Loans`, `LoansExchange`, `TrustedCalls`,
`TrustedSpender`, `PortfolioVault`, `NavCalculator`, `VaultShareToken`, and
the `TimelockController` — use its Snowscan event log to inspect
every `RoleGranted` and `RoleRevoked` event from the deployment transaction
through a recorded review block. (`LoansNFT` and `SmartAccountFactory` hold no
roles of their own — `LoansNFT` reads its roles from the Loans contract, so
reviewing `$LOANS` covers it.) The `$TIMELOCK` review matters most:
`TimelockController` is not enumerable, so its proposer/canceller/executor
sets are asserted only at deploy time (§2) — the event log is the only
post-hoc proof no extra holder was added since. Reconcile the history with the
expected role holders above, and record the review block and reviewer in the
deployment notes. This manual review is what checks for role holders other
than the expected holder and named forbidden deployer.

### 9.2 Etherscan verification

🔶 Re-verify manually where needed:

```bash
# For each (contract, source path), if --verify did not succeed during deploy:
forge verify-contract <ADDRESS> contracts/Loans.sol:Loans \
  --chain 43114 --etherscan-api-key $ETHERSCAN_API_KEY --watch
```

Repeat for `LoansNFT`, `LoansExchange`, `TrustedCalls`, `TrustedSpender`,
`SmartAccountFactory`, `PortfolioVault`, `VaultShareToken`, `NavCalculator`,
the Timelock, and any Safe proxies you want indexed.

## 10. Final Safe ownership transitions <a id="10-raise-admin-safe-threshold"></a>

All setup-time SafeExec activity is done. Rotate each threshold-1 deployer-EOA
Safe to its final signer set in the Safe UI ([app.safe.global](https://app.safe.global)).

The Forwarder needs no step of its own: §4 constructs it owned by the Admin Safe,
so §10.1 carries sender-rotation authority to the final signer set along with
every other Admin-Safe power. There is no Hot-Proxy Safe in this topology — the
relay is the Forwarder plus its authorized sender EOAs, and payout destinations
are named directly.

### 10.1 Raise Admin Safe threshold (M-of-N)

Batch the whole transition into **one atomic Safe transaction** (Safe UI →
Transaction Builder): one `addOwnerWithThreshold(owner, 1)` per final owner,
then `removeOwner(prevOwner, deployerEOA, M)` — `removeOwner`'s last argument
sets the final threshold, so no separate `changeThreshold` call is needed.
Atomicity leaves no intermediate state: the Safe either reaches exactly the N
final owners at threshold M or stays unchanged. The deployer can sign the very
transaction that removes it — owner checks run at signature validation, before
execution. `prevOwner` is the linked-list pointer to the owner preceding the
deployer _after_ the additions; let the Transaction Builder compute it and
simulate the batch before executing.

Afterwards, verify the network, Safe address, complete owner list, threshold,
and deployer removal in the Safe UI. Record the transaction hash and have a
second operator review the final state.

### 10.2 Raise Proposer Safe threshold (M-of-N)

Same procedure as §10.1, applied to the Proposer Safe.

### 10.3 Rotate the Operational Management Safe (M-of-N)

Same procedure as §10.1, applied to the Operational Management Safe using the
operator-approved final owner set and threshold. The Whitelister Safe needs no
transition because it started in its final M-of-N state in §1.1.

After §10.1–§10.3,
`SafeExec.s.sol` is no longer usable against these Safes (it requires
`threshold == 1`). All future privileged ops go through the Safe UI →
Timelock-schedule (Proposer Safe) → wait 36h → Timelock-execute path, or for
Admin-only ops, through the Admin Safe directly.

## 11. Publish `@tare-io/tare-contracts` <a id="11-publish"></a>

Open a PR from the deployment branch back to `main` containing:

- The `package.json` version bump from §1.0.
- The `avalanche` chain entry and the populated `avalanche-production` config in
  `cli/lib/deployment-configs.ts`.
- The new `deployments/avalanche/production/*` artifacts, including the
  `roles/` manifest (`latest.json` + the version-pinned copy) maintained
  automatically by the §1.4/§5 commands.

The version was already bumped in §1.0, so merging is all it takes: the release
workflow publishes the package on push to `main` — no prerelease workaround.

Consumers (LMS) install the new version and pick up the addresses + ABIs.

## 12. LMS handoff and funding <a id="12-lms-handoff-and-funding"></a>

### 12.1 LMS handoff checklist

- [ ] Published `@tare-io/tare-contracts` version pinned in LMS.
- [ ] LMS env updated with: `LOANS_ADDRESS`, `TRUSTED_CALLS_ADDRESS`,
      `TRUSTED_SPENDER_ADDRESS`, `SMART_ACCOUNT_FACTORY_ADDRESS`,
      `TIMELOCK_ADDRESS`, `USDC_ADDRESS`, `AVALANCHE_RPC`,
      `TARE_DEPLOYMENT_<id>_FORWARDER_ADDRESS` (and the eight
      `*_SMART_ACCOUNT` addresses — read them from the roles manifest via
      `pnpm tare-contracts manifest show`, the `originatorSa` …
      `calculatingAgentSa` fields).
- [ ] Relayer/signer EOA key provisioned in LMS' hot wallet config, and that
      address is an authorized sender on `$FORWARDER` (§4).
- [ ] From an LMS principal with `portfolio:nav:update`, run the existing
      portfolio-management **Update NAV** action with batch size `1` (or call
      authenticated `POST /portfolio/nav/update` with `{ "batchSize": 1 }`).
      The backend relayer forwards the trusted call through the Investor Manager
      SA, which holds `INVESTOR_MANAGER`.
- [ ] Wait for the NAV workflow to complete, then confirm the donated 1-USDC
      seed was finalized before approving any deposit or redemption:

  ```bash
  cast call $PORTFOLIO_VAULT "lastNav()(uint256)" --rpc-url $AVALANCHE_RPC
  # Expect: 1000000
  ```

- [ ] Smoke test from LMS: create a draft loan; confirm `Loans.createLoan` from
      the originator SA succeeds.

### 12.2 Funding plan

- Top up the **relayer/signer EOA** with enough AVAX for expected onchain ops
  over the next operational window (typical floor: 0.5–1 AVAX, adjust to
  traffic). It pays gas for every relayed call.
- Set an alerting threshold (e.g. < 0.1 AVAX) in whatever balance monitor you
  use; out-of-gas is the most common production-incident class for this
  architecture.

## Open items left to the operator

- Final Admin Safe, Proposer Safe, and Operational Management Safe thresholds
  and signer sets (§10). They do not have to be the same group: Admin Safe is
  the protocol operations multisig; Proposer Safe is a smaller multisig whose
  only power is scheduling Timelock ops; Operational Management follows the
  operator-approved policy.
- Confirm `usdc` in the config matches `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`
  (native USDC by Circle on Avalanche C-Chain).

## Out of scope

- Monitoring / alerting setup (Tenderly, Forta, etc.).
- Pause / rollback procedure.
