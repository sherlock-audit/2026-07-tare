# CctpBridgeModule Specification

## Overview

A single-purpose Safe module that bridges a Safe's USDC to one hardcoded recipient on one hardcoded destination chain via Circle's CCTP v2 + Forwarding Service. It is the custody layer for the interim Erebor → Avalanche USDC rail: Erebor pushes plain USDC transfers to the intake Safe (Base mainnet), and any single Safe owner can flush the balance to the Avalanche Funder — and nowhere else.

Key architectural decision: every routing parameter (recipient, destination domain, token, messenger, fee allowances) is hardcoded — the route as compile-time constants, the Safe and recipient as deploy-time immutables. This is what makes single-signer execution safe: a compromised owner key can only send funds to the configured Tare-controlled recipient. Arbitrary fund movement out of the Safe still requires the Safe's normal threshold (≥ 2).

## Core Concepts

### Fixed route

The module knows exactly one route. The chain-level parameters are compile-time constants, so they sit in reviewed, verified source rather than deploy-time configuration:

- `USDC` — USDC on Base mainnet (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`)
- `TOKEN_MESSENGER` — Circle's CCTP v2 TokenMessenger on Base mainnet (`0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d`)
- `DESTINATION_DOMAIN` — CCTP domain of the destination (1 = Avalanche)
- `FLAT_FEE` — flat fee allowance (0.50 USDC) covering the Forwarding Service's destination gas
- `FAST_FEE_NUMERATOR` / `FAST_FEE_DENOMINATOR` — Fast-transfer protocol fee fraction (13 / 100 000 = 1.3 bps, Circle's current Base → Avalanche Fast rate)
- `FINALITY_THRESHOLD_STANDARD` (2000) / `FINALITY_THRESHOLD_FAST` (1000) — the two CCTP finality tiers

The per-deployment parameters are constructor immutables:

- `safe` — the intake Safe whose USDC is bridged
- `mintRecipient` — destination recipient (the Avalanche Funder), as bytes32

Changing any of these means deploying a new module (a code change for the constants), enabling it on the Safe, and disabling the old one — both threshold-gated Safe transactions. The trade-off of baking the route into code: the same bytecode cannot be rehearsed on a testnet.

### Single-owner execution

`bridge` is callable by any owner of the Safe (`safe.isOwner(msg.sender)`), directly from the owner's EOA. It does not go through `execTransaction`, so no threshold signatures are collected. The module executes the approve and burn from the Safe's context via `execTransactionFromModule`.

### Forwarding Service

The burn is submitted with Circle's reserved `cctp-forward` hook data and `destinationCaller = 0`. Circle's Forwarding Service then attests _and_ mints on the destination — Tare operates no destination-chain infrastructure. Standard finality (`bridge`) is the default; Fast finality (`bridgeFast`) is opt-in. Fast is best-effort: if the fast-transfer allowance is exhausted or the fee allowance falls short of Circle's live quote, the transfer silently settles at Standard finality (slower, still delivered).

### Fees

Fees (protocol fee + forwarding fee) are deducted _from_ the burned amount; the recipient nets `amount − feeExecuted`. The submitted `maxFee` is an allowance, not a charge — but the Forwarding Service consumes whatever headroom it is given, so the allowance is sized per mode as tightly as the mode requires:

- Standard (`bridge`): `maxFee = FLAT_FEE`. Standard transfers carry no protocol fee; the flat only funds the forwarder's destination gas.
- Fast (`bridgeFast`): `maxFee = FLAT_FEE + amount × FAST_FEE_NUMERATOR / FAST_FEE_DENOMINATOR`, adding Circle's 1.3 bps Fast protocol fee on top of the flat.

`FLAT_FEE` is deliberately small: delivery never depends on it. With `destinationCaller = 0`, anyone can permissionlessly submit the public attestation to the destination MessageTransmitter, so an underfunded allowance costs latency, never funds. The bridged amount must exceed the mode's `maxFee` so fees can never fully consume a transfer.

## Functions

### bridge

```solidity
function bridge(uint256 amount) external returns (uint256 bridgedAmount);
```

Bridge the Safe's USDC to the hardcoded recipient at Standard finality (the default mode).

- `amount` — USDC subunits to bridge, or `0` to sweep the Safe's entire USDC balance.

Validation:

- Caller must be an owner of the Safe (`NotSafeOwner`).
- The effective amount must exceed the mode's `maxFee` (`AmountTooSmall`).
- Both Safe-context calls must succeed (`ModuleCallFailed`), and the approve must not return `false` (`UsdcApprovalFailed`).

State changes (executed from the Safe via `execTransactionFromModule`):

1. `USDC.approve(TOKEN_MESSENGER, bridgedAmount)` — exact amount, fully consumed by the burn, so no allowance lingers.
2. `TOKEN_MESSENGER.depositForBurnWithHook(bridgedAmount, DESTINATION_DOMAIN, mintRecipient, USDC, 0, maxFee, minFinalityThreshold, FORWARDING_HOOK_DATA)` with the mode's fee allowance and finality threshold.

Events: `Bridged(caller, bridgedAmount, maxFee, fastMode, mintRecipient)`.

### bridgeFast

```solidity
function bridgeFast(uint256 amount) external returns (uint256 bridgedAmount);
```

Same flow as `bridge`, at Fast finality with the fee allowance raised by 1.3 bps of the amount (see Fees). Exposed as a separate function rather than a parameter so that Standard stays the default path (`bridge` keeps its signature) and the mode is legible from the call's selector. Fast is best-effort — a shortfall degrades to Standard, it never reverts or strands funds.

### Views

The per-deployment immutables are exposed as views (`safe`, `mintRecipient`), and the route as public constants (`USDC`, `TOKEN_MESSENGER`, `DESTINATION_DOMAIN`, `FLAT_FEE`, `FAST_FEE_NUMERATOR`, `FAST_FEE_DENOMINATOR`, `FINALITY_THRESHOLD_STANDARD`, `FINALITY_THRESHOLD_FAST`, `FORWARDING_HOOK_DATA` = Circle's `cctp-forward` magic bytes).

## Security Model

- **Theft resistance**: a single compromised owner key cannot redirect funds; the only reachable destination is the hardcoded recipient. Draining the Safe elsewhere requires the Safe threshold.
- **Residual risk — fee-dust destruction**: a compromised owner key cannot redirect funds, but it can destroy value by looping minimum-amount transfers (`amount` just above `maxFee`), letting the Forwarding Service consume nearly the entire balance as fees. Accepted because the intake Safe holds funds only transiently, every iteration is a visible on-chain transaction, and `disableModule` bounds the window.
- **Griefing resistance**: `bridge`/`bridgeFast` are owner-gated, so outsiders cannot force ill-timed transfers or shred the balance into fee-paying dust transfers. The `amount > maxFee` floor bounds fee-dominated transfers.
- **No standing approvals**: allowance is granted and consumed within one transaction. Circle's TokenMessenger and USDC are upgradeable proxies controlled by Circle; a standing approval would extend that trust indefinitely.
- **Kill switch**: the Safe disables the module (`disableModule`, threshold-gated). The module has no pause, no admin, and no owner of its own.
- **Trust assumptions**: Circle's TokenMessenger/USDC contracts, attestation service, and Forwarding Service behave honestly; `feeExecuted ≤ maxFee` is enforced by CCTP.

## Deployment & Operations

Deployed via `script/DeployCctpBridgeModule.s.sol` (CREATE3), which refuses to run on any chain other than Base mainnet (the hardcoded route only exists there), reads the Safe and recipient from `CCTP_BRIDGE_*` environment variables, and fail-fast asserts both on-chain after deployment. Operators invoke it through the CLI's `deploy cctp-bridge` command (see `cli/README.md`), which sets those variables from `--safe` / `--mint-recipient` flags. The CREATE3 salt includes the package version, so re-deploying under the same deployment name requires a version bump.

Rollout order:

1. Create the intake Safe on Base via the official Safe UI (threshold ≥ 2).
2. Deploy the module; the script pins the chain and verifies the Safe and recipient.
3. Verify the contract on the block explorer and independently re-check `mintRecipient` — a wrong recipient burns funds irrecoverably.
4. Enable the module on the Safe (threshold-gated Safe transaction).
5. **Canary bridge**: send a small USDC amount to the Safe, call `bridge(0)`, and confirm delivery on the destination before routing real funds.

### Stuck-transfer recovery

If a burn succeeds but forwarding stalls (e.g. the fee allowance no longer covers destination gas):

- A message can be re-attested within 24h via Circle's `POST /v2/reattest/{nonce}`.
- Because `destinationCaller = 0`, anyone can fetch the attestation and call `receiveMessage` on the destination MessageTransmitter; the mint still pays the hardcoded recipient.

Monitoring is manual: Circle's explorer / Iris API for delivery, plus intake-Safe and Funder balance checks.

## Out of Scope

- LMS integration (requests table, deposit matching, delivery polling) — deliberately removed; see the POC learnings in tare-lms `specs/cctp_bridge/`.
- Per-transfer/daily caps, pause machinery, multi-route registries — excluded to keep the attack surface minimal.
