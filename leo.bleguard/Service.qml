import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Wayland._IdleNotify

import "BleLogic.js" as Ble

Item {
  id: service

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string statePath: stateDir + "bleguard-state.json"

  // ---- Tunables ----------------------------------------------------------
  readonly property int graceSeconds: 10
  readonly property int idleThresholdSeconds: 30
  readonly property int rssiStaleMs: 6000
  readonly property int rssiPollMs: 2000
  readonly property int idlePollMs: 1000
  readonly property int lockCheckMs: 1000
  // Default RSSI floor. Tunable per-VM later; for now hardcoded.
  readonly property int defaultRssiThreshold: -85

  // RSSI → distance via log-distance path-loss model:
  //   d = 10^((txPower - rssi) / (10 * pathLoss))
  // txPower = measured RSSI at 1 m (typical iPhone ~ -59 dBm).
  // pathLoss = 2.0 free space, 2.5–3.5 indoor. We pick 2.5 as a sane middle.
  readonly property int txPowerDbm: -59
  readonly property real pathLoss: 2.5

  // History for the popup chart. Trimmed on every push to keep memory bounded.
  readonly property int historyWindowSeconds: 300
  readonly property int historyMaxPoints: 600

  // ---- State machine -----------------------------------------------------
  // One of: DISARMED, ARMED, WARNING, WAITING, LOCKING, LOCKED
  property string state: "DISARMED"
  // Timestamps as var (not int) — see comment on lastRssiAt.
  property var phoneLostSince: 0
  property var phoneBackSince: 0

  // ---- Live device tracking ---------------------------------------------
  // Re-resolved from Bluetooth.devices on demand — we don't hold the QObject
  // in a property because BlueZ churn destroys them and stale references
  // segfault Quickshell (see Omarchy bluetooth panel note).
  function findTargetDevice() {
    var list = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      if (d && d.address && d.address.toLowerCase() === service.targetMac.toLowerCase()) {
        return d
      }
    }
    return null
  }

  // ---- RSSI tracking (requires BlueZ discovery on) ------------------
  // Use var for timestamps — Date.now() in 2026 is ~1.79e12 ms since epoch,
  // which overflows QML's 32-bit int (max 2.1e9) and silently truncates to
  // the lower 32 bits (~664e6), giving nonsense time deltas.
  property var lastRssi: 0
  property var lastRssiAt: 0

  // Rolling RSSI history for the popup chart. Each entry: {t: ms, rssi: dBm}.
  // Only real busctl readings — never the synthetic `lastRssi = 0` we set
  // when the phone drops, otherwise the chart would lie about presence.
  property var rssiHistory: []
  readonly property real distanceMeters: {
    if (!lastRssi || lastRssi === 0) return 0
    return Math.pow(10, (service.txPowerDbm - lastRssi) / (10 * service.pathLoss))
  }

  function phoneLost() {
    var dev = service.findTargetDevice()
    var connected = dev ? dev.connected : false
    if (!connected) return true
    if (lastRssiAt && (Date.now() - lastRssiAt) > service.rssiStaleMs) return true
    if (lastRssi !== 0 && lastRssi < service.rssiThreshold) return true
    return false
  }

  // ---- Persisted state --------------------------------------------------
  PersistentProperties {
    id: persisted
    reloadableId: "leo-bleguard"
    property string targetMac: ""
    property bool armed: true
    property int rssiThreshold: service.defaultRssiThreshold

    onTargetMacChanged: service.saveSoon()
    onArmedChanged: service.saveSoon()
    onRssiThresholdChanged: service.saveSoon()
  }

  readonly property alias targetMac: persisted.targetMac
  readonly property alias armed: persisted.armed
  readonly property alias rssiThreshold: persisted.rssiThreshold

  Timer {
    id: saveTimer
    interval: 2000
    repeat: false
    onTriggered: service.flushState()
  }

  function saveSoon() { saveTimer.restart() }
  function flushStateNow() { saveTimer.stop(); service.flushState() }

  function flushState() {
    var payload = JSON.stringify({
      targetMac: persisted.targetMac,
      armed: persisted.armed,
      rssiThreshold: persisted.rssiThreshold
    })
    var script =
      "import json, os\n" +
      "p = " + JSON.stringify(statePath) + "\n" +
      "os.makedirs(os.path.dirname(p), exist_ok=True)\n" +
      "tmp = p + '.tmp'\n" +
      "with open(tmp, 'w') as f: f.write(" + JSON.stringify(payload) + ")\n" +
      "os.replace(tmp, p)\n"
    Quickshell.execDetached(["python3", "-c", script])
  }

  // ---- Hydration (FileView, NOT Quickshell.readFile — that doesn't exist) ---
  FileView {
    id: stateFile
    path: service.statePath
    watchChanges: false
    printErrors: false
    onLoaded: service.hydrate(text() || "")
    onLoadFailed: function(error) {
      console.warn("leo.bleguard: state load failed:", error, "— starting fresh")
      service.hydrate("")
    }
  }

  function hydrate(raw) {
    if (raw) {
      try {
        var parsed = JSON.parse(raw)
        if (parsed && typeof parsed === "object") {
          // Apply in place; PersistentProperties' onXxxChanged triggers saveSoon,
          // which is harmless (it'll re-write the same values).
          if (typeof parsed.targetMac === "string") persisted.targetMac = parsed.targetMac
          if (typeof parsed.armed === "boolean") persisted.armed = parsed.armed
          if (typeof parsed.rssiThreshold === "number") persisted.rssiThreshold = parsed.rssiThreshold
        }
      } catch (e) {
        console.warn("leo.bleguard: malformed state file:", e)
      }
    }
    service.state = service.armed ? "ARMED" : "DISARMED"
    if (service.armed && service.targetMac) {
      rssiPollTimer.start()
      service.lastRssiAt = Date.now()  // grace window while first poll runs
    }
  }

  Component.onCompleted: {
    // Wait for FileView to fire onLoaded before deciding the initial state.
    // Falls back to DISARMED if onLoadFailed fires (handled below).
  }

  // ---- RSSI polling -----------------------------------------------------
  // BlueZ exposes RSSI only while the adapter is actively scanning
  // (StartDiscovery). Phones connected over BR/EDR (OBEX/A2DP) still
  // broadcast BLE advertisements for proximity / find-my-device, so
  // RSSI is available IF we keep discovery on. Writing true to the
  // Quickshell BluetoothAdapter.discovering property triggers the
  // underlying StartDiscovery() and keeps the session alive for as
  // long as the property is true.
  function setBluezDiscovery(enabled) {
    var ad = Bluetooth.defaultAdapter
    if (ad) ad.discovering = !!enabled
  }

  Process {
    id: rssiProc
    command: ["busctl", "get-property", "org.bluez",
              "/placeholder", "org.bluez.Device1", "RSSI"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = Ble.parseBusctlRssi(text || "")
        if (n !== null && n !== 0) {
          var now = Date.now()
          service.lastRssi = n
          service.lastRssiAt = now
          service.pushHistory(n, now)
          service.evaluateProximity()
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var msg = String(rssiProc.stdout ? rssiProc.stdout.text : "")
        if (msg.indexOf("No such property") >= 0 && rssiPollTimer.running) {
          // Phone does not advertise over BLE. Stop polling and rely on
          // connection state only. We re-enable polling whenever the
          // user re-arms the plugin (see setArmed).
          rssiPollTimer.stop()
          console.log("leo.bleguard: RSSI not exposed by BlueZ for " +
                      service.targetMac + " — using connection state only")
        }
      }
    }
  }

  function startRssiPoll() {
    // Make sure BlueZ is scanning so RSSI is observable.
    setBluezDiscovery(true)
    var dev = service.findTargetDevice()
    if (!dev || !dev.connected || !dev.dbusPath) {
      rssiProc.running = false
      return
    }
    rssiProc.command = ["busctl", "get-property", "org.bluez",
                        dev.dbusPath, "org.bluez.Device1", "RSSI"]
    rssiProc.running = true
  }

  // Append a fresh RSSI sample, trim older entries outside the window.
  // Reassigns the array (not push) so QML change notifications fire.
  function pushHistory(rssi, t) {
    if (!rssi || rssi === 0) return
    var cutoff = t - service.historyWindowSeconds * 1000
    var next = []
    for (var i = 0; i < service.rssiHistory.length; i++) {
      if (service.rssiHistory[i].t >= cutoff) next.push(service.rssiHistory[i])
    }
    next.push({ t: t, rssi: rssi })
    if (next.length > service.historyMaxPoints) {
      next = next.slice(next.length - service.historyMaxPoints)
    }
    service.rssiHistory = next
  }

  function stopRssiPoll() {
    rssiProc.running = false
    setBluezDiscovery(false)
  }

  // Periodic proximity check — runs even when RSSI is unavailable, so
  // phone disconnect (the only reliable signal on BR/EDR phones) is
  // detected within one interval.
  Timer {
    id: rssiPollTimer
    interval: service.rssiPollMs
    repeat: true
    running: false
    onTriggered: {
      service.startRssiPoll()
      service.evaluateProximity()
    }
  }

  // ---- Idle monitor (Wayland ext-idle-notify-v1) -----------------------
  property bool idle: false
  IdleMonitor {
    id: idleMonitor
    enabled: true
    timeout: service.idleThresholdSeconds
    respectInhibitors: true
    onIsIdleChanged: {
      service.idle = isIdle
      // When user crosses into idle, lock if we're waiting for it.
      if (isIdle && service.state === "WAITING") {
        service.triggerLock()
      }
    }
  }

  // ---- Grace + lock timers ----------------------------------------------
  Timer {
    id: graceTimer
    interval: service.graceSeconds * 1000
    repeat: false
    onTriggered: service.onGraceExpired()
  }

  Timer {
    id: idlePollTimer
    interval: service.idlePollMs
    repeat: true
    running: false
    onTriggered: service.evaluateProximity()
  }

  Process {
    id: lockCheckProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = String(text || "").trim()
        if (v === "true") {
          service.state = "LOCKED"
          // Keep polling — we need to detect the manual unlock so the
          // state machine returns to ARMED. Stopping here strands the
          // service in LOCKED after every lock cycle.
        } else if (v === "false" && service.state === "LOCKED") {
          // User unlocked manually — re-arm.
          service.state = "ARMED"
          service.lastRssiAt = Date.now()  // reset stale window
          lockCheckTimer.stop()
          service.evaluateProximity()
        }
      }
    }
  }
  Timer {
    id: lockCheckTimer
    interval: service.lockCheckMs
    repeat: true
    running: false
    onTriggered: {
      if (lockCheckProc.running) return
      lockCheckProc.command = ["bash", "-lc", "omarchy-shell lock isLocked"]
      lockCheckProc.running = true
    }
  }

  // ---- State transitions -------------------------------------------------
  readonly property int backStableMs: 3000
  // Cumulative out-of-range time required before the WARNING notification
  // fires. Stretches across BR/EDR flaps: a 2s reconnect does not reset the
  // counter, only a clean cancelWarning() does. Picked longer than typical
  // phone-environment flap (<5s) so a flaky link at the desk edge does not
  // spam the user.
  readonly property int lostEntryMs: 5000

  function evaluateProximity() {
    if (service.state === "LOCKED" || service.state === "LOCKING") return
    if (!service.armed) return
    if (!service.targetMac) return  // not paired yet

    if (service.phoneLost()) {
      // Reset the cached reading so the popup doesn't keep showing a stale
      // value that BlueZ still has in memory but the device is actually gone.
      service.lastRssi = 0
      service.lastRssiAt = 0
      service.phoneBackSince = 0
      // phoneLostSince accumulates across flaps — first time we see the
      // phone missing, stamp it; do NOT reset on brief reconnects below.
      if (service.phoneLostSince === 0) service.phoneLostSince = Date.now()
      if (service.state === "ARMED"
          && Date.now() - service.phoneLostSince >= service.lostEntryMs) {
        service.enterWarning()
      }
    } else if (service.state === "WARNING" || service.state === "WAITING") {
      // Phone back — require stable for backStableMs before cancelling the
      // warning, so a 200ms BR/EDR reconnect doesn't immediately cancel
      // and re-arm a 10s grace timer on the next poll.
      if (service.phoneBackSince === 0) {
        service.phoneBackSince = Date.now()
      } else if (Date.now() - service.phoneBackSince >= service.backStableMs) {
        service.cancelWarning()
      }
      // NOTE: phoneLostSince intentionally NOT reset here — a brief
      // reconnect (e.g. 3s) followed by another drop should be treated as
      // continuous absence. cancelWarning() resets it on a real re-arm.
    } else {
      service.phoneBackSince = 0
    }
  }

  function enterWarning() {
    if (service.state !== "ARMED") return
    service.state = "WARNING"
    graceTimer.restart()
    service.postGraceNotification()
  }

  function cancelWarning() {
    graceTimer.stop()
    idlePollTimer.stop()
    service.state = "ARMED"
    service.phoneLostSince = 0
    service.lastRssiAt = Date.now()  // reset stale window
  }

  function onGraceExpired() {
    if (service.state !== "WARNING") return
    if (idleMonitor.isIdle) {
      service.triggerLock()
    } else {
      service.state = "WAITING"
      idlePollTimer.start()
    }
  }

  function triggerLock() {
    if (service.state === "LOCKED" || service.state === "LOCKING") return
    service.state = "LOCKING"
    idlePollTimer.stop()
    graceTimer.stop()
    Quickshell.execDetached(["bash", "-lc", "omarchy-system-lock"])
    lockCheckTimer.start()
  }

  function postGraceNotification() {
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "leo.bleguard",
      "-u", "normal",
      "-t", "12000",
      "-i", "bluetooth-symbolic",
      "Phone out of range",
      "Locking in " + graceSeconds + "s unless your phone comes back."
    ])
  }

  // ---- Public API for the panel / IPC -----------------------------------
  function setThreshold(value) {
    var n = parseInt(value, 10)
    if (isNaN(n)) return false
    if (n > -10) n = -10
    if (n < -100) n = -100
    persisted.rssiThreshold = n
    return true
  }

  function setTarget(mac) {
    if (typeof mac !== "string") return false
    persisted.targetMac = mac.trim()
    // Fresh pairing — reset the stale window so we don't immediately fire
    // a WARNING because RSSI hasn't been polled yet.
    service.lastRssiAt = Date.now()
    service.state = service.armed ? "ARMED" : "DISARMED"
    if (service.armed && persisted.targetMac) {
      rssiPollTimer.start()
      service.startRssiPoll()
    } else {
      stopRssiPoll()
    }
    return true
  }

  function setArmed(value) {
    persisted.armed = !!value
    if (!service.armed) {
      graceTimer.stop()
      idlePollTimer.stop()
      rssiPollTimer.stop()
      lockCheckTimer.stop()
      stopRssiPoll()
      service.state = "DISARMED"
    } else {
      service.state = "ARMED"
      if (persisted.targetMac) {
        rssiPollTimer.start()
        service.startRssiPoll()
      }
      service.evaluateProximity()
    }
  }

  function listPaired() {
    var list = Bluetooth.devices ? Bluetooth.devices.values : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      if (!d || !d.paired) continue
      out.push({
          address: d.address || "",
          name: d.name || d.deviceName || "",
          battery: d.batteryAvailable ? d.battery : null
        })
    }
    return out
  }

  // Custom control IPC on a separate target — `leo.bleguard` itself is
  // already claimed by the base Omarchy Panel's IpcHandler (show/hide/toggle).
  IpcHandler {
    target: "leo.bleguard.ctrl"

    function arm(): string {
      service.setArmed(true)
      return "armed"
    }

    function disarm(): string {
      service.setArmed(false)
      return "disarmed"
    }

    function status(): string {
      return JSON.stringify({
        state: service.state,
        armed: service.armed,
        targetMac: service.targetMac,
        rssi: service.lastRssi,
        rssiAt: service.lastRssiAt,
        distance: service.distanceMeters,
        historyPoints: service.rssiHistory.length,
        history: service.rssiHistory,
        discovering: Bluetooth.defaultAdapter ? Bluetooth.defaultAdapter.discovering : false,
        idle: service.idle,
        threshold: service.rssiThreshold,
        txPower: service.txPowerDbm,
        pathLoss: service.pathLoss
      })
    }

    function setTarget(mac: string): string {
      return service.setTarget(mac) ? "ok" : "invalid"
    }

    function setThreshold(value: int): string {
      return service.setThreshold(value) ? "ok" : "invalid"
    }

    function lockNow(): string {
      service.triggerLock()
      return "locking"
    }
  }
}