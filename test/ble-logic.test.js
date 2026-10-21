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
// The regression this whole change is about: a phone that stopped advertising
// while sitting on the desk must NOT be reported as out of range.
// ---------------------------------------------------------------------------

test("stale reading but the phone was last seen close: not out of range", () => {
  const o = opts({
    connected: false,
    rssi: -45,
    rssiAt: NOW - 10 * 60 * 1000, // ten minutes without an advertisement
    advAt: NOW - 10 * 60 * 1000,
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
// BlueZ removes the RSSI property as soon as it stops seeing the device, so
// "no property" must never be read as "the phone left". This is the case
// that made the plugin lock the laptop with the phone on the desk.
// ---------------------------------------------------------------------------

test("no measurement at all: hold the state instead of reporting out of range", () => {
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

test("a known value survives a silent advertisement channel", () => {
  const o = opts({
    connected: false,
    rssi: -45,
    rssiAt: NOW - 90 * 60 * 1000, // the phone has been silent for 1.5 h
    advAt: NOW - 90 * 60 * 1000,
    advertisingEverObserved: true,
  })
  assert.equal(Ble.phoneLost(o), false)
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
    advAt: NOW - STALE - 1,
  })
  assert.equal(Ble.presenceLevel(o), "unknown")
  assert.equal(Ble.presenceSource(o), "none")
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
  assert.equal(Ble.phoneLost(o), false) // not "lost" ...
  assert.equal(Ble.phonePresent(o), false) // ... but not proof of presence
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
  // ...but the value still decides, so the phone is not reported as gone.
  assert.equal(Ble.phoneLost(o), false)
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
