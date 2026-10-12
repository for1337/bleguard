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

// Decide whether the phone is "out of range". Mirrors the rules in
// Service.qml so the same logic is unit-testable from node.
function phoneLost(deviceConnected, lastRssi, lastRssiAt, threshold, now) {
    if (!deviceConnected) return true
    if (!lastRssiAt || (now - lastRssiAt) > 15000) return true
    if (lastRssi === null || lastRssi === undefined) return true
    if (lastRssi < threshold) return true
    return false
}

function stateLabel(state) {
    switch (state) {
        case "ARMED":    return "Armed"
        case "WARNING":   return "Phone out of range"
        case "WAITING":   return "Phone out, waiting for idle"
        case "LOCKING":   return "Locking…"
        case "LOCKED":    return "Locked"
        case "DISARMED":  return "Disarmed"
        default:          return state || "—"
    }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parseBusctlRssi: parseBusctlRssi,
        formatRssi: formatRssi,
        signalBars: signalBars,
        phoneLost: phoneLost,
        stateLabel: stateLabel
    };
}