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
  // When RSSI hasn't updated for this long, we assume BlueZ stopped
  // exposing it (ColorOS quirk) and fall back to connection-only proximity.
  readonly property int rssiStaleWindowMs: 30000
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
  // One of: DISARMED, ARMED, WARNING, WAITING, LOCKING, LOCKED, UNLOCKING
  property string state: "DISARMED"
  // True when this plugin triggered the lock (vs. a manual omarchy-system-lock
  // or `omarchy shell lock lock` from a shortcut). Only auto-unlock when true —
  // a manual lock should respect the user's intent.
  property bool autoLockSource: false
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
  // Stamps Date.now() ONLY when the RSSI value actually changes between
  // busctl polls. Used by the popup to flag cached readings — BlueZ
  // stops tracking RSSI for paired+bonded+trusted ColorOS devices, so
  // a long-elapsed change timestamp is the fingerprint of that quirk
  // (see omarchy-ble-paired-stops-rssi memory). Does NOT update when
  // the value is the same as before: a stationary phone genuinely stays
  // at one value, and we'd rather not flag a real "still here" as stale.
  property var lastRssiValueChangeAt: 0

  // "Phone is advertising" evidence. BlueZ populates AdvertisingFlags /
  // ManufacturerData when an advertisement is processed while Discovering=true,
  // even if the BR/EDR ACL is asleep (ColorOS "fast sleep" pattern). We treat
  // recent advertising presence as a strong "phone is here" signal — used
  // ONLY by the auto-unlock path so the laptop can be re-armed when the user
  // comes back with a sleeping-but-broadcasting phone. WARNING/AUTO-LOCK
  // paths continue to use phoneLost() which treats disconnected=lost.
  property var lastAdvAt: 0
  property bool advertisingEverObserved: false

  // Rolling RSSI history for the popup chart. Each entry: {t: ms, rssi: dBm}.
  // Only real busctl readings — never the synthetic `lastRssi = 0` we set
  // when the phone drops, otherwise the chart would lie about presence.
  property var rssiHistory: []
  // True once BlueZ has returned at least one real RSSI for this device.
  // While false, phoneLost() falls back to connection-only proximity
  // (relevant for paired+trusted devices where BlueZ never exposes RSSI).
  property bool rssiEverObserved: false
  readonly property real distanceMeters: {
    if (!lastRssi || lastRssi === 0) return 0
    return Math.pow(10, (service.txPowerDbm - lastRssi) / (10 * service.pathLoss))
  }

  function phoneLost() {
    var dev = service.findTargetDevice()
    var connected = dev ? dev.connected : false

    // BR/EDR ACL up: treat as "nearby" regardless of RSSI staleness.
    // ColorOS quirk: once Paired=Bonded=Trusted, BlueZ stops exposing RSSI
    // while ACL is up. Presence is the ACL.
    if (connected) {
      var rssiFresh = service.rssiEverObserved
        && lastRssiAt
        && (Date.now() - lastRssiAt) <= service.rssiStaleWindowMs
      if (!rssiFresh) return false
      if (lastRssi !== 0 && lastRssi < service.rssiThreshold) return true
      return false
    }

    // BR/EDR ACL down — but ColorOS drops ACL during "fast sleep" while
    // continuing to broadcast BLE advertisements. Treat fresh advertising
    // within rssiStaleWindowMs (30s) as presence: the phone is on the desk
    // sleeping, and the user is sitting in front of it. This is the case
    // that produced the lock/unlock loop before this fix.
    var advFresh = service.advertisingEverObserved
      && service.lastAdvAt
      && (Date.now() - service.lastAdvAt) <= service.rssiStaleWindowMs
    return !advFresh
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
      service.lastAdvAt = Date.now()   // grace window for advertising too
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
          if (service.lastRssi !== n) {
            service.lastRssiValueChangeAt = now
          }
          service.lastRssi = n
          service.lastRssiAt = now
          service.rssiEverObserved = true
          service.pushHistory(n, now)
          service.evaluateProximity()
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var msg = String(rssiProc.stdout ? rssiProc.stdout.text : "")
        if (msg.indexOf("No such property") >= 0 && rssiPollTimer.running) {
          // Phone does not advertise over BLE (ColorOS quirk, see
          // omarchy-ble-paired-stops-rssi memory). Don't tear down the
          // polling timer — keep evaluateProximity() running so we still
          // check the connection state. RSSI stays 0; the rssiStaleMs
          // timer inside phoneLost() will declare the phone "lost" after
          // 6s if the property never reappears.
          console.log("leo.bleguard: RSSI not exposed by BlueZ for " +
                      service.targetMac + " — connection-only proximity")
        }
      }
    }
  }

  function startRssiPoll() {
    // Make sure BlueZ is scanning so RSSI + AdvertisingFlags are observable.
    setBluezDiscovery(true)
    var dev = service.findTargetDevice()
    if (!dev || !dev.dbusPath) {
      rssiProc.running = false
      advProc.running = false
      return
    }
    var path = dev.dbusPath
    // Poll RSSI regardless of ACL state. The OPPO exposes RSSI even while
    // BR/EDR is asleep (it stays in BlueZ's advertising cache), and on
    // other devices a "No such property" response just leaves the timer
    // alive (see rssiProc.onExited). Skipping the poll when disconnected
    // leaves the chart frozen at the last reading.
    rssiProc.command = ["busctl", "get-property", "org.bluez",
                        path, "org.bluez.Device1", "RSSI"]
    rssiProc.running = true
    advProc.command = ["busctl", "get-property", "org.bluez",
                       path, "org.bluez.Device1", "AdvertisingFlags"]
    advProc.running = true
  }

  // Tracks the AdvertisingFlags property: when BlueZ processes an
  // advertisement, it overwrites this with the current flags. A non-empty
  // byte array proves a recent advertisement was received — strong presence
  // evidence even when BR/EDR is asleep. Stops trusting only after the
  // value has been stale for rssiStaleWindowMs (30 s by default).
  Process {
    id: advProc
    command: ["busctl", "get-property", "org.bluez",
              "/placeholder", "org.bluez.Device1", "AdvertisingFlags"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // busctl prints "ay <count> <bytes...>". Empty when no advertisement
        // is cached: "ay 0" or "ay 0\n". Any entry with count > 0 = evidence.
        var out = String(text || "").trim()
        var m = out.match(/^ay\s+(\d+)/)
        var count = m ? parseInt(m[1], 10) : 0
        if (count > 0) {
          service.lastAdvAt = Date.now()
          service.advertisingEverObserved = true
          service.evaluateProximity()
        }
      }
    }
    onExited: function(exitCode) {
      // "No such property" on a non-advertising device: silent. Just don't
      // update lastAdvAt; phoneLost() will treat presence as unknown.
      if (exitCode !== 0) {
        var msg = String(advProc.stdout ? advProc.stdout.text : "")
        if (msg.indexOf("No such property") < 0) {
          // Some other error — log so it surfaces in qslog.
          console.log("leo.bleguard: advProc exit " + exitCode + ": " + msg.trim())
        }
      }
    }
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
    advProc.running = false
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
          if (service.state !== "LOCKED") {
            service.state = "LOCKED"
            // Only treat as a manual external lock if our triggerLock()
            // didn't already set autoLockSource=true. Otherwise preserve it
            // so auto-unlock still fires for plugin-triggered locks.
            if (!service.autoLockSource) {
              // Coming from omarchy-system-lock keybind or similar — keep
              // autoLockSource=false so we don't auto-unlock a manual lock.
            }
          }
          // Keep polling — we need to detect the manual unlock so the
          // state machine returns to ARMED. Stopping here strands the
          // service in LOCKED after every lock cycle.
        } else if (v === "false" && (service.state === "LOCKED" || service.state === "UNLOCKING")) {
          // User unlocked (manually or via auto-unlock) — re-arm.
          service.state = "ARMED"
          service.autoLockSource = false
          service.phoneBackSince = 0
          service.lastRssiAt = Date.now()  // reset stale window
          service.lastAdvAt = Date.now()   // reset advertising stale window
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
  // Stable-presence timer for auto-unlock. While LOCKED, the phone must be
  // "in range" (connected, RSSI above threshold, fresh) for this long before
  // we ask Omarchy's lock plugin to drop the session lock. Default 10s.
  readonly property int unlockStableMs: 10000

  function evaluateProximity() {
    if (service.state === "LOCKING") return
    if (!service.armed) return
    if (!service.targetMac) return  // not paired yet

    if (service.state === "LOCKED") {
      // Auto-unlock path: only if this plugin triggered the lock (not a
      // manual `omarchy-system-lock` from a keybind).
      if (!service.autoLockSource) return
      // phoneLost() now also accepts recent BLE advertisements as
      // presence (the ColorOS fast-sleep case), so a sleeping-but-
      // broadcasting phone on the desk counts as "phone is back".
      if (service.phoneLost()) {
        service.phoneBackSince = 0
      } else if (service.phoneBackSince === 0) {
        service.phoneBackSince = Date.now()
      } else if (Date.now() - service.phoneBackSince >= service.unlockStableMs) {
        service.triggerAutoUnlock()
      }
      return
    }

    if (service.phoneLost()) {
      // Reset the cached reading so the popup doesn't keep showing a stale
      // value that BlueZ still has in memory but the device is actually gone.
      service.lastRssi = 0
      service.lastRssiAt = 0
      // Don't reset lastAdvAt: it's owned by advProc and consumed by
      // phoneLost(). evaluateProximity can't tell whether the disconnect
      // is "phone genuinely gone" or "ColorOS fast sleep"; let the
      // rssiStaleWindowMs (30s) keep advancing so phoneLost() eventually
      // flips to true once advertisements stop arriving too.
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

  // ---- Auto-unlock -------------------------------------------------------
  // Phone has been "back in range" for unlockStableMs while LOCKED — ask
  // Omarchy's lock plugin (via IPC) to drop the session lock. Bypasses PAM:
  // BLE proximity + stable-presence timer is the second factor.
  // Requires the unlock IPC method in Omarchy's lock plugin
  // (see patches/install-lock-unlock-ipc.sh).
  function triggerAutoUnlock() {
    if (service.state !== "LOCKED") return
    if (!service.autoLockSource) return  // never auto-unlock a manual lock
    service.state = "UNLOCKING"
    service.phoneBackSince = 0
    service.autoLockSource = false  // single-shot; the lockCheckTimer handles ARMED transition
    Quickshell.execDetached(["bash", "-lc",
      "qs -p /usr/share/omarchy/shell ipc call lock unlock"])
    // The lockCheckTimer will see isLocked=false and transition us to ARMED.
    // If the lock plugin doesn't have an `unlock` IPC method, the IPC call
    // returns "Function not found" and we stay in UNLOCKING until the user
    // manually unlocks — patches/install-lock-unlock-ipc.sh must be applied.
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
    service.lastAdvAt = Date.now()   // reset advertising stale window
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
    service.autoLockSource = true
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
    service.lastAdvAt = Date.now()
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
        // Grace window while first poll runs (or fails). Without this, if
        // BlueZ never exposes RSSI for a paired device, phoneLost() can
        // never trigger because both rssiAt and rssi stay at 0.
        service.lastRssiAt = Date.now()
        service.lastAdvAt = Date.now()
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
        autoLockSource: service.autoLockSource,
        phoneBackSince: service.phoneBackSince,
        targetMac: service.targetMac,
        rssi: service.lastRssi,
        rssiAt: service.lastRssiAt,
        rssiValueChangeAt: service.lastRssiValueChangeAt,
        advAt: service.lastAdvAt,
        advertisingEverObserved: service.advertisingEverObserved,
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