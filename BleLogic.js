.pragma library

// Parse the stdout of `busctl get-property ... RSSI`. Format is "i -65\n".
// Returns null on anything unparseable so the caller can ignore it without
// losing the previous reading.
function parseBusctlRssi(stdout) {
    if (!stdout) return null
    var trimmed = String(stdout).trim()
    if (!trimmed) return null
    var parts = trimmed.split(/\s+/)
    if (parts.length < 2) return null
    var n = parseInt(parts[1], 10)
    if (isNaN(n)) return null
    return n
}

// Render RSSI for the popup. Returns "—" when the value is missing.
function formatRssi(rssi) {
    if (rssi === null || rssi === undefined || rssi === 0) return "—"
    return rssi + " dBm"
}

// 0–4 bars for the popup. Bucket roughly matches consumer expectations:
//   -90+  faint      → 1 bar
//   -80..-89 weak    → 2
//   -70..-79 fair    → 3
//   -69..-60 good    → 4
//   -60..-30 strong  → 4 (cap)
function signalBars(rssi) {
    if (rssi === null || rssi === undefined) return 0
    if (rssi >= -60) return 4
    if (rssi >= -70) return 3
    if (rssi >= -80) return 2
    if (rssi >= -90) return 1
    return 0
}

// Is the last RSSI reading recent enough to act on?
//
// "Fresh" used to mean "the value changed recently", because with a regular
// (unfiltered) BlueZ discovery session the RSSI property is only republished
// when the value moves by 8 dBm — so a change was the only evidence that a
// new advertisement had arrived.
//
// With the filtered-discovery helper the RSSI is republished on *every*
// advertisement, so freshness now simply means "an advertisement was
// received recently". That is a genuine liveness signal.
function isRssiFresh(opts) {
    return !!opts.rssiEverObserved
        && !!opts.rssiAt
        && (opts.now - opts.rssiAt) <= (opts.staleWindowMs === undefined ? 45000 : opts.staleWindowMs)
}

// Age of a reading, in ms. 0 when there is no reading at all.
//
// A plain function on purpose: in QML a binding over Date.now() would only be
// re-evaluated when its dependencies change, so `Date.now() - lastRssiAt`
// would freeze at the moment the last reading arrived and then report an age
// of a few seconds forever. The age has to be computed at the moment it is
// used.
function rssiAgeMs(rssiAt, now) {
    if (!rssiAt) return 0
    var base = now === undefined ? Date.now() : now
    var age = base - rssiAt
    return age > 0 ? age : 0
}

// Restore the timestamp of a reading persisted by a previous shell session.
//
// The absolute timestamp is authoritative: it keeps the *exact* age across a
// restart, so a restored reading is "fresh" only when it really was measured
// moments ago. The relative age is only a legacy fallback.
//
// When neither is usable the age is unknown — and an unknown age must never
// look fresh. Such a reading is restored as older than the freshness window:
// it can still keep the phone from being reported as gone (the value decides,
// silence is not evidence), but it can never unlock the laptop on its own.
//
// opts:
//   saved          the parsed state object (may carry lastRssiAt / lastRssiAgeSec)
//   now            current timestamp in ms
//   staleWindowMs  the freshness window in ms (default 45000)
function restoreRssiAt(saved, now, staleWindowMs) {
    var window_ = staleWindowMs === undefined ? 45000 : staleWindowMs
    if (saved && typeof saved.lastRssiAt === "number" && saved.lastRssiAt > 0) {
        return saved.lastRssiAt
    }
    if (saved && typeof saved.lastRssiAgeSec === "number" && saved.lastRssiAgeSec > 0) {
        return now - saved.lastRssiAgeSec * 1000
    }
    return now - window_ - 1
}

// Which channel currently carries the presence decision.
//
//   "acl"         BR/EDR ACL is up — the link itself is the proof
//   "rssi"        a fresh RSSI reading (an advertisement arrived recently)
//   "rssi-stale"  the last RSSI is old, but we still know its value
//   "adv"         no RSSI ever, but a recent advertisement was observed
//   "unknown"     nothing recent at all
function presenceLevel(opts) {
    var staleWindow = opts.staleWindowMs === undefined ? 45000 : opts.staleWindowMs
    if (opts.connected) return "acl"
    if (isRssiFresh(opts)) return "rssi"
    if (opts.rssiEverObserved && opts.rssi !== 0 && opts.rssi !== undefined) return "rssi-stale"
    var advFresh = !!opts.advertisingEverObserved
        && !!opts.advAt
        && (opts.now - opts.advAt) <= staleWindow
    if (advFresh) return "adv"
    return "unknown"
}

// Backwards-compatible channel name used by the panel and the status IPC.
function presenceSource(opts) {
    var level = presenceLevel(opts)
    if (level === "rssi-stale") return "rssi-stale"
    if (level === "unknown") return "none"
    return level
}

// Decide whether the phone is "out of range". Mirrors Service.qml's
// phoneLost() so the same logic is unit-testable from node.
//
// The rule: **the RSSI value decides**, whether it is fresh or stale.
// Silence is never evidence of absence.
//
//   value >= threshold → the phone is here
//   value <  threshold → the phone is out of range
//   no value at all   → we know nothing → hold the current state
//
// Why that last line is not a cop-out: BlueZ *removes* the RSSI property
// from the device object as soon as it stops seeing the device, and this
// phone's beacon advertises in bursts with tens of minutes of silence in
// between. Treating "the property is gone" as "the phone left" is what
// made the plugin lock the laptop (and shout "Phone out of range") while
// the phone was lying on the desk.
//
// opts:
//   now              current timestamp in ms
//   connected        BR/EDR ACL is up
//   rssi             last RSSI value (0 = unknown)
//   rssiAt           timestamp of the last RSSI update (0 = never)
//   rssiEverObserved BlueZ returned at least one real reading
//   advAt            timestamp of the last *new* advertisement (0 = never)
//   advertisingEverObserved  BlueZ returned at least one advertisement
//   threshold        RSSI threshold in dBm
//   staleWindowMs    how long a reading stays "fresh" (default 45000)
//   warmup           true while we have no evidence yet (never alarm)
function phoneLost(opts) {
    var threshold = opts.threshold

    // Warm-up: right after arming there is no evidence at all. Reporting
    // "out of range" then would be a guess, so hold the current state until
    // the first real reading arrives.
    if (opts.warmup) return false

    // ACL up: the link proves the phone is here. Apply the threshold only
    // when the RSSI is fresh — a stale value must not override a live link.
    if (opts.connected) {
        if (!isRssiFresh(opts)) return false
        if (opts.rssi !== 0 && opts.rssi < threshold) return true
        return false
    }

    // The value decides — fresh or stale. A phone last seen close is never
    // reported as gone just because its beacon went quiet.
    if (opts.rssiEverObserved && opts.rssi !== 0 && opts.rssi !== undefined) {
        return opts.rssi < threshold
    }

    // No RSSI at all: there is no measurement to judge, and the silence of
    // the advertisement channel does not prove anything either (the beacon
    // has a burst duty cycle). Hold the current state instead of guessing.
    return false
}

// Positive evidence that the phone is back — used to gate the auto-unlock.
//
// Unlike phoneLost(), this requires *fresh* proof: an ACL link, a recent
// advertisement, or a recent RSSI above the threshold. A stale RSSI is
// deliberately not enough, so a phone that stayed silent after the user
// walked away can never unlock the laptop on its own.
function phonePresent(opts) {
    if (opts.connected) return true
    if (isRssiFresh(opts)) {
        return opts.rssi !== 0 && opts.rssi >= opts.threshold
    }
    var staleWindow = opts.staleWindowMs === undefined ? 45000 : opts.staleWindowMs
    var advFresh = !!opts.advertisingEverObserved
        && !!opts.advAt
        && (opts.now - opts.advAt) <= staleWindow
    return advFresh
}

// The out-of-range grace period.
//
// How long the reading has to stay out of range before the warning fires —
// and with it the notification and the whole lock procedure. A value that
// flaps around the threshold never reaches the grace period, so a single
// noisy sample can never lock the laptop.
//
// The counter stretches across short flaps: a 2 s reconnect does not reset
// it. Only a *stable* return does. Without that reset the counter survives
// the whole session and the next drop fires the warning immediately — with no
// grace at all.
//
// opts:
//   now            current timestamp in ms
//   lost           true when the phone is out of range
//   state          the current state ("ARMED", "WARNING", "WAITING", …)
//   lostSince      timestamp of the first out-of-range observation (0 = none)
//   backSince      timestamp of the first observation that the phone is back
//                  (0 = none)
//   lostEntryMs    the grace period before the warning fires (default 5000)
//   backStableMs   how long the phone must stay back before we believe it
//                  (default 3000)
//
// Returns { action, lostSince, backSince } where action is "enter-warning",
// "cancel-warning" or "hold".
function graceStep(state, opts) {
    var now = opts.now
    var lostEntryMs = opts.lostEntryMs === undefined ? 5000 : opts.lostEntryMs
    var backStableMs = opts.backStableMs === undefined ? 3000 : opts.backStableMs
    var lostSince = opts.lostSince || 0
    var backSince = opts.backSince || 0
    var warning = state === "WARNING" || state === "WAITING"

    if (opts.lost) {
        // Out of range. The "back" timer restarts from zero: the phone has to
        // be seen back for backStableMs before it counts as back.
        backSince = 0
        if (lostSince === 0) lostSince = now
        if (state === "ARMED" && (now - lostSince) >= lostEntryMs) {
            return { action: "enter-warning", lostSince: lostSince, backSince: backSince }
        }
        return { action: "hold", lostSince: lostSince, backSince: backSince }
    }

    // The phone is back. Require it to stay back for backStableMs before we
    // believe it: a 200 ms BR/EDR flap must neither cancel a warning nor
    // reset the out-of-range counter.
    if (backSince === 0) {
        return { action: "hold", lostSince: lostSince, backSince: now }
    }
    if ((now - backSince) < backStableMs) {
        return { action: "hold", lostSince: lostSince, backSince: backSince }
    }
    if (warning) {
        return { action: "cancel-warning", lostSince: 0, backSince: backSince }
    }
    // Back in ARMED: the next out-of-range episode starts a fresh grace
    // period instead of inheriting the counter of the previous one.
    return { action: "hold", lostSince: 0, backSince: backSince }
}

function stateLabel(state) {
    switch (state) {
        case "ARMED":    return "Armed"
        case "WARNING":   return "Phone out of range"
        case "WAITING":   return "Phone out, waiting for idle"
        case "LOCKING":   return "Locking…"
        case "LOCKED":    return "Locked"
        case "UNLOCKING": return "Unlocking…"
        case "DISARMED":  return "Disarmed"
        default:          return state || "—"
    }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parseBusctlRssi: parseBusctlRssi,
        formatRssi: formatRssi,
        signalBars: signalBars,
        isRssiFresh: isRssiFresh,
        rssiAgeMs: rssiAgeMs,
        restoreRssiAt: restoreRssiAt,
        presenceLevel: presenceLevel,
        presenceSource: presenceSource,
        phoneLost: phoneLost,
        phonePresent: phonePresent,
        graceStep: graceStep,
        stateLabel: stateLabel
    };
}
