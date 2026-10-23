// Unit tests for the presence logic mirrored in BleLogic.js.
// Run with: node --test test/ble-logic.test.js
const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// BleLogic.js starts with `.pragma library`, a QML directive node cannot
// parse. Strip it and evaluate the file in an isolated context so the
// module.exports branch at the bottom is what we get back.
function loadBleLogic() {
  const src = fs
    .readFileSync(path.join(__dirname, "..", "BleLogic.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, "")
  const module = { exports: {} }
  vm.runInNewContext(src, { module, exports: module.exports })
  return module.exports
}

const Ble = loadBleLogic()

const NOW = 1_700_000_000_000
const STALE = 45_000
const THRESHOLD = -80
const ABSENT = 45_000

function opts(over) {
  return Object.assign(
    {
      now: NOW,
      connected: true,
      rssi: -60,
      rssiAt: NOW - 1000,
      rssiEverObserved: true,
      advAt: NOW - 1000,
      advertisingEverObserved: true,
      threshold: THRESHOLD,
      staleWindowMs: STALE,
      absentAfterMs: ABSENT,
      since: 0,
      warmup: false,
    },
    over || {},
  )
}

// ---------------------------------------------------------------------------
// Core rule: the RSSI *value* decides, the threshold separates near from far.
// ---------------------------------------------------------------------------

test("value above the threshold: the phone is here", () => {
  assert.equal(Ble.phoneLost(opts({ connected: false, rssi: -45 })), false)
})

test("value below the threshold: the phone is out of range", () => {
  assert.equal(Ble.phoneLost(opts({ connected: false, rssi: -95 })), true)
})

test("value exactly on the threshold counts as present", () => {
  assert.equal(Ble.phoneLost(opts({ connected: false, rssi: THRESHOLD })), false)
})

// ---------------------------------------------------------------------------
// A gap between two advertisements is not yet an absence: while the silence
// is shorter than the absence window, the last known value still decides.
// This is the case that used to produce a bogus "Phone out of range"
// notification with the phone lying on the desk.
// ---------------------------------------------------------------------------

test("a fresh reading above the threshold: the phone is here", () => {
  const o = opts({
    connected: false,
    rssi: -45,
    rssiAt: NOW - 20 * 1000, // still fresh
    advAt: NOW - 20 * 1000,
  })
  assert.equal(Ble.phoneLost(o), false)
  assert.equal(Ble.presenceLevel(o), "rssi")
})

test("with a wider absence window the last value keeps deciding during the silence", () => {
  // The reading is older than the freshness window, but the silence has not
  // yet outlasted the absence window: the remembered value still decides.
  const o = opts({
    connected: false,
    rssi: -45,
    rssiAt: NOW - 60 * 1000,
    advAt: NOW - 60 * 1000,
    absentAfterMs: 300000,
  })
  assert.equal(Ble.phoneLost(o), false)
  assert.equal(Ble.presenceLevel(o), "rssi-stale")
})

test("stale reading and the phone was last seen far: still out of range", () => {
  const o = opts({
    connected: false,
    rssi: -95,
    rssiAt: NOW - 10 * 60 * 1000,
    advAt: NOW - 10 * 60 * 1000,
  })
  assert.equal(Ble.phoneLost(o), true)
})

test("warm-up: no evidence yet, never report out of range", () => {
  const o = opts({
    connected: false,
    rssi: 0,
    rssiAt: 0,
    rssiEverObserved: false,
    warmup: true,
  })
  assert.equal(Ble.phoneLost(o), false)
})

// ---------------------------------------------------------------------------
// No signal at all is out of range.
//
// A phone that switches its radio off cannot send us a weak signal — it
// simply stops answering. That silence is the only evidence left, and it is
// treated exactly like a measurement below the threshold: grace period,
// notification, lock.
// ---------------------------------------------------------------------------

test("no measurement at all and no reference point: hold the state", () => {
  const o = opts({
    connected: false,
    rssi: 0,
    rssiAt: 0,
    rssiEverObserved: false,
    advAt: 0,
    advertisingEverObserved: false,
  })
  assert.equal(Ble.phoneLost(o), false)
  assert.equal(Ble.presenceLevel(o), "unknown")
})

test("a silence longer than the absence window counts as out of range", () => {
  const o = opts({
    connected: false,
    rssi: -45, // the last value said "close"…
    rssiAt: NOW - 60 * 1000,
    advAt: NOW - 60 * 1000,
  })
  assert.equal(Ble.phoneLost(o), true) // …but the phone stopped answering
  assert.equal(Ble.presenceLevel(o), "absent")
})

test("the absence window is configurable", () => {
  const silent = {
    connected: false,
    rssi: -45,
    rssiAt: NOW - 60 * 1000,
    advAt: NOW - 60 * 1000,
  }
  // 60 s of silence: outside the default window, inside a wider one.
  assert.equal(Ble.phoneLost(opts(silent)), true)
  assert.equal(Ble.phoneLost(opts(Object.assign({}, silent, { absentAfterMs: 120000 }))), false)
  // 0 = the first missing heartbeat is enough.
  assert.equal(Ble.phoneLost(opts(Object.assign({}, silent, { absentAfterMs: 0 }))), true)
})

test("a live ACL link prevents the absence from firing", () => {
  // The BR/EDR link is proof of presence on its own: a quiet BLE beacon
  // while the phone sits on the desk must never read as absence.
  const o = opts({
    connected: true,
    rssi: -45,
    rssiAt: NOW - 60 * 60 * 1000,
    advAt: NOW - 60 * 60 * 1000,
  })
  assert.equal(Ble.phoneLost(o), false)
  assert.equal(Ble.presenceLevel(o), "acl")
})

test("a recent advertisement prevents the absence from firing", () => {
  const o = opts({
    connected: false,
    rssi: -45,
    rssiAt: NOW - 60 * 60 * 1000, // the reading is ancient
    advAt: NOW - 1000, // but an advertisement just arrived
  })
  assert.equal(Ble.phoneLost(o), false)
  assert.equal(Ble.presenceLevel(o), "rssi-stale") // the reading is old, the adv is fresh
})

test("the silence clock starts when we began waiting for a phone we never heard", () => {
  const o = opts({
    connected: false,
    rssi: 0,
    rssiAt: 0,
    rssiEverObserved: false,
    advAt: 0,
    advertisingEverObserved: false,
    since: NOW - 60 * 1000,
  })
  assert.equal(Ble.phoneLost(o), true)
  assert.equal(Ble.presenceLevel(o), "absent")
})

test("the silence age is measured from the last piece of evidence", () => {
  assert.equal(Ble.silenceAgeMs(opts({ rssiAt: NOW - 5000, advAt: 0 })), 5000)
  // The newest evidence wins.
  assert.equal(Ble.silenceAgeMs(opts({ rssiAt: NOW - 5000, advAt: NOW - 1000 })), 1000)
  // No evidence at all: the age is unknown, not zero.
  assert.equal(Ble.silenceAgeMs(opts({ rssiAt: 0, advAt: 0 })), null)
  // Without a reference point there is nothing to measure.
  assert.equal(Ble.absentBySilence(opts({ rssiAt: 0, advAt: 0 })), false)
})

test("a known value survives a silent advertisement channel — until the window is over", () => {
  const o = opts({
    connected: false,
    rssi: -45,
    rssiAt: NOW - 90 * 60 * 1000, // the phone has been silent for 1.5 h
    advAt: NOW - 90 * 60 * 1000,
    advertisingEverObserved: true,
  })
  // 1.5 h of silence is way past the absence window: the phone is gone.
  assert.equal(Ble.phoneLost(o), true)
  assert.equal(Ble.presenceLevel(o), "absent")
})

// ---------------------------------------------------------------------------
// ACL
// ---------------------------------------------------------------------------

test("ACL up with a fresh strong RSSI: phone is present", () => {
  assert.equal(Ble.phoneLost(opts()), false)
  assert.equal(Ble.presenceLevel(opts()), "acl")
})

test("ACL up with a stale RSSI: the link itself proves presence", () => {
  const o = opts({ rssiAt: NOW - STALE - 1 })
  assert.equal(Ble.phoneLost(o), false)
})

test("ACL up with a fresh RSSI below threshold: phone is out of range", () => {
  assert.equal(Ble.phoneLost(opts({ rssi: -95 })), true)
})

// ---------------------------------------------------------------------------
// Freshness
// ---------------------------------------------------------------------------

test("a reading inside the window is fresh", () => {
  assert.equal(Ble.isRssiFresh(opts({ rssiAt: NOW - 1000 })), true)
})

test("a reading outside the window is stale", () => {
  assert.equal(Ble.isRssiFresh(opts({ rssiAt: NOW - STALE - 1 })), false)
})

test("no reading at all is never fresh", () => {
  assert.equal(Ble.isRssiFresh(opts({ rssiAt: 0 })), false)
})

test("presence level: fresh reading wins over the advertisement cache", () => {
  const o = opts({ connected: false, advAt: NOW - STALE - 1 })
  assert.equal(Ble.presenceLevel(o), "rssi")
})

test("presence level: advertisement only", () => {
  const o = opts({
    connected: false,
    rssi: 0,
    rssiAt: 0,
    rssiEverObserved: false,
    advAt: NOW - 1000,
  })
  assert.equal(Ble.presenceLevel(o), "adv")
})

test("presence level: nothing at all", () => {
  const o = opts({
    connected: false,
    rssi: 0,
    rssiAt: 0,
    rssiEverObserved: false,
    advAt: 0,
    advertisingEverObserved: false,
  })
  assert.equal(Ble.presenceLevel(o), "unknown")
  assert.equal(Ble.presenceSource(o), "none")
})

test("presence level: the last advertisement is older than the absence window", () => {
  const o = opts({
    connected: false,
    rssi: 0,
    rssiAt: 0,
    rssiEverObserved: false,
    advAt: NOW - STALE - 1,
    advertisingEverObserved: true,
  })
  assert.equal(Ble.presenceLevel(o), "absent")
})

// ---------------------------------------------------------------------------
// Unlocking is stricter than locking: it needs fresh, positive evidence.
// ---------------------------------------------------------------------------

test("unlock needs fresh evidence: a stale strong reading is not enough", () => {
  const o = opts({
    connected: false,
    rssi: -45,
    rssiAt: NOW - 10 * 60 * 1000,
    advAt: NOW - 10 * 60 * 1000,
  })
  assert.equal(Ble.phoneLost(o), true) // out of range: the phone is silent ...
  assert.equal(Ble.phonePresent(o), false) // ... but not proof that it is back
})

test("unlock: a fresh strong reading is proof of presence", () => {
  const o = opts({ connected: false, rssi: -45, rssiAt: NOW - 1000 })
  assert.equal(Ble.phonePresent(o), true)
})

test("unlock: a fresh weak reading is not proof of presence", () => {
  const o = opts({ connected: false, rssi: -95, rssiAt: NOW - 1000 })
  assert.equal(Ble.phonePresent(o), false)
})

test("unlock: a live ACL link is proof of presence", () => {
  assert.equal(Ble.phonePresent(opts({ connected: true })), true)
})

// ---------------------------------------------------------------------------
// Persistence across a shell restart.
//
// The reading has to survive a restart (BlueZ drops the RSSI property the
// moment it stops seeing the device), but it has to survive it *honestly*:
// the restored age must be the real age, otherwise a reading from minutes
// ago looks fresh and can unlock the laptop on its own.
// ---------------------------------------------------------------------------

test("the RSSI age is computed when it is asked for", () => {
  assert.equal(Ble.rssiAgeMs(NOW - 5000, NOW), 5000)
  assert.equal(Ble.rssiAgeMs(0, NOW), 0)
  assert.equal(Ble.rssiAgeMs(NOW + 5000, NOW), 0) // clock skew never goes negative
})

test("a persisted absolute timestamp keeps its exact age across a restart", () => {
  const measuredAt = NOW - 120000
  const restored = Ble.restoreRssiAt({ lastRssi: -50, lastRssiAt: measuredAt }, NOW, STALE)
  assert.equal(restored, measuredAt)
  assert.equal(Ble.rssiAgeMs(restored, NOW), 120000)

  // ...and a reading that old is not proof of presence. The advertisement
  // channel is silent too — that is the realistic case: the beacon is quiet.
  const o = opts({
    connected: false,
    rssi: -50,
    rssiAt: restored,
    advAt: NOW - 120000,
  })
  assert.equal(Ble.phonePresent(o), false)
})

test("a persisted relative age is restored as a timestamp", () => {
  const restored = Ble.restoreRssiAt({ lastRssi: -50, lastRssiAgeSec: 30 }, NOW, STALE)
  assert.equal(restored, NOW - 30000)
  assert.equal(Ble.rssiAgeMs(restored, NOW), 30000)
})

test("an unknown age is restored as stale, never as fresh", () => {
  const restored = Ble.restoreRssiAt({ lastRssi: -50, lastRssiAgeSec: 0 }, NOW, STALE)
  assert.ok(Ble.rssiAgeMs(restored, NOW) > STALE)
  const o = opts({
    connected: false,
    rssi: -50,
    rssiAt: restored,
    advAt: NOW - 120000,
  })
  assert.equal(Ble.isRssiFresh(o), false)
  assert.equal(Ble.phonePresent(o), false)
  // The reading is older than the absence window, so the phone counts as
  // gone — but a restored reading can never unlock the laptop on its own.
  assert.equal(Ble.phoneLost(o), true)
})

test("round trip: save the real age, restore it, and it is still the real age", () => {
  const measuredAt = NOW - 90000
  const saved = { lastRssi: -50, lastRssiAt: measuredAt, lastRssiAgeSec: 90 }
  const restored = Ble.restoreRssiAt(saved, NOW, STALE)
  assert.equal(Ble.rssiAgeMs(restored, NOW), 90000)
  assert.equal(Ble.presenceLevel(opts({ connected: false, rssi: -50, rssiAt: restored })), "rssi-stale")
})

// ---------------------------------------------------------------------------
// The grace period: the delay between "the reading crossed the threshold"
// and "the notification appears and the lock procedure starts".
// ---------------------------------------------------------------------------

function grace(state, over) {
  return Object.assign(
    {
      now: NOW,
      lost: true,
      lostSince: 0,
      backSince: 0,
      lostEntryMs: 5000,
      backStableMs: 3000,
    },
    over || {},
  )
}

test("grace period: the reading just crossed the threshold, nothing happens yet", () => {
  const step = Ble.graceStep("ARMED", grace("ARMED", { now: NOW, lostSince: NOW }))
  assert.equal(step.action, "hold")
  assert.equal(step.lostSince, NOW)
})

test("grace period: the warning only fires once the delay has elapsed", () => {
  const lostSince = NOW - 4999
  assert.equal(
    Ble.graceStep("ARMED", grace("ARMED", { now: NOW, lostSince })).action,
    "hold",
  )
  assert.equal(
    Ble.graceStep("ARMED", grace("ARMED", { now: NOW, lostSince: NOW - 5000 })).action,
    "enter-warning",
  )
})

test("grace period: a short flap does not restart the delay", () => {
  // Out of range at T0, briefly back at T0+2s (less than backStableMs), then
  // out of range again: the absence is continuous, so the warning fires
  // 5 s after the *first* drop, not 5 s after the last one.
  const lostSince = NOW - 3000
  const step = Ble.graceStep("ARMED", grace("ARMED", { now: NOW, lostSince }))
  assert.equal(step.action, "hold")
  assert.equal(step.lostSince, lostSince) // the counter was not reset
})

test("REGRESSION: a stable return resets the counter, so the next episode waits again", () => {
  // Out of range at T0 ...
  let step = Ble.graceStep("ARMED", grace("ARMED", { now: NOW, lostSince: NOW }))
  assert.equal(step.action, "hold")
  assert.equal(step.lostSince, NOW)

  // ... the phone comes back and stays back for 3 s: the counter is cleared.
  step = Ble.graceStep("ARMED", grace("ARMED", { now: NOW + 4000, lost: false, backSince: NOW + 1000 }))
  assert.equal(step.action, "hold")
  assert.equal(step.lostSince, 0)

  // The next drop must wait for the full grace period again — it must not
  // fire the notification instantly, the way it did before the fix.
  step = Ble.graceStep("ARMED", grace("ARMED", { now: NOW + 5000, lost: true, lostSince: 0 }))
  assert.equal(step.action, "hold")
  assert.equal(step.lostSince, NOW + 5000)

  step = Ble.graceStep("ARMED", grace("ARMED", { now: NOW + 10000, lost: true, lostSince: NOW + 5000 }))
  assert.equal(step.action, "enter-warning")
})

test("a warning is cancelled only after the phone has been stably back", () => {
  let step = Ble.graceStep("WARNING", grace("WARNING", { now: NOW, lost: false, backSince: NOW }))
  assert.equal(step.action, "hold") // just came back, not stable yet

  step = Ble.graceStep("WARNING", grace("WARNING", { now: NOW + 3000, lost: false, backSince: NOW }))
  assert.equal(step.action, "cancel-warning")
  assert.equal(step.lostSince, 0)
})

test("a flap does not cancel the warning", () => {
  const step = Ble.graceStep("WARNING", grace("WARNING", { now: NOW, lost: false, backSince: NOW }))
  assert.equal(step.action, "hold")
})

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

test("RSSI parsing", () => {
  assert.equal(Ble.parseBusctlRssi("i -65\n"), -65)
  assert.equal(Ble.parseBusctlRssi("i -65"), -65)
  assert.equal(Ble.parseBusctlRssi(""), null)
  assert.equal(Ble.parseBusctlRssi("No such property"), null)
})

test("RSSI formatting", () => {
  assert.equal(Ble.formatRssi(-65), "-65 dBm")
  assert.equal(Ble.formatRssi(0), "—")
  assert.equal(Ble.formatRssi(null), "—")
})

test("signal bars", () => {
  assert.equal(Ble.signalBars(-45), 4)
  assert.equal(Ble.signalBars(-65), 3)
  assert.equal(Ble.signalBars(-75), 2)
  assert.equal(Ble.signalBars(-85), 1)
  assert.equal(Ble.signalBars(-120), 0)
})

// ---------------------------------------------------------------------------
// busctl fallback: a cached RSSI value is not proof of life
// ---------------------------------------------------------------------------

test("the first polled value is not proof of life (it may be a cached value)", () => {
  assert.equal(Ble.pollProvesLife(0, -51), false)
  assert.equal(Ble.pollProvesLife(undefined, -51), false)
})

test("a repeated polled value is not proof of life", () => {
  assert.equal(Ble.pollProvesLife(-51, -51), false)
})

test("a changed polled value is proof of life", () => {
  assert.equal(Ble.pollProvesLife(-51, -55), true)
})

test("an unusable reading is never proof of life", () => {
  assert.equal(Ble.pollProvesLife(-51, 0), false)
  assert.equal(Ble.pollProvesLife(-51, null), false)
})
