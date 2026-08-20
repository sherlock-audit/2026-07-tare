# Forwarder Specification

## Overview

The Forwarder is a nonce-free hot relay that lets multiple authorized hot wallets execute
trusted calls concurrently. It exists to remove the throughput bottleneck of the HotProxy
Safe: every Safe `execTransaction` consumes the Safe's single sequential nonce, so all hot
operations routed through the HotProxy must be strictly serialized — read nonce, sign,
send, wait — even when they are independent. The Forwarder replaces that shared nonce with
plain EOA transactions: each authorized sender uses its own account nonce, so N senders can
submit N transactions in parallel.

The Forwarder occupies every relay position the HotProxy Safe used to:

- **Module delegate** — the only delegate registered on `TrustedCalls` and `TrustedSpender` for
  each role SA, so calls it forwards execute with the same whitelist and allowance restrictions
  as any other delegate (see [trusted-calls.md](./trusted-calls.md) and
  [trusted-spender.md](./trusted-spender.md)).
- **Safe owner slot** — `setup-smart-accounts` gives the Forwarder an owner slot on every
  role smart account, so it can confirm Safe transactions on behalf of its authorized
  senders. Where the final threshold is above 1 (2 in production) that slot is one required
  signature, not sufficient alone.
- **Vault operator** — `PortfolioVault.setOperator` on the shareholder SA, so deposits and
  redemptions route through it.

## Provenance and Reuse

The core relay is Chainlink's audited `AuthorizedForwarder` / `AuthorizedReceiver`
(operator-forwarder design). All source is fully vendored under
`contracts/vendor/chainlink/` — the two operator-forwarder files plus their transitive
dependencies (`ConfirmedOwnerWithProposal`, `IOwnable`, `IAuthorizedReceiver`, and the
OpenZeppelin 4.8.3 `Address` library) — each with a provenance header. Patches are
minimal and documented (pragma widening and import-path fixes); the logic is
byte-identical to the upstream release (`@chainlink/contracts` 1.3.0). No external
Chainlink submodule or remapping is required. `Forwarder.sol` is a zero-logic wrapper: it
adds no functions and only pins the upstream constructor's ownership-handoff arguments
(`recipient`, `message`) to zero, so a deployment can never carry a standing ownership
offer.

Inherited behavior:

- `forward(to, data)` / `multiForward(tos, datas)` — callable only by authorized senders;
  the target must be a contract; reverts bubble up to the caller.
- The token passed at construction (the protocol currency) is permanently blocked as a
  forward target.
- `setAuthorizedSenders(senders)` — owner-only, replaces the entire sender list atomically,
  so a key rotation cannot leave a stale sender authorized.
- `ownerForward` — the owner may forward arbitrary calls without being in the sender list.

## Authorization Model

| Actor              | Capability                                                                  |
| ------------------ | --------------------------------------------------------------------------- |
| Authorized senders | `forward`, `multiForward`; countersign Safe transactions (see below)        |
| Owner              | `setAuthorizedSenders` (atomic rotation), `ownerForward`, ownership handoff |
| Anyone             | Read the sender list                                                        |

The Forwarder itself grants no protocol permissions: what a forwarded call may do is
decided entirely by the receiving contract, which sees the Forwarder as `msg.sender` and
applies its own delegate checks. Removing the Forwarder as a delegate on a smart account
(`removeDelegate`) is the per-account kill switch; `setAuthorizedSenders([])` is the global
one.

## Safe Owner Slot

When the Forwarder holds an owner slot on a Safe, an authorized sender confirms Safe
transactions through it with `v = 1` approved-hash signatures naming the Forwarder as the
approving owner. The Safe accepts such a signature when the Forwarder is the caller or has
pre-approved the hash, giving two flows:

- **Forwarded execution (single transaction)** — the sender wraps the whole
  `Safe.execTransaction` call in `forward(safe, ...)`. Inside the Safe, `msg.sender` is the
  owner Forwarder, which counts as an implicit approval — no separate signature or approval
  step exists.
- **Approved hash (two transactions)** — the sender forwards a call to
  `Safe.approveHash(safeTxHash)`; anyone may then submit the `execTransaction` carrying the
  `v = 1` signature.

Both flows gate the confirmation on `isAuthorizedSender` at forward time, so rotating a
sender out takes effect immediately. The Forwarder deliberately implements no EIP-1271
interface: every owner-slot confirmation is an explicit on-chain `forward()` call, keeping
a single authorization funnel and zero custom signature-validation code.

## Deployment Status

The Forwarder **replaces** the HotProxy Safe as the relay rather than running beside it
(issue #218): `setup-smart-accounts` authorizes no other relay, so the Forwarder is the sole
`TrustedCalls`/`TrustedSpender` delegate on every role SA, holds the owner slot, and is the
shareholder SA's `PortfolioVault` operator.

Only `DeployLocal` deploys one, with the hot-safe owner key as its single authorized sender,
publishing the address in the `accounts` deployment manifest (`Forwarder`) and the baked
anvil manifest (`env.FORWARDER_ADDRESS`).

Outside local dev the Forwarder is deployed on its own rather than as part of the accounts
component: `deploy forwarder` (`script/DeployForwarder.s.sol`) writes a `forwarder` deployment
component and records the address in the roles manifest, which is where `setup-smart-accounts`
reads it. `--forwarder <address>` or a `forwarder` field in the setup manifest overrides it, and
the LMS takes `<PREFIX>FORWARDER_ADDRESS`. Local dev needs none of that — `DeployLocal` publishes
the address into the accounts manifest and both fall back to it.

`initialOwner` is a required constructor argument on every path, so ownership is never left with
the deployer by omission: a live deploy names the Admin Safe and never holds the sender-rotation
power at all, and `DeployLocal` names the deployer deliberately. Because `setAuthorizedSenders` is
owner-only, a Safe-owned Forwarder relays nothing until its owner authorizes the relayer EOA —
`forwarder set-senders` routes that through the owning Safe.

The `bench-forwarder` CLI command (since removed; see git history) validated the two paths
against each other on anvil: N trusted calls serialized through HotSafe `execTransaction`
versus the same N dispatched concurrently through `forward` ran ~5x faster with 4 senders,
even with zero RPC latency; the gap widens on a real network.
