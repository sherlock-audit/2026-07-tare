import { test } from "node:test"
import assert from "node:assert/strict"
import {
  assertSendersSettableAtDeploy,
  planSenderUpdate,
  resolveAuthorizedSenders,
  resolveForwarder,
} from "../lib/forwarder.js"

const FORWARDER = "0x1000000000000000000000000000000000000004"
const OTHER = "0x1000000000000000000000000000000000000005"
const DEPLOYED = "0x1000000000000000000000000000000000000006"
const DEPLOYER = "0x1000000000000000000000000000000000000007"
const ADMIN_SAFE = "0x1000000000000000000000000000000000000008"
const RELAYER = "0x1000000000000000000000000000000000000009"

test("resolves from the flag, then the manifest, then the deployment", () => {
  assert.equal(resolveForwarder({ option: FORWARDER, manifest: OTHER, deployment: DEPLOYED }), FORWARDER)
  assert.equal(resolveForwarder({ manifest: OTHER, deployment: DEPLOYED }), OTHER)
  assert.equal(resolveForwarder({ deployment: DEPLOYED }), DEPLOYED)
})

test("a deployment with no Forwarder and no override is an error", () => {
  assert.throws(() => resolveForwarder({ deployment: null }), /no Forwarder address/)
})

test("a malformed address names the option it came from", () => {
  assert.throws(() => resolveForwarder({ option: "0xnope", deployment: null }), /--forwarder/)
  assert.throws(() => resolveForwarder({ manifest: "0xnope", deployment: null }), /manifest forwarder/)
})

test("a sender set is checksummed, non-empty and free of duplicates", () => {
  assert.deepEqual(resolveAuthorizedSenders([RELAYER.toUpperCase().replace("0X", "0x"), ` ${OTHER} `]), [
    RELAYER,
    OTHER,
  ])
  assert.throws(() => resolveAuthorizedSenders([]), /at least one --sender/)
  assert.throws(() => resolveAuthorizedSenders([RELAYER, RELAYER]), /duplicate --sender/)
  assert.throws(() => resolveAuthorizedSenders(["0xnope"]), /--sender/)
})

test("senders are only settable at deploy while the deployer owns the Forwarder", () => {
  assertSendersSettableAtDeploy({ initialOwner: DEPLOYER, deployer: DEPLOYER, senders: [RELAYER] })
  assertSendersSettableAtDeploy({ initialOwner: ADMIN_SAFE, deployer: DEPLOYER, senders: [] })
  assert.throws(
    () => assertSendersSettableAtDeploy({ initialOwner: ADMIN_SAFE, deployer: DEPLOYER, senders: [RELAYER] }),
    /forwarder set-senders/
  )
})

test("a sender update routes through the signer, the owning Safe, or neither", () => {
  const base = { forwarder: FORWARDER, signer: DEPLOYER, ownerIsSafe: false, signerOwnsSafe: false, safeThreshold: 0 }

  assert.deepEqual(planSenderUpdate({ ...base, owner: DEPLOYER.toLowerCase() }), { via: "signer" })
  assert.deepEqual(
    planSenderUpdate({ ...base, owner: ADMIN_SAFE, ownerIsSafe: true, signerOwnsSafe: true, safeThreshold: 1 }),
    { via: "safe", safe: ADMIN_SAFE }
  )
  assert.throws(() => planSenderUpdate({ ...base, owner: OTHER }), /neither the signer .* nor a Safe/)
  assert.throws(
    () => planSenderUpdate({ ...base, owner: ADMIN_SAFE, ownerIsSafe: true, safeThreshold: 1 }),
    /is not an owner of the owning Safe/
  )
  assert.throws(
    () => planSenderUpdate({ ...base, owner: ADMIN_SAFE, ownerIsSafe: true, signerOwnsSafe: true, safeThreshold: 3 }),
    /threshold 3 — submit setAuthorizedSenders through the Safe UI/
  )
})
