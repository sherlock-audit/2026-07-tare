# Production Deployment — Issues Log

Tracking issues encountered while running the production deployment on
Avalanche C-Chain per
[production_deployment_runbook.md](production_deployment_runbook.md), plus the
fixes needed. Format mirrors
[anvil_rehearsal_issues.md](anvil_rehearsal_issues.md).

## Status

- Started: 2026-08-19
- Current step: §9 — Verify deployment (hard gate)

## Issues

| #   | Runbook step           | Symptom                                                                                                                                                                                                                   | Root cause                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Fix                                                                                                                                                                                                                                                                                                                                               | Status               |
| --- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| 1   | §1.4 Record Safes      | `manifest set adminSafe 0x5DFf…2684` fails: `has no code on chain (use --eoa if it is one)` — but the Safe verifiably has code on Avalanche mainnet (43114)                                                               | Stale `TARE_DEPLOYMENT_NAME=staging` exported in the operator's shell from a previous staging session. dotenv ([cli/index.ts](../../cli/index.ts)) never overrides already-exported vars, so the CLI resolved `avalanche-staging` → chain `avalancheFuji` → checked the Safe's code on **Fuji**, where it has none. Manual `cast chain-id --rpc-url $AVALANCHE_RPC` checks passed because the staging config reads a different env var (`AVALANCHE_FUJI_RPC`), masking the mismatch. | `unset TARE_DEPLOYMENT_NAME TARE_CHAIN` (or re-export the production values) and re-run. No stray writes landed in the staging manifest (`deployments/avalancheFuji/staging/` untouched per `git status`).                                                                                                                                        | Fixed (operator env) |
| 2   | §1.4 Record Safes      | `roles/latest.json` silently carried the previous deployment's fields into the new one: `hotProxy` (a Safe the current topology no longer has), all eight role SAs, and `salt …:v2` survived into the fresh `0.5.36.json` | `writeRolesManifest` merges field-by-field into the existing `latest.json` — a redeployment starts from the previous deployment's manifest, and `manifest set` only overwrites the fields it is given. Left in place, §5 `create-role-accounts` would have **skipped all eight roles** (idempotency reads the manifest) and §6/§7 would have wired the old deployment's SAs — owned by the old Operational Management Safe, i.e. accounts the new governance does not control.       | Hand-cleaned both manifest files: dropped `hotProxy` (no reader anywhere in `cli/`/`script/`/`src/`) and the eight stale `*Sa` fields; reset `salt` to `…:v1` (fresh Timelock instance in §2, so no operation-hash collision is possible; `:vN` bumps should only signal a §7 re-run). Verified by diff against the v0.5.22 manifest (`def953c`). | Fixed (manifest)     |
| 3   | §9.1 Verify deployment | `verify-deployment` fails: `error: too many arguments for 'verify-deployment'. Expected 0 arguments but got 1.`                                                                                                           | `$WHITELISTER_SAFE` was empty — the §9.1 command interpolates it, but no earlier runbook step ever says to `export WHITELISTER_SAFE=…` (unlike `TIMELOCK`/`ADMIN_SAFE`, exported in §2). With the var empty, zsh drops the word entirely, so `--whitelister` swallowed `--timelock-min-delay` as its value and `129600` became a stray positional arg.                                                                                                                               | Exported the value and re-ran. Runbook §9.1 now includes an explicit `export WHITELISTER_SAFE=0x…` line (value from deployment notes, deliberately not read from the manifest the deploy wrote — the hard gate's expectations stay independent).                                                                                                  | Fixed (runbook)      |

## Backlog / enhancement ideas

- **CLI — print the resolved deployment on every command.** Issue #1 was
  silent: nothing in the CLI output revealed it was operating on
  `avalancheFuji/staging` instead of `avalanche/production`. Have
  `resolveDeployment` (or `outputResult`) always print the resolved
  `<chain>/<shortName>` (and ideally the chain id it verified against) so a
  stale `TARE_CHAIN`/`TARE_DEPLOYMENT_NAME` is caught by eye on the first
  command, not after a confusing failure — or worse, after a cross-deployment
  write that succeeds.
- **Runbook §1.3 — warn about pre-exported `TARE_*` vars.** The env section
  should note that shell-exported `TARE_CHAIN`/`TARE_DEPLOYMENT_NAME` (e.g.
  from a prior staging session) take precedence over `.env` because dotenv
  does not override existing environment variables, and instruct operators to
  `unset` or verify them before starting.
- **Prevent stale-manifest carryover on redeployment (issue #2).** Two layers:
  - _Runbook §1.4 (cheap, docs-only):_ add a first step for redeployments —
    archive the previous manifest and start clean, e.g.
    `git rm deployments/<chain>/<name>/roles/latest.json` (the old
    version-pinned copy stays in git as the durable record), then verify with
    `manifest show` that the file is absent before recording the new Safes.
    A stale-field review by eye is not enough — issue #2's fields all looked
    plausible.
  - _CLI (structural):_ make the manifest **version-keyed**: writers write the
    `<pkg-version>.json` copy and readers (`create-role-accounts`,
    `setup-smart-accounts`, `grant-roles`) load the file matching the current
    `package.json` version, treating a missing file as an empty manifest.
    A new package version then structurally starts from a blank manifest —
    no carryover possible — while `latest.json` remains a generated
    convenience copy for consumers. Alternative smaller guard: `manifest set`
    refuses to write when the existing manifest's `version` differs from the
    current package version, with an explicit `manifest reset` (archive +
    start empty) as the sanctioned path.
