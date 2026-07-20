# Anvil Rehearsal Runbook

A local rehearsal of the production deployment against a forked Avalanche
mainnet anvil. Use this to catch bugs before doing the real thing — every step
of [production_deployment_runbook.md](production_deployment_runbook.md) is
exercised with stand-in Safes and real USDC (funded by impersonating Circle's
`masterMinter`).

This doc is intentionally short: it covers only the **anvil-specific deltas**
and links straight into the production runbook for the rest.

## 1. Why and when

Run this end-to-end (or at minimum §2 → §10) before every mainnet deploy. The
production runbook is the source of truth; this doc keeps the rehearsal step
list aligned without duplicating prose.

## 2. Anvil pre-flight <a id="2-anvil-pre-flight"></a>

### 2.1 Fork Avalanche

```bash
anvil --fork-url $AVALANCHE_RPC --chain-id 43114 \
  --block-time 2 \
  --gas-limit 15000000 \
  --block-base-fee-per-gas 25000000000 \
  --hardfork cancun \
  --host 127.0.0.1 --port 8545 &
export AVALANCHE_RPC=http://127.0.0.1:8545
```

The non-default flags align anvil's runtime parameters with Avalanche C-Chain
as closely as possible.
Forking with `--chain-id 43114` lets the deploy scripts find their existing
`chains.avalanche` configuration and write artifacts to
`deployments/avalanche/production/`. Substitute a different `--name`
(`--name rehearsal`, say) if you want artifacts kept out of the production tree.

### 2.2 Deployer EOA

Use an anvil-funded account; no keystore import needed:

```bash
export DEPLOYER_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# DEPLOYER_KEY is the CLI's --private-key default (cli/index.ts), so every
# command below signs with the anvil account without --account flags.
```

### 2.3 USDC

The production runbook assumes native USDC at
`0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`. The fork carries the real
FiatTokenV2 bytecode, so the rehearsal uses real USDC directly — no MockUSDC,
no config override. Funding the role SAs is done in §4 by impersonating
Circle's `masterMinter`.

```bash
export USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
```

### 2.4 Stand-in Safes

The production runbook (§1.1) requires five Safes. On anvil all of them can be
single-owner with the deployer EOA — the production-only behaviour in §11
(threshold raise on Admin Safe + Proposer Safe and 1-of-2 rotation of the
Hot-Proxy Safe) is the only step that depends on real signer sets.

Deploy single-owner Safes via the `deploy-safe` CLI command. It reads the
canonical Safe v1.4.1 factory + singleton from the `avalanche` chain config
(both already live on the mainnet fork) and deploys a plain Safe with the
deployer EOA as sole owner, threshold = 1. Because it sources the Safe infra
from chain config, it works at this point — before any protocol component is
deployed in §3.

> **Note:** `deploy local` is **not** used here. Its `foundry-dev` config sets
> `admin` to the deployer EOA (anvil account #0), not a Safe — it only deploys a
> Hot-Proxy Safe (`HotSafe`), and there is no `ADMIN_SAFE` in any manifest. For
> a clean rehearsal, deploy all five stand-in Safes uniformly via `deploy-safe`.

`--manifest-key` records each Safe straight into the roles manifest
(`deployments/avalanche/production/roles/latest.json`) — this replaces the
production runbook's §1.4 `manifest set` step, since here the CLI creates the
Safes itself:

```bash
for key in adminSafe proposerSafe,guardianSafe whitelisterSafe hotProxy operationalManagementSafe; do
  pnpm tare-contracts deploy-safe \
    --owners $DEPLOYER_ADDR --threshold 1 --manifest-key $key
done
pnpm tare-contracts manifest set offramp 0x...   # any funded EOA works as a stand-in
pnpm tare-contracts manifest show
```

(`proposerSafe,guardianSafe` records one Safe under both fields, mirroring
production where the Proposer Safe is also the SA co-owner.)

> All five Safes being single-owner is fine for rehearsal. In production the
> Whitelister Safe is real M-of-N from day 1, but for an anvil walkthrough the
> single-owner stand-in exercises the exact same call paths.

### 2.5 Speed tweak for the cast snippets

§2.1 launches anvil with `--block-time 2` to match Avalanche, so blocks
advance on the same cadence as mainnet. If you want the rehearsal to run
faster, drop `--block-time` from §2.1 — anvil reverts to instant-mine (one
block per tx).

Both Timelock flows are CLI commands that handle their own
schedule-then-execute block-wait internally (`grant-roles` in §7.1–7.5,
`update-timelock-delay` in §9), so no `sleep` substitutions are needed either
way.

## 3. Run production steps 2–7 <a id="3-run-production-steps-2-7"></a>

Follow the production runbook end-to-end from
[§2 Deploy Timelock](production_deployment_runbook.md#2-deploy-timelock)
through
[§7 Privileged role grants (Timelock + Whitelister)](production_deployment_runbook.md#7-approve-originator-timelock-routed).

§7.1–7.5 runs the `grant-roles` CLI command as-is — on anvil the
Proposer Safe is single-owner with the deployer EOA, so the same
`SafeExec`-based scheduling path works without changes.

§7.6 is a Safe-UI flow in production; on anvil the Whitelister Safe is
single-owner (the deployer EOA), so fold it into the §7 command:

```bash
pnpm tare-contracts grant-roles --include-shareholder-grant
```

**Skip §7.7 (vault seed / NAV bootstrap) for now.** It needs USDC to donate and
a manager-role caller to run `updateNav` — neither exists on the fork until §4
below mints USDC and the §7 role grants take effect. Run the fork-specific
equivalent in [§4.1](#4-1-seed-vault) instead of
[§7.7](production_deployment_runbook.md#7-7-seed-vault).

Substitutions for these sections:

- `--account dp` → drop the flag; the deployer key from §2.2 is picked up via
  `DEPLOYER_KEY` (or pass `--private-key $DEPLOYER_KEY` if a command requires
  it explicitly).
- `--password $KEYSTORE_PASSWORD` → drop, no keystore involved.
- `$USDC` → keep as `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` (real USDC on
  the fork).

## 4. Fund SAs with USDC (impersonate Circle) <a id="4-fund-sas-with-usdc"></a>

Real USDC on Avalanche has no public `mint` — minting is gated on Circle's
`masterMinter` configuring per-address minter allowances. `fund-usdc
--impersonate-master-minter` performs the whole sequence: impersonate the
`masterMinter` via `anvil_impersonateAccount`, configure the deployer EOA as a
minter with a 1B-USDC allowance, then mint the baked-snapshot amounts to the
roles-manifest SAs (Investor 100M, Borrower 1M, Shareholder 100M) and report
each resulting balance.

Do this after production runbook §6 so the SA addresses are recorded in the
roles manifest, and before §5 of this runbook so the loan/vault flows verified
by §10 have funds to move.

```bash
pnpm tare-contracts fund-usdc --impersonate-master-minter
```

### 4.1 Seed the vault (NAV bootstrap) <a id="4-1-seed-vault"></a>

The fork equivalent of production
[§7.7](production_deployment_runbook.md#7-7-seed-vault), deferred here because it
needs the USDC minted above. Same goal: give the vault a non-zero `lastNav` so
the first `approveDeposit` / `approveRedemption` does not revert with
`ZeroNav()`.

`seed-vault` handles both steps — the donation (§4 made the deployer a USDC
minter, so the mint path works on the fork) and a single `updateNav(1)` driven
through the hot proxy (the production path; the deployer owns the threshold-1
Hot-Proxy Safe stand-in). It fails unless `lastNav()` ends up non-zero:

```bash
pnpm tare-contracts seed-vault --amount 1
```

`--impersonate` is available to drive `updateNav` by impersonating the
Investor Manager SA instead — useful when rehearsing against a chain where the
hot-proxy delegate wiring is not in place yet.

Confirm:

```bash
export PORTFOLIO_VAULT=$(jq -r '.contracts.PortfolioVault' deployments/avalanche/production/vault/latest.json)
cast call $PORTFOLIO_VAULT "lastNav()(uint256)" --rpc-url $AVALANCHE_RPC
# Expect: 1000000 (non-zero).
```

## 5. LMS handoff (local) <a id="5-lms-handoff-local"></a>

Replace
[§8 Copy SA addresses into LMS](production_deployment_runbook.md#8-copy-sa-addresses-into-lms)
with the local equivalent: point your local LMS dev stack (see
`tare-lms` repo, `pnpm --filter @tare/backend dev`) at the local addresses by
exporting them in its `.env`. The eight SA addresses from the roles manifest
(`pnpm tare-contracts manifest show`) plus the contract addresses from the §4
deployment artifacts are all you need.

## 6. Run production steps 9–10 <a id="6-run-production-steps-9-10"></a>

Follow
[§9 Harden](production_deployment_runbook.md#9-harden) and
[§10 Verify deployment](production_deployment_runbook.md#10-verify-deployment)
as written. `verify-deployment` is the rehearsal's
own hard gate — a failed assertion here is the whole point of the rehearsal.

## 7. Skip production steps 11–13 <a id="7-skip-production-steps-11-13"></a>

Do **not** run:

- §11 (final Safe ownership transitions) — there is no real signer set; the
  stand-in Safes are single-owner. This covers §11.1 (Admin Safe raise),
  §11.2 (Proposer Safe raise), and §11.3 (Hot-Proxy 1-of-2 rotation).
- §12 (publish `@tare-io/tare-contracts`) — rehearsal artifacts should not be
  released.
- §13 (LMS handoff and funding) — local LMS already wired in §5; no funding
  required.

## 8. Tear down <a id="8-tear-down"></a>

```bash
# Stop the background anvil process.
kill %1
# Drop the rehearsal deployment artifacts so they don't accidentally land in a
# PR (git clean catches untracked files like a first-ever roles manifest):
git checkout -- deployments/avalanche/production/
git clean -fd deployments/avalanche/production/
# Reset deployment-configs.ts to the placeholder address if you changed it for
# the rehearsal:
git checkout -- cli/lib/deployment-configs.ts
```

If you used `--name rehearsal` instead of `production` in §2.1, swap the
`deployments/avalanche/production/` paths above for `deployments/avalanche/rehearsal/`.
