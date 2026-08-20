# Staging Deployment Runbook — Avalanche Fuji (43113)

This is the staging playbook for deploying the Tare protocol to the Avalanche
Fuji testnet, adapted from the
[production runbook](production_deployment_runbook.md) with **EOA-only
governance**: there is **no Timelock and no governance Safe**. A single
**staging admin EOA** holds `ADMIN_ROLE`, `GUARDIAN_ROLE`, and
`WHITELISTER_ROLE` on every contract, owns the Forwarder, and is the sole
threshold-1 owner of every role smart account. Guardian-gated grants are plain
`cast send` calls from that EOA; SA self-calls run through `safe-exec` with the
EOA as signer.

Because the governance-Safe machinery is skipped, the production ceremony
commands `deploy timelock`, `deploy-safe`, `create-role-accounts`,
`setup-smart-accounts`, `grant-roles`, and `update-timelock-delay` are **not
used** here (`create-role-accounts` and `setup-smart-accounts` hard-require
governance Safes with code on chain; `grant-roles` hard-requires a Timelock).
The role SAs are created one-by-one with `create-smart-account` and configured
with explicit CLI calls instead.

## Deployment model at a glance

```
Staging Admin EOA ──ADMIN_ROLE + GUARDIAN_ROLE on every contract──► Loans, LoansNFT,
                                                                    LoansExchange, TrustedCalls,
                                                                    TrustedSpender, SmartAccountFactory,
                                                                    PortfolioVault, VaultShareToken,
                                                                    NavCalculator
Staging Admin EOA ──WHITELISTER_ROLE on VaultShareToken──► grants SHAREHOLDER_ROLE
Staging Admin EOA ──owner──► Forwarder (rotates authorized senders)
Staging Admin EOA ──sole threshold-1 owner──► all eight role SAs
                                              (Forwarder added as second owner, threshold stays 1)

Forwarder (authorized sender EOAs) ──delegate (TrustedCalls / TrustedSpender)──► role SAs
```

Differences from production, at a glance:

| Aspect           | Production                                | Staging (this runbook)                    |
| ---------------- | ----------------------------------------- | ----------------------------------------- |
| Chain            | Avalanche C-Chain (43114)                 | Avalanche Fuji (43113)                    |
| Config key       | `avalanche-production`                    | `avalanche-staging` (chain field is Fuji) |
| USDC             | native USDC by Circle                     | Circle testnet USDC (faucet-funded)       |
| Governance       | Timelock guardian + 4 Safes               | one admin EOA (admin = guardian)          |
| SA creation      | `create-role-accounts` (batch)            | `create-smart-account` ×8                 |
| SA configuration | `setup-smart-accounts` (batch)            | explicit `safe-exec` / CLI calls          |
| SA owners        | {Ops Mgmt Safe, Forwarder, Proposer}, 2/3 | {admin EOA, Forwarder}, threshold 1       |
| Guardian grants  | `grant-roles` (Timelock batch)            | `cast send` from the admin EOA            |
| Explorer         | snowscan.xyz                              | testnet.snowscan.xyz                      |

## 1. Pre-flight <a id="1-pre-flight"></a>

### 1.0 Repo state & package version

🔶 Start from `main` at the latest commit, with a clean tree:

```bash
git checkout main && git pull
git status --porcelain          # must print nothing
```

🔶 Create the deployment branch, then bump the `version` field in
`package.json` as the first commit — the release workflow only publishes on
push to `main` when the version is new, and lms-s picks up the staging
addresses from the published package (§9):

```bash
git checkout -b <branch_name>
npm version patch --no-git-tag-version
git commit -am "chore: bump version for fuji staging deployment"
```

### 1.1 Config skeleton

`cli/lib/deployment-configs.ts` contains the `avalancheFuji` chain and the
`avalanche-staging` deployment config skeleton. **The key is historical** (it
is the deployment name lms-s references) while the entry's `chain` field is
`avalancheFuji` — so every CLI invocation uses `--chain avalanche --name
staging` for the _lookup_, and the tooling reads the Fuji RPC and writes
artifacts under `deployments/avalancheFuji/staging/` from the `chain` field.
The `admin`/`guardian` placeholders are filled in §2 (both with the staging
admin EOA).

👀 Inspect the `avalanche-staging` entry and check the values against the live
chain:

```bash
# chains.avalancheFuji must point at real Fuji infra.
cast chain-id --rpc-url $FUJI_RPC                                        # 43113
cast call 0x5425890298aed601595a70AB815c96711a31Bc65 "symbol()(string)" --rpc-url $FUJI_RPC   # USDC
# Canonical Safe v1.4.1 infra must have code on Fuji (role SAs are Safes):
cast code 0x41675C099F32341bf84BFc5382aF534df5C7461a --rpc-url $FUJI_RPC | head -c 4   # SafeSingleton → 0x60…
cast code 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 --rpc-url $FUJI_RPC | head -c 4   # SafeProxyFactory
cast code 0x9641d764fc13c8b624c04430c7356c1c7c8102e2 --rpc-url $FUJI_RPC | head -c 4   # MultiSendCallOnly
```

👀 Confirm by eye in `cli/lib/deployment-configs.ts`:

- `chains.avalancheFuji.chainId == "43113"` and `rpc()` reads `FUJI_RPC`.
- `avalanche-staging.chain == "avalancheFuji"`, `shortName == "staging"`.
- `usdc == 0x5425890298aed601595a70AB815c96711a31Bc65` (Circle testnet USDC —
  same token `fuji-dev` uses).
- `deploymentId` (`100143113`) is unique — not shared with any other entry
  (`fuji-dev` holds `100043113`). **lms-s must be repointed to this id** (§9).
- `blockExplorerUrl == "https://testnet.snowscan.xyz"`, `loansBaseURI` is the
  staging (`tare.live`) URL.
- `admin` / `guardian` are still the `0x000…000` placeholders at this point
  (filled in §2).

### 1.2 Keys & env

Two EOAs are required — `DeployLoans.s.sol` rejects a guardian equal to the
deployer, and the deploy scripts strip the deployer of every role at the end:

- **Deployer EOA** (`dp`) — broadcasts the deploys; holds no roles afterwards.
- **Staging admin EOA** (`stg`) — admin + guardian + whitelister, Forwarder
  owner, SA owner. This is a hot key with every staging power; fine for a test
  environment, never reuse it for anything production-facing.

🔶 Import both into keystores:

```bash
cast wallet import dp -i       # deployer EOA key
cast wallet import stg -i      # staging admin EOA key
```

`.env`:

```
DEPLOYER_ADDR=0xYOUR_DEPLOYER_EOA
DEPLOYER_ACCOUNT=dp
STG_ADMIN=0xYOUR_STAGING_ADMIN_EOA
RELAYER_EOA=0xYOUR_STAGING_RELAYER_EOA
FUJI_RPC=<fuji-rpc-url>                  # prefer a private endpoint (Alchemy/Quicknode)
ETHERSCAN_API_KEY=<etherscan-v2-key>     # Etherscan V2 covers 43113 via testnet Snowscan
# Config lookup key is avalanche-staging (see §1.1) — TARE_CHAIN is the key
# prefix, NOT the chain the tooling talks to (that comes from the config entry).
TARE_CHAIN=avalanche
TARE_DEPLOYMENT_NAME=staging
# Do NOT set DEPLOYER_KEY — its presence overrides --account (see cli/index.ts).
```

With `TARE_CHAIN`/`TARE_DEPLOYMENT_NAME` set, `--chain avalanche --name
staging` is implied on every `pnpm tare-contracts` invocation below, and each
command reads/records addresses in the deployment's **roles manifest**
(`deployments/avalancheFuji/staging/roles/latest.json` plus a version-pinned
copy, maintained automatically).

Public Fuji RPCs rate-limit like their mainnet counterparts and can drop
requests mid `forge script --broadcast`. Prefer a private endpoint.

### 1.3 Fund the EOAs

- **AVAX** on Fuji for both EOAs — a few AVAX each from the
  [Avalanche testnet faucet](https://core.app/tools/testnet-faucet) (or an
  internal faucet wallet). The admin EOA sends every §5–§6 transaction.
- **Testnet USDC** for the deployer — at least ~2 USDC from
  [faucet.circle.com](https://faucet.circle.com) (select Avalanche Fuji).
  §6.3's vault seed transfers 1 USDC from the deployer's balance.

### 1.4 Sanity checks

👀 Source the env, build, and check chain + balances:

```bash
set -a; source .env; set +a
forge clean && forge build
cast chain-id --rpc-url $FUJI_RPC                     # expect 43113
cast balance $DEPLOYER_ADDR --rpc-url $FUJI_RPC --ether
cast balance $STG_ADMIN     --rpc-url $FUJI_RPC --ether
cast call 0x5425890298aed601595a70AB815c96711a31Bc65 "balanceOf(address)(uint256)" $DEPLOYER_ADDR --rpc-url $FUJI_RPC
# Expect ≥ ~2 AVAX on each EOA and ≥ 2e6 USDC base units on the deployer.
```

## 2. Commit the admin EOA to config <a id="2-commit-config"></a>

🔶 In [cli/lib/deployment-configs.ts](../../cli/lib/deployment-configs.ts),
edit the `avalanche-staging` entry to replace the `0x000…000` placeholders —
**both** with the staging admin EOA:

```ts
"avalanche-staging": {
  ...
  admin: "0xSTG_ADMIN",      // value of $STG_ADMIN
  guardian: "0xSTG_ADMIN",   // same address — the admin EOA is the guardian
  ...
}
```

Commit on the deployment branch. There is no timelock artifact and no
`adminSafe` manifest entry in this topology, so the §3 deploy scripts read
`admin`/`guardian` straight from these config values — they must be correct.

🔶 Also record the admin EOA and (optionally) the offramp in the roles
manifest, which later commands and the §8 verifier read:

```bash
pnpm tare-contracts manifest set operationalManagementSafe $STG_ADMIN --eoa
pnpm tare-contracts manifest set offramp 0x... --eoa   # staging Brale offramp (skip if none)
```

(`operationalManagementSafe` is a production-named field; here it simply
records the SA owner the §8 verifier expects. `guardianSafe` is recorded in §3
as the Forwarder — the second SA owner.)

👀 Verify the config before committing:

```bash
npx tsx -e '
  import { getDeploymentConfig } from "./cli/lib/deployment-configs.ts";
  const c = getDeploymentConfig("avalanche-staging");
  console.log("admin   ", c.admin);
  console.log("guardian", c.guardian);
'
echo "expected admin == guardian == staging admin EOA: $STG_ADMIN"
```

Both must match (case-insensitive), be non-zero, and be distinct from
`$DEPLOYER_ADDR`.

## 3. Deploy protocol <a id="3-deploy-protocol"></a>

Order matters: `accounts` reads the vault manifest and `vault` reads the loans
manifest, so deploy **loans → vault → accounts**.

🔶 Deploy all three (`--admin`/`--guardian` resolve from the §2 config values —
there is no manifest/timelock layer to override them):

```bash
pnpm tare-contracts deploy loans    --deployer-addr $DEPLOYER_ADDR --account dp
pnpm tare-contracts deploy vault    --deployer-addr $DEPLOYER_ADDR --account dp
pnpm tare-contracts deploy accounts --deployer-addr $DEPLOYER_ADDR --account dp
```

Each script runs with `--verify`; if Etherscan verification fails, the
broadcast still succeeds — re-verify manually (§8.2). Artifacts land under
`deployments/avalancheFuji/staging/{loans,accounts,vault}/latest.json`.

🔶 Read the addresses needed below straight from the artifacts:

```bash
export DEPLOY_DIR=deployments/avalancheFuji/staging

export LOANS=$(jq -r '.contracts.Loans'                        $DEPLOY_DIR/loans/latest.json)
export LOANS_NFT=$(jq -r '.contracts.LoansNFT'                 $DEPLOY_DIR/loans/latest.json)
export LOANS_EXCHANGE=$(jq -r '.contracts.LoansExchange'       $DEPLOY_DIR/loans/latest.json)
export USDC=$(jq -r '.contracts.USDC'                          $DEPLOY_DIR/loans/latest.json)
export PORTFOLIO_VAULT=$(jq -r '.contracts.PortfolioVault'     $DEPLOY_DIR/vault/latest.json)
export VAULT_SHARE_TOKEN=$(jq -r '.contracts.VaultShareToken'  $DEPLOY_DIR/vault/latest.json)
export NAV_CALCULATOR=$(jq -r '.contracts.NavCalculator'       $DEPLOY_DIR/vault/latest.json)
```

🔶 Deploy the **Forwarder**, owned by the admin EOA (records `forwarder` in
the roles manifest):

```bash
pnpm tare-contracts deploy forwarder --owner $STG_ADMIN --account dp
export FORWARDER=$(jq -r '.contracts.Forwarder' $DEPLOY_DIR/forwarder/latest.json)
```

`--owner` is the constructor's `initialOwner` — the address that may rotate
authorized senders. `--currency` defaults to the loans manifest's USDC and is
the one target the Forwarder refuses to forward to.

🔶 Record the Forwarder as the SAs' second owner (`guardianSafe` is the field
the §8 verifier reads for the co-owner slot):

```bash
pnpm tare-contracts manifest set guardianSafe $FORWARDER
```

🔶 Authorize the staging relayer EOA. `setAuthorizedSenders` is owner-only;
with an EOA owner, `set-senders` sends directly from it — so sign as `stg`:

```bash
pnpm tare-contracts forwarder set-senders --sender $RELAYER_EOA --account stg
pnpm tare-contracts forwarder check
```

`--sender` is the relayer/signer EOA the **staging** LMS signs with — the only
address allowed to forward — and replaces the whole sender set.

Each deploy script grants `GUARDIAN_ROLE` and `ADMIN_ROLE` to the configured
holders (here: both the admin EOA) and revokes the deployer's transient
`GUARDIAN_ROLE`. After §3 the deployer holds **no** privileged roles on any
contract.

## 4. Create smart accounts <a id="4-create-smart-accounts"></a>

Eight SAs, one per role, each a threshold-1 Safe owned by the admin EOA.
`create-role-accounts` is not usable here (it requires governance Safes with
code on chain), so create them individually — `--manifest-key` records each in
the roles manifest, and `--delegates`/`--currencies` make the factory perform
the common wiring at creation (Forwarder delegation on both modules,
`enableModule(TrustedCalls)`, `USDC.approve(TrustedSpender, MAX)`):

```bash
for key in originatorSa borrowerSa investorSa servicerSa shareholderSa \
           portfolioManagerSa investorManagerSa calculatingAgentSa; do
  pnpm tare-contracts create-smart-account \
    --owners $STG_ADMIN --threshold 1 \
    --delegates $FORWARDER --currencies $USDC \
    --manifest-key $key --account dp
done
```

🔶 Export the SA addresses for §5–§6:

```bash
export MANIFEST=$(pnpm -s tare-contracts manifest show --json)
export ORIGINATOR_SA=$(echo $MANIFEST | jq -r '.data.originatorSa')
export BORROWER_SA=$(echo $MANIFEST | jq -r '.data.borrowerSa')
export INVESTOR_SA=$(echo $MANIFEST | jq -r '.data.investorSa')
export SERVICER_SA=$(echo $MANIFEST | jq -r '.data.servicerSa')
export SHAREHOLDER_SA=$(echo $MANIFEST | jq -r '.data.shareholderSa')
export PORTFOLIO_MANAGER_SA=$(echo $MANIFEST | jq -r '.data.portfolioManagerSa')
export INVESTOR_MANAGER_SA=$(echo $MANIFEST | jq -r '.data.investorManagerSa')
export CALCULATING_AGENT_SA=$(echo $MANIFEST | jq -r '.data.calculatingAgentSa')
export OFFRAMP=$(echo $MANIFEST | jq -r '.data.offramp // empty')
```

The roles manifest is committed with the rest of the
`deployments/avalancheFuji/staging/*` artifacts in §9.

## 5. Configure smart accounts <a id="5-configure-smart-accounts"></a>

`setup-smart-accounts` is not usable here (its executor drives every step
through an Operational Management _Safe_), so the remaining role-specific
steps — the ones the factory does **not** perform at creation — run as
explicit SA self-calls via `safe-exec`, signed by the admin EOA (`--account
stg`; the sender must be an SA owner and the threshold must be 1 — both true
here). Every step mirrors the production
[§6 step list](production_deployment_runbook.md#6-configure-smart-accounts);
none of these are whitelistable as trusted calls, so they must land now — no
relay can retrofit them later.

🔶 ERC-20 approvals to Loans (borrower, investor, servicer):

```bash
export MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935

for sa in $BORROWER_SA $INVESTOR_SA $SERVICER_SA; do
  pnpm tare-contracts safe-exec --safe $sa --target $USDC \
    --sig "approve(address,uint256)" --args $LOANS,$MAX --account stg
done
```

🔶 Investor: allow LoansExchange to move loan NFTs, and register the vault as
a peer Investor in the investor SA's address book (seller-side checks on
`LoansExchange.createOffer`/`acceptOffer`):

```bash
pnpm tare-contracts safe-exec --safe $INVESTOR_SA --target $LOANS_NFT \
  --sig "setApprovalForAll(address,bool)" --args $LOANS_EXCHANGE,true --account stg

pnpm tare-contracts address-book register --role Investor --addr $PORTFOLIO_VAULT \
  --smart-account $INVESTOR_SA --account stg
```

🔶 Shareholder: vault wiring (all three are on the TrustedCalls
never-whitelist list):

```bash
pnpm tare-contracts safe-exec --safe $SHAREHOLDER_SA --target $USDC \
  --sig "approve(address,uint256)" --args $PORTFOLIO_VAULT,$MAX --account stg

pnpm tare-contracts safe-exec --safe $SHAREHOLDER_SA --target $VAULT_SHARE_TOKEN \
  --sig "approve(address,uint256)" --args $PORTFOLIO_VAULT,$MAX --account stg

pnpm tare-contracts safe-exec --safe $SHAREHOLDER_SA --target $PORTFOLIO_VAULT \
  --sig "setOperator(address,bool)" --args $FORWARDER,true --account stg
```

🔶 Borrower: offramp allowance on TrustedSpender (skip if no offramp was
recorded in §2; amount/expiry default to max/no-expiry):

```bash
pnpm tare-contracts set-allowance set --from $BORROWER_SA --to $OFFRAMP \
  --smart-account $BORROWER_SA --account stg
```

🔶 Originator: register the peer SAs in its own address book
(`registerAddress` is permissionless and writes to `addressBook[msg.sender]`,
so it must be an originator-SA self-call):

```bash
pnpm tare-contracts address-book register --role Borrower --addr $BORROWER_SA \
  --smart-account $ORIGINATOR_SA --account stg
pnpm tare-contracts address-book register --role Investor --addr $INVESTOR_SA \
  --smart-account $ORIGINATOR_SA --account stg
pnpm tare-contracts address-book register --role Servicer --addr $SERVICER_SA \
  --smart-account $ORIGINATOR_SA --account stg
```

🔶 Add the Forwarder as second owner of every SA, threshold stays 1. The
owner slot is what lets an authorized sender confirm a Safe transaction with a
`v = 1` pre-validated signature (at threshold 1 it is sufficient alone —
acceptable on staging, never in production):

```bash
for sa in $ORIGINATOR_SA $BORROWER_SA $INVESTOR_SA $SERVICER_SA $SHAREHOLDER_SA \
          $PORTFOLIO_MANAGER_SA $INVESTOR_MANAGER_SA $CALCULATING_AGENT_SA; do
  pnpm tare-contracts safe-exec --safe $sa --target $sa \
    --sig "addOwnerWithThreshold(address,uint256)" --args $FORWARDER,1 --account stg
done
```

After §5 each SA has owners `{ $STG_ADMIN, $FORWARDER }`, threshold 1.

## 6. Privileged role grants (direct, no Timelock) <a id="6-role-grants"></a>

All seven setup-time grants are guardian-callable (or, for the
shareholder grant, `onlyRole(WHITELISTER_ROLE)`) — and the admin EOA holds
`GUARDIAN_ROLE`, so each is a plain transaction signed by `stg`.

| #   | Target               | Function                                              | Caller (direct)         |
| --- | -------------------- | ----------------------------------------------------- | ----------------------- |
| 6.1 | `$LOANS`             | `approveOriginator($ORIGINATOR_SA)`                   | admin EOA (guardian)    |
| 6.2 | `$PORTFOLIO_VAULT`   | `grantRole(PORTFOLIO_MANAGER, $PORTFOLIO_MANAGER_SA)` | admin EOA (guardian)    |
| 6.3 | `$PORTFOLIO_VAULT`   | `grantRole(INVESTOR_MANAGER, $INVESTOR_MANAGER_SA)`   | admin EOA (guardian)    |
| 6.4 | `$NAV_CALCULATOR`    | `grantRole(CALCULATING_AGENT, $CALCULATING_AGENT_SA)` | admin EOA (guardian)    |
| 6.5 | `$VAULT_SHARE_TOKEN` | `grantRole(WHITELISTER_ROLE, $STG_ADMIN)`             | admin EOA (guardian)    |
| 6.6 | `$PORTFOLIO_VAULT`   | `registerAddress($INVESTOR_SA)`                       | admin EOA (guardian)    |
| 6.7 | `$VAULT_SHARE_TOKEN` | `grantRole(SHAREHOLDER_ROLE, $SHAREHOLDER_SA)`        | admin EOA (whitelister) |

6.6 is the buyer-side half of the exchange wiring: `LoansExchange.acceptOffer`
checks both parties' address books, so without the investor SA in the vault's
book every Funder → vault settlement reverts `SellerNotRegistered`.

### 6.1 Grants

🔶 Read the role ids, then execute the seven grants:

```bash
export ROLE_PM=$(cast call $PORTFOLIO_VAULT "PORTFOLIO_MANAGER()(bytes32)" --rpc-url $FUJI_RPC)
export ROLE_IM=$(cast call $PORTFOLIO_VAULT "INVESTOR_MANAGER()(bytes32)" --rpc-url $FUJI_RPC)
export ROLE_CA=$(cast call $NAV_CALCULATOR "CALCULATING_AGENT()(bytes32)" --rpc-url $FUJI_RPC)
export ROLE_WL=$(cast call $VAULT_SHARE_TOKEN "WHITELISTER_ROLE()(bytes32)" --rpc-url $FUJI_RPC)
export ROLE_SH=$(cast call $VAULT_SHARE_TOKEN "SHAREHOLDER_ROLE()(bytes32)" --rpc-url $FUJI_RPC)

pnpm tare-contracts approve-originator set --originator $ORIGINATOR_SA --account stg

cast send $PORTFOLIO_VAULT "grantRole(bytes32,address)" $ROLE_PM $PORTFOLIO_MANAGER_SA --account stg --rpc-url $FUJI_RPC
cast send $PORTFOLIO_VAULT "grantRole(bytes32,address)" $ROLE_IM $INVESTOR_MANAGER_SA  --account stg --rpc-url $FUJI_RPC
cast send $NAV_CALCULATOR  "grantRole(bytes32,address)" $ROLE_CA $CALCULATING_AGENT_SA --account stg --rpc-url $FUJI_RPC
cast send $VAULT_SHARE_TOKEN "grantRole(bytes32,address)" $ROLE_WL $STG_ADMIN          --account stg --rpc-url $FUJI_RPC
cast send $PORTFOLIO_VAULT "registerAddress(address)" $INVESTOR_SA                     --account stg --rpc-url $FUJI_RPC
# 6.7 requires 6.5 to have landed — WHITELISTER_ROLE is the admin of SHAREHOLDER_ROLE.
cast send $VAULT_SHARE_TOKEN "grantRole(bytes32,address)" $ROLE_SH $SHAREHOLDER_SA     --account stg --rpc-url $FUJI_RPC
```

### 6.2 Confirm

```bash
pnpm tare-contracts approve-originator check --originator $ORIGINATOR_SA   # approved: true
cast call $PORTFOLIO_VAULT   "hasRole(bytes32,address)(bool)" $ROLE_PM $PORTFOLIO_MANAGER_SA --rpc-url $FUJI_RPC
cast call $PORTFOLIO_VAULT   "hasRole(bytes32,address)(bool)" $ROLE_IM $INVESTOR_MANAGER_SA  --rpc-url $FUJI_RPC
cast call $NAV_CALCULATOR    "hasRole(bytes32,address)(bool)" $ROLE_CA $CALCULATING_AGENT_SA --rpc-url $FUJI_RPC
cast call $VAULT_SHARE_TOKEN "hasRole(bytes32,address)(bool)" $ROLE_WL $STG_ADMIN            --rpc-url $FUJI_RPC
cast call $VAULT_SHARE_TOKEN "hasRole(bytes32,address)(bool)" $ROLE_SH $SHAREHOLDER_SA       --rpc-url $FUJI_RPC
cast call $LOANS "isRegisteredForRole(address,uint8,address)(bool)" $PORTFOLIO_VAULT 2 $INVESTOR_SA --rpc-url $FUJI_RPC
# Expect: true for all six.
```

### 6.3 Seed the vault (NAV bootstrap) <a id="6-3-seed-vault"></a>

Identical to production
([§7.8](production_deployment_runbook.md#7-7-seed-vault) — read its NAV/share
price note before choosing a different seed size). With 6-decimal Fuji USDC
and `DEAD_SHARES = 1e18`, **seed exactly 1 USDC** for the clean
`1 USDC → 1 share` starting price. The donation is a plain transfer from the
signer's USDC balance; `updateNav(1)` is driven through the relay, so **the
signer must be an authorized sender on the Forwarder** — either run this with
the relayer key, or temporarily add the deployer as a sender alongside the
relayer (`forwarder set-senders --sender $RELAYER_EOA --sender $DEPLOYER_ADDR
--account stg`) and re-run `set-senders` with just `$RELAYER_EOA` afterwards:

```bash
pnpm tare-contracts seed-vault --amount 1 --account dp
```

👀 Confirm:

```bash
cast call $PORTFOLIO_VAULT "lastNav()(uint256)" --rpc-url $FUJI_RPC
# Expect: 1000000 (non-zero). approveDeposit / approveRedemption are now unblocked.
```

## 7. Copy SA addresses into LMS <a id="7-copy-sa-addresses-into-lms"></a>

In the staging (lms-s) admin tooling, register all eight SA addresses under
the staging deployment. Read them from the roles manifest:

```bash
pnpm tare-contracts manifest show
```

(the `originatorSa` … `calculatingAgentSa` fields). LMS has no importer that
reads the roles manifest for live deployments, so this stays a manual
admin-tooling step.

## 8. Verify deployment (hard gate) <a id="8-verify-deployment"></a>

👀 Run the on-chain verifier. `--guardian` is the admin EOA, there is no
`--timelock-min-delay` (the timelock phase reports _skipped_ — no timelock
manifest exists), and the SA phase reads the roles manifest recorded in
§2–§4: expected owners are `{operationalManagementSafe, forwarder,
guardianSafe}` = `{$STG_ADMIN, $FORWARDER, $FORWARDER}`, so pass
`--sa-threshold 1` and `--sa-allow-extra-owners` (subset semantics — the
duplicate Forwarder entry then matches the two-owner set):

```bash
pnpm tare-contracts verify-deployment \
  --rpc-url $FUJI_RPC \
  --deployer $DEPLOYER_ADDR \
  --admin $STG_ADMIN \
  --guardian $STG_ADMIN \
  --whitelister $STG_ADMIN \
  --sa-threshold 1 --sa-allow-extra-owners
```

This is a hard gate: do not proceed if any phase fails. Asserted, among other
things:

- Every contract grants `GUARDIAN_ROLE` and `ADMIN_ROLE` to `$STG_ADMIN`; the
  deployer holds no privileged role anywhere. Complete role membership is
  reviewed manually from the contracts' `RoleGranted` / `RoleRevoked` events.
- Loans address book is consistent: originator approved, borrower/investor/
  servicer registered on the originator's book.
- All eight SAs have `$STG_ADMIN` and `$FORWARDER` as owners, threshold 1,
  plus the modules, delegates, allowances and operator flags from §4–§5.
- `Forwarder.owner() == $STG_ADMIN`.
- The expected §6 role grants are present.

### 8.2 Etherscan verification

🔶 Re-verify manually where `--verify` did not succeed during deploy:

```bash
forge verify-contract <ADDRESS> contracts/Loans.sol:Loans \
  --chain 43113 --etherscan-api-key $ETHERSCAN_API_KEY --watch
```

Repeat for `LoansNFT`, `LoansExchange`, `TrustedCalls`, `TrustedSpender`,
`SmartAccountFactory`, `PortfolioVault`, `VaultShareToken`, `NavCalculator`,
and the Forwarder.

## 9. Publish `@tare-io/tare-contracts` & LMS handoff <a id="9-publish"></a>

Open a PR from the deployment branch back to `main` containing:

- The `package.json` version bump from §1.0.
- The populated `avalanche-staging` config in
  `cli/lib/deployment-configs.ts`.
- The new `deployments/avalancheFuji/staging/*` artifacts, including the
  `roles/` manifest.

Merging publishes the package; lms-s installs the new version and picks up the
addresses + ABIs.

### 9.1 LMS handoff checklist

- [ ] Published `@tare-io/tare-contracts` version pinned in lms-s.
- [ ] **lms-s repointed to deploymentId `100143113`** (it was previously
      pinned to `100043114`, the retired mainnet mock-USDC staging deployment).
- [ ] lms-s env updated with: `LOANS_ADDRESS`, `TRUSTED_CALLS_ADDRESS`,
      `TRUSTED_SPENDER_ADDRESS`, `SMART_ACCOUNT_FACTORY_ADDRESS`,
      `USDC_ADDRESS`, `FUJI_RPC`,
      `TARE_DEPLOYMENT_<id>_FORWARDER_ADDRESS` (and the eight
      `*_SMART_ACCOUNT` addresses from §7). There is no `TIMELOCK_ADDRESS` in
      this topology.
- [ ] Staging relayer/signer EOA key provisioned in lms-s' hot wallet config,
      and that address is an authorized sender on `$FORWARDER` (§3) — and the
      only one, if the deployer was temporarily added in §6.3.
- [ ] Smoke test from lms-s: create a draft loan; confirm `Loans.createLoan`
      from the originator SA succeeds.

### 9.2 Funding plan

- Top up the **staging relayer EOA** with Fuji AVAX (faucet); it pays gas for
  every relayed call. Testnet faucets rate-limit, so keep a reserve.
- Test-USDC liquidity for staging flows comes from
  [faucet.circle.com](https://faucet.circle.com) plus `fund-usdc` where
  applicable.

## Out of scope

- Monitoring / alerting (test environment).
- Production governance parity (Timelock, Safes, M-of-N thresholds) — by
  design; see the [production runbook](production_deployment_runbook.md) for
  that model.
