---
title: Local Anvil Deploy — Production Parity & Deployment CLI Commands
stage: draft
references:
  - specs/deployment/production_deployment_runbook.md
  - specs/deployment/anvil_rehearsal_runbook.md
---

# Local Anvil Deploy — Production Parity & Deployment CLI Commands

Align the baked local Anvil snapshot (`cli/bake-anvil-state.ts`) with the
production deployment topology defined in the
[production runbook](./production_deployment_runbook.md), and promote the
runbooks' recurring raw-bash blocks into first-class CLI commands. The bake
then becomes a continuously-exercised rehearsal of the production sequence:
every dev environment and e2e run boots a chain that was set up with the same
commands, in the same order, as mainnet.

Two deliberate local deltas (decided, not open): **every Safe and smart
account stays at threshold 1**, and **the Timelock `minDelay` stays 0** (the
§9 hardening step is skipped locally).

## Motivation

- Today's local topology diverges from production: `foundry-dev` uses EOA
  `admin`/`guardian` addresses (no Timelock, no Safes besides the HotSafe),
  creates only 4 of the 8 role smart accounts, and wires them with one-off
  CLI calls instead of `setup-smart-accounts`/`grant-roles`. Bugs in the
  production-path commands only surface during a manual rehearsal.
- The runbooks contain repeated raw-bash sections (the §5 SA-creation loop +
  hand-written roles manifest, `SafeExec.s.sol` env-var invocations, the §9
  `updateDelay` casts, the §7.7 vault seed, the fork USDC minting). Each is
  error-prone by hand; each becomes a command used by both the runbooks and
  the bake.

## Deployment model: production vs local

| Aspect                   | Production                                    | Local bake                                                                   |
| ------------------------ | --------------------------------------------- | ---------------------------------------------------------------------------- |
| Safes                    | 5 Safes, rotated to M-of-N in §11             | 5 stand-in Safes, deployer sole owner, threshold 1, never rotated            |
| Hot-Proxy Safe           | dedicated Safe, later 1-of-2 (HSM + Admin)    | the `HotSafe` already deployed by `deploy local` (threshold 1)               |
| Guardian                 | Timelock on every contract                    | same (Timelock deployed locally, `minDelay = 0` forever)                     |
| Admin                    | Admin Safe                                    | same (stand-in Admin Safe)                                                   |
| Role smart accounts      | 8                                             | 8 (adds Shareholder, Portfolio Manager, Investor Manager, Calculating Agent) |
| SA owners / threshold    | `{OpsMgmt, HotProxy, Proposer}`, 2/3          | `{OpsMgmt, deployer, HotProxy, Proposer}`, **threshold 1**                   |
| `SHAREHOLDER_ROLE` grant | Whitelister Safe via Safe UI                  | `grant-roles --include-shareholder-grant` (SafeExec path)                    |
| Vault NAV bootstrap      | manual §7.7 (cast + SafeExec)                 | `seed-vault` command, baked into the snapshot                                |
| USDC                     | Circle native USDC                            | MockUSDC with public `mint`                                                  |
| §9 hardening (36h delay) | run                                           | skipped                                                                      |
| §11 ownership rotations  | run                                           | skipped                                                                      |

The SA owner set matches production plus the deployer EOA. The deployer stays
a direct owner so existing dev tooling (`set-allowance`, `debug-tx`,
e2e helpers) can keep executing SA transactions with a single key; threshold 1
means any of the four owners can act alone. Since all stand-in Safes are
themselves deployer-owned threshold-1, the deployer can also drive any owner
Safe via `SafeExec.s.sol`.

## New CLI commands

All commands follow the existing conventions in `cli/commands/`: global
`--chain`/`--name` deployment resolution, `--json` output via `outputResult`,
idempotency where meaningful.

### Manifest auto-recording

Every command already resolves its deployment from `--chain`/`--name`, so the
roles manifest needs no extra configuration: its canonical location is
`deployments/<chain>/<name>/roles/latest.json`, derived the same way the
deploy scripts derive their artifact paths. This removes the runbooks'
shell-var plumbing — instead of capturing every address into an exported
variable and hand-writing `roles/latest.json`, commands record and resolve
addresses through the manifest automatically. Explicit `--input`/`--output`
flags remain as the escape hatch for out-of-tree paths; keeping rehearsal
artifacts out of the committed tree is already covered by `--name rehearsal`
changing the derived path.

The global `--chain`/`--name` options gain env-var defaults, following the
pattern the signer flags already use (`DEPLOYER_KEY` / `DEPLOYER_ACCOUNT` /
`DEPLOYER_ADDR` in `cli/index.ts`):

```
--chain   defaults to $TARE_CHAIN
--name    defaults to $TARE_DEPLOYMENT_NAME (then "dev")
```

Precedence: flag > env var > built-in default. A runbook session sets
`export TARE_CHAIN=avalanche TARE_DEPLOYMENT_NAME=production` once (in §1.3's
`.env`) and every subsequent command omits both flags — the manifest path,
artifact paths, and chain config all follow.

- **Writers** — commands that produce an address upsert it into the derived
  roles manifest (creating the file if missing):
  - `deploy-safe --manifest-key <field[,field...]>` — records the new Safe
    under the given manifest field(s), e.g.
    `--manifest-key proposerSafe,guardianSafe` when one Safe fills both
    slots. Without `--manifest-key`, today's stdout-only behavior.
  - `create-smart-account --manifest-key <field>` — records a one-off SA
    (e.g. `--manifest-key borrowerSa`).
  - `create-role-accounts` — records all eight role SAs (its whole purpose).
  - `deploy timelock` / `deploy loans|vault|accounts` keep writing their own
    `timelock/`, `loans/`, `vault/`, `accounts/` manifests as today — those
    are already automatic.
- **Readers** — `setup-smart-accounts`, `grant-roles`, `seed-vault`,
  `fund-usdc` default `--input` to the derived roles manifest, and
  `create-role-accounts` fills any Safe field not passed as a flag from the
  existing manifest (so `deploy-safe --manifest-key` calls earlier in the
  sequence make the flags unnecessary). `deploy timelock` defaults
  `--proposer`/`--canceller` from the manifest's `proposerSafe`/`adminSafe`,
  and the protocol `deploy` subcommands default `--admin` from `adminSafe`
  and `--guardian` from the timelock manifest's `TimelockController`.

For addresses created outside the CLI (production §1.1 creates the five Safes
in the Safe UI), a small helper records them by hand — replacing the runbook's
`export ADMIN_SAFE=0x...` block:

```
tare-contracts manifest set <field> <value>    # e.g. manifest set adminSafe 0x...
```

`manifest set` validates address-shaped fields (checksum, has code on chain)
and works for scalar fields too (`salt`, `offramp`).

**Versioned copies.** The deploy-script manifests already keep `latest.json`
and a version-pinned `<pkg-version>.json` side by side
(`deployments/avalanche/production/loans/{latest.json,0.5.20.json}`); the
roles manifest follows the same convention. All roles-manifest writers go
through one shared `writeRolesManifest()` helper in `cli/lib` that stamps the
current `package.json` version into the document and writes **both**
`roles/latest.json` and `roles/<version>.json` on every upsert. The two files
stay in sync within a version; a manifest edited under a later version (e.g. a
salt bump for a `grant-roles` re-run) leaves the old pinned file behind as
history. This replaces the runbook's manual
`cp roles/latest.json roles/$PKG_VERSION.json` step — no writer ever copies
files by hand.

### `create-role-accounts`

```
tare-contracts create-role-accounts
  [--ops-mgmt-safe <addr>]     # initial SA owner (production: sole owner)
  [--hot-proxy <addr>]
  [--guardian-safe <addr>]     # multisig co-owner added in setup (prod: = proposer safe)
  [--proposer-safe <addr>]
  [--whitelister-safe <addr>]
  [--salt <string>]            # grant-roles operation salt
  [--offramp <addr>]           # borrower offramp allowance target
  [--owners <addr,...>]        # initial owner override (default: ops-mgmt-safe)
  [--threshold <n>]            # default 1
  [--output <path>]            # default: derived roles manifest
```

Replaces production runbook §5 (the bash loop + heredoc manifest). Creates the
eight role SAs (`originator`, `borrower`, `investor`, `servicer`,
`shareholder`, `portfolio-manager`, `investor-manager`, `calculating-agent`)
via the existing `create-smart-account` logic and upserts them into the roles
manifest consumed by `setup-smart-accounts` and `grant-roles` (both
`latest.json` and the version-pinned copy, via `writeRolesManifest()`).

- Safe/salt/offramp flags are optional when the manifest already carries the
  field (recorded earlier by `deploy-safe --manifest-key` / `manifest set`);
  a flag that contradicts an existing manifest value is an error.
- Idempotent: roles already present in the manifest are skipped; only
  missing SAs are created and merged in.
- Validation: all Safe addresses must have code.

### `safe-exec`

```
tare-contracts safe-exec
  --safe <addr>
  --target <addr>
  (--calldata <hex> | --sig <signature> [--args <a,b,...>])
  [--value <wei>]
```

CLI wrapper around `script/SafeExec.s.sol` (which reads `SAFE_ADDRESS` /
`TARGET_ADDRESS` / `CALL_DATA` from env — a repeated foot-gun in the runbooks;
prod §7.7 and §9, anvil §3). Pre-flight asserts
`safe.isOwner(sender) && threshold == 1` and reports a clear error instead of
a forge revert. Other new commands shell into this rather than re-implementing
the env-var dance.

### `update-timelock-delay`

```
tare-contracts update-timelock-delay
  --min-delay <seconds>
  --proposer-safe <addr>
  [--salt <string>]            # default derived: "<chain>-<name>:update-delay:<seconds>"
```

Replaces production runbook §9 (~25 lines of raw cast with a hand-computed
salt). Encodes `updateDelay(minDelay)`, schedules it on the Timelock from the
proposer Safe (via the `safe-exec` path), waits one block, executes (open
executor), and verifies `getMinDelay() == minDelay`. Idempotent: exits 0 with
`skipped` if the delay is already the target value. Not used by the bake
(local delay stays 0) but used by the rehearsal and production runbooks.

### `seed-vault`

```
tare-contracts seed-vault
  [--input <roles-manifest>]   # default: derived roles manifest
  [--amount <usdc>]            # default 1 (1e6 units)
  [--impersonate]              # anvil only: impersonate the investor-manager SA
```

Replaces production §7.7 and anvil-rehearsal §4.1. Two steps, both verified:

1. Donation: transfer `--amount` USDC to the `PortfolioVault` (on MockUSDC,
   mint directly; on a fork, requires the sender to hold USDC or
   `fund-usdc` to have run).
2. `updateNav(1)` driven from the Investor Manager SA — default path is
   `TrustedCalls.executeTrustedCall` from the Hot-Proxy Safe via `safe-exec`
   (the production path); `--impersonate` uses `anvil_impersonateAccount`
   instead (rehearsal shortcut).

Exits non-zero unless `lastNav() > 0` afterwards. Idempotent: skips both steps
if `lastNav()` is already non-zero.

### `fund-usdc`

```
tare-contracts fund-usdc
  [--to <addr> --amount <units>]  # one-off; default funds the roles-manifest set
  [--input <roles-manifest>]      # default: derived roles manifest
  [--impersonate-master-minter]   # forked mainnet USDC (anvil only)
```

Replaces anvil-rehearsal §4 and the hand-rolled `cast send ... mint` steps in
the current bake. With `--input`, funds the standard set from the roles
manifest: Investor 100M, Borrower 1M, Shareholder 100M USDC (the amounts the
baked snapshot has always shipped). On MockUSDC it calls `mint` directly; with
`--impersonate-master-minter` it performs the Circle `masterMinter` →
`configureMinter` → `mint` sequence from the rehearsal runbook.

### `grant-roles --include-shareholder-grant` (extension)

Production §7.6 (`VaultShareToken.grantRole(SHAREHOLDER_ROLE, shareholderSa)`)
is a Safe-UI flow on mainnet but a SafeExec call everywhere the Whitelister
Safe is threshold-1 (rehearsal, bake). New optional flag on the existing
`grant-roles` command: after the Timelock batch lands, execute the shareholder
grant from `whitelisterSafe` via the `safe-exec` path and verify with
`hasRole`. Refuses to run if the Whitelister Safe threshold ≠ 1.

### `deploy` — `--admin` / `--guardian` overrides

Locally, the Admin Safe and Timelock addresses are runtime values (deployed
moments earlier), so they cannot live in the static `foundry-dev` entry in
`cli/lib/deployment-configs.ts`. Add optional `--admin <addr>` and
`--guardian <addr>` flags to the `deploy` subcommands (forwarded to the forge
scripts as env overrides, e.g. `DEPLOY_ADMIN` / `DEPLOY_GUARDIAN`), taking
precedence over the config values. The `foundry-dev` config keeps its current
EOA values as fallback so a plain `deploy local` still works standalone.

## Bake sequence (`cli/bake-anvil-state.ts` rework)

Numbered against the production runbook sections each step rehearses:

```
 0. export TARE_CHAIN=foundry TARE_DEPLOYMENT_NAME=dev           (—)
 1. Start throwaway anvil                                        (—)
 2. deploy-safe ×4                                               (§1.1)
      --manifest-key operationalManagementSafe / adminSafe /
        proposerSafe,guardianSafe / whitelisterSafe
      deployer sole owner, threshold 1; addresses land in
      the derived roles manifest — no shell vars
 3. deploy timelock --min-delay 0                                (§2)
      proposer/canceller resolved from the roles manifest,
      --executor 0x0 → timelock/latest.json
 4. deploy local --keep-state --admin/--guardian from roles manifest (§3–§4)
      → loans / vault / accounts manifests; the script's HotSafe
        is the local Hot-Proxy Safe stand-in;
        manifest set hotProxy $HOT_SAFE + manifest set offramp $HOT_SAFE
 5. create-role-accounts                                         (§5)
      --owners <opsMgmtSafe>,$DEPLOYER --threshold 1
      --salt "foundry-dev:setup-grants:v1"
      (Safe fields come from the manifest) → 8 SAs upserted
 6. setup-smart-accounts                                         (§6)
      delegates, module, approvals, operator, address book,
      ownership transition (adds HotSafe + Proposer as owners);
      threshold stays 1 (see below)
 7. grant-roles --include-shareholder-grant                      (§7.1–7.6)
      approveOriginator + 4 role grants via Timelock (delay 0),
      shareholder grant from the Whitelister Safe
 8. set-allowance SA → HotSafe for each SA                       (local extra)
      dev/e2e TrustedSpender transfer flows depend on these;
      production sets allowances per-need, not at setup
 9. fund-usdc                                                    (anvil §4)
10. seed-vault --amount 1                                        (§7.7)
      → lastNav = 1 USDC baked into the snapshot
11. anvil_dumpState → state/anvil-state.json.gz                  (—)
12. Write state/anvil-manifest.json (v2 shape below)             (—)
```

Steps 5–10 need no `--input`/address flags — everything resolves from the
deployment set in step 0 and the roles manifest it derives.

Skipped relative to production: §9 (delay raise — local `minDelay` stays 0),
§10 `verify-deployment` (optional CI follow-up, see open questions), §11
(ownership rotations), §12–13 (publish/handoff).

The ownership-transition step in `setup-smart-accounts` currently hardcodes
the production end state (`addOwnerWithThreshold(hotProxy, 1)` then
`(guardianSafe, 2)`). It gains a `--final-threshold <n>` option (default 2);
the bake passes `--final-threshold 1` so both adds keep threshold 1.

Removed from the current bake: the anvil-account-#1 `GUARDIAN_KEY` and the
direct `approve-originator` call (now Timelock-routed via `grant-roles`), the
manual `address-book register` and `approve-currency` loops (now inside
`setup-smart-accounts`).

## Package export changes

`state/anvil-manifest.json` grows to carry the full role set and governance
addresses (`src/anvil.ts` `AnvilManifest` updated to match):

```typescript
export interface AnvilManifest {
  version: string
  accounts: {
    Borrower: `0x${string}`
    Investor: `0x${string}`
    Originator: `0x${string}`
    Servicer: `0x${string}`
    Shareholder: `0x${string}`
    PortfolioManager: `0x${string}`
    InvestorManager: `0x${string}`
    CalculatingAgent: `0x${string}`
  }
  env: {
    HOT_PROXY_SAFE_ADDRESS: `0x${string}` // unchanged key, back-compat
    TIMELOCK_ADDRESS: `0x${string}`
    ADMIN_SAFE_ADDRESS: `0x${string}`
    PROPOSER_SAFE_ADDRESS: `0x${string}`
    WHITELISTER_SAFE_ADDRESS: `0x${string}`
    OPS_MGMT_SAFE_ADDRESS: `0x${string}`
  }
}
```

The roles manifest (`deployments/foundry/dev/roles/latest.json`) and the
timelock manifest are committed alongside the existing `loans`/`vault`/
`accounts` manifests, matching the production artifact layout. LMS keeps
resolving the hot proxy from `deployment.contracts.HotSafe`
(`plugins/onchain.ts`), which `deploy local` still writes — no change there.

## LMS database seeding (tare-lms)

How the dev DB mirrors the baked chain today, and what changes. Both smart
accounts and the portfolio vault are registered in the single
`onchain_accounts` table, distinguished by `account_type`
(`smartaccount` / `internal` / `vault`); there is no separate contracts table.

### Today

1. `anvil-provision-state` gunzips the baked snapshot into the anvil volume;
   the chain boots with contracts + SAs already onchain.
2. `seed-anvil` (`apps/backend/src/cli/seed-anvil.ts`) reads
   `@tare-io/tare-contracts/anvil` and inserts one `smartaccount` row per
   baked role (4 today), the servicing entity, the default agreement
   template, and the "Anvil Default" loan profile.
3. `seed-internal-contract-accounts` inserts each `KNOWN_CONTRACTS` address
   as an `internal` row and the deployment's bootstrap `PortfolioVault` as a
   `vault` row (`shortName: "Portfolio"`, `vaultShareTokenAddress` set,
   `managerAccountId` left null — nothing to assign it to).

### Changes

1. **`seed-anvil` registers 8 SAs.** The accounts map extends with
   `"Anvil Shareholder"`, `"Anvil Portfolio Manager"`,
   `"Anvil Investor Manager"`, `"Anvil Calculating Agent"` from the new
   manifest exports. Row fields updated to the baked topology:
   `owners: [opsMgmtSafe, deployer, hotProxySafe, proposerSafe]`,
   `threshold: 1`, `delegates: [hotProxySafe]` (unchanged),
   `entityId` = dev service entity (unchanged). The re-seed guard already
   keys on the short-name set, so it extends automatically; a version bump
   against a stale DB still fails with the `docker:redeploy` message.
2. **Vault registration is already covered** — `seed-internal-contract-accounts`
   keeps inserting the `PortfolioVault` `vault` row from the deployments
   export, unchanged. New: **assign the vault manager.** With a Portfolio
   Manager SA now existing, `seed-anvil` sets the Portfolio vault row's
   `managerAccountId` to the "Anvil Portfolio Manager" row id. This requires
   reordering `pnpm docker:utils` to run `seed-internal-contract-accounts`
   **before** `seed-anvil` (it only needs migrations + the contracts package,
   so the move is safe); today it runs after.
3. **Loan profile unchanged** — "Anvil Default" keeps referencing only the
   four core roles (originator/investor/borrower/servicer).
4. **Timelock and governance Safes are not registered** as `internal`
   accounts for now — `KNOWN_CONTRACTS` doesn't include them and no event
   consumer needs them yet (open question below).

### Sequence after the change

```
docker:utils
  ├─ postgres + db:migrate
  ├─ anvil-provision-state (gunzip baked snapshot → volume)
  ├─ anvil --state ... (contracts, Timelock, Safes, 8 SAs, seeded vault onchain)
  ├─ setup-oauth / seed-m2m
  ├─ seed-internal-contract-accounts  (internal rows + "Portfolio" vault row)   ← moved up
  ├─ seed-anvil                       (8 smartaccount rows, entity, template,
  │                                    loan profile, vault managerAccountId)
  └─ pre-seed                         (test data)
```

## Runbook updates

Once the commands exist, both runbooks shrink:

- One `export TARE_CHAIN=avalanche TARE_DEPLOYMENT_NAME=production` in §1.3
  replaces the `--chain avalanche --name production` repetition and the
  per-address `export ADMIN_SAFE=…` / `export LOANS=$(jq …)` blocks; the
  UI-created Safes are recorded with `manifest set` instead.
- Production §5 → one `create-role-accounts` invocation (no heredoc, no
  manual version-pinned copy); §7.7 → `seed-vault`; §9 →
  `update-timelock-delay`; the `SafeExec.s.sol` env-var blocks → `safe-exec`.
- Anvil rehearsal §4 → `fund-usdc --impersonate-master-minter`; §4.1 →
  `seed-vault --impersonate`; §3's §7.6 substitution →
  `grant-roles --include-shareholder-grant`.

## Open questions

- Drop the deployer EOA from the local SA owner set once all dev tooling
  routes through the Ops Mgmt Safe? (Would make owner sets exactly
  production-shaped; deferred — requires auditing e2e helpers first.)
- Run `verify-deployment` at the end of the bake as a CI gate? It asserts the
  production owner/threshold/delay values, so it would need
  `--sa-threshold 1 --timelock-min-delay 0` style overrides to pass locally.
- Register the Timelock (and Safes) as `internal` onchain accounts in LMS for
  event attribution? Requires extending `KNOWN_CONTRACTS` and the deployments
  export to carry the timelock manifest.

## Docs impact (tare-lms)

- `docs/architecture/` pages describing the dev-stack bootstrap / anvil
  seeding pipeline must reflect the new seed order, the 8-account set, and
  the vault manager assignment (grep for `seed-anvil` /
  `seed-internal-contract-accounts` when implementing).

## Implementation checklist

tare-contracts:

- [x] `TARE_CHAIN` / `TARE_DEPLOYMENT_NAME` env defaults for `--chain`/`--name`
- [x] Shared `writeRolesManifest()` (`latest.json` + `<version>.json`
      dual-write) + derived-path resolution in `cli/lib`
- [x] `manifest set` command
- [x] `deploy-safe` / `create-smart-account`: `--manifest-key`
- [x] `deploy` subcommands: `--admin` / `--guardian` overrides
      (+ manifest-derived defaults; local deploys only use them with
      `--keep-state`, since a reset wipes the recorded Safes/Timelock)
- [x] `setup-smart-accounts`: `--final-threshold` option
- [x] `safe-exec` command (wraps `script/SafeExec.s.sol`)
- [x] `create-role-accounts` command (SA loop + roles manifest)
- [x] `update-timelock-delay` command
- [x] `seed-vault` command (`--impersonate` variant)
- [x] `fund-usdc` command (`--impersonate-master-minter` variant)
- [x] `grant-roles --include-shareholder-grant`
- [x] Rework `cli/bake-anvil-state.ts` to the sequence above (adds a
      `deploy safe-infra` bootstrap preset + `deploy local --keep-state` so
      stand-in Safes and the Timelock can be deployed before the protocol,
      and `DEPLOY_HOT_SAFE_OWNER` so the HotSafe owner stays the hot-proxy
      signing EOA when the admin becomes a Safe)
- [x] Extend `AnvilManifest` / `src/anvil.ts` (v2 manifest)
- [x] Commit `deployments/foundry/dev/{timelock,roles}` manifests
- [x] Update both runbooks to use the new commands

tare-lms:

- [ ] `seed-anvil`: 8 roles, new owner set, vault `managerAccountId`
- [ ] `docker:utils`: run `seed-internal-contract-accounts` before `seed-anvil`
- [ ] Bump `@tare-io/tare-contracts` and verify e2e against the new snapshot
- [ ] Update affected `docs/architecture/` pages
