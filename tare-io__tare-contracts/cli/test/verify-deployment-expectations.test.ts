import { test } from "node:test"
import assert from "node:assert/strict"
import { addressSetsEqual } from "../commands/verify-deployment/checker.js"
import { resolveExpectedForwarderSenders } from "../commands/verify-deployment/expectations.js"

const RELAYER = "0x1000000000000000000000000000000000000003"
const OTHER_RELAYER = "0x1000000000000000000000000000000000000004"
const FOUNDRY_ADMIN = "0x1000000000000000000000000000000000000005"

test("Forwarder senders resolve from options, environment, then foundry default", () => {
  assert.deepEqual(resolveExpectedForwarderSenders([OTHER_RELAYER], RELAYER, FOUNDRY_ADMIN), [OTHER_RELAYER])
  assert.deepEqual(resolveExpectedForwarderSenders(undefined, RELAYER, FOUNDRY_ADMIN), [RELAYER])
  assert.deepEqual(resolveExpectedForwarderSenders(undefined, undefined, FOUNDRY_ADMIN), [FOUNDRY_ADMIN])
  assert.throws(() => resolveExpectedForwarderSenders(undefined, undefined, undefined), /Forwarder sender is required/)
})

test("Forwarder sender expectations reject invalid and duplicate addresses", () => {
  assert.throws(() => resolveExpectedForwarderSenders([RELAYER, RELAYER], undefined, undefined), /duplicate --sender/)
  assert.throws(() => resolveExpectedForwarderSenders(["0xnope"], undefined, undefined), /--sender/)
})

test("address sets compare exactly without depending on order", () => {
  assert.equal(addressSetsEqual([RELAYER, OTHER_RELAYER], [OTHER_RELAYER, RELAYER]), true)
  assert.equal(addressSetsEqual([RELAYER], [RELAYER, OTHER_RELAYER]), false)
  assert.equal(addressSetsEqual([RELAYER, OTHER_RELAYER], [RELAYER]), false)
  assert.equal(addressSetsEqual([RELAYER, OTHER_RELAYER], [RELAYER, RELAYER]), false)
})