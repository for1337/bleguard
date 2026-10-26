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
  // How long an RSSI reading stays "fresh", i.e. how recently an
  // advertisement must have been received for the value to be trusted.
  // The helper's filtered-discovery session makes BlueZ republish the RSSI
  // on *every* advertisement, so this is a real liveness window and not a
  // "did the number move" heuristic. It has to comfortably exceed the
  // phone's advertising interval (~15 s for an idle OPPO beacon) so a
  // single missed advertisement does not flip the presence state.
  readonly property int rssiStaleWindowMs: 45000
  readonly property int rssiPollMs: 2000
  readonly property int idlePollMs: 1000
  readonly property int lockCheckMs: 1000
  // Default RSSI floor. Tunable per-VM later; for now hardcoded.
  readonly property int defaultRssiThreshold: -85
  // Default grace period between "the value crossed the threshold" and
  // "the notification appears and the lock procedure starts".
  readonly property int defaultLostEntryMs: 5000
  // Default window of complete silence (no ACL, no advertisement, no RSSI)
  // after which the phone counts as out of range, exactly like a measurement
  // below the threshold. A phone that switched its radio off cannot send us
  // a weak signal — it simply stops answering, and that silence is the only
  // evidence left. The window has to be long enough to survive a gap
  // between two advertisements and a BR/EDR drop, but short enough that a
  // radio that stays off is noticed.
  readonly property int defaultAbsentAfterMs: 45000

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
  // When we started waiting for the phone. Used as the fallback start of the
  // silence clock when the phone was never heard from at all (armed while the
  // radio was off): without it there would be no reference point to measure
  // the silence against.
  property var presenceSince: 0

  // ---- Auto-unlock bookkeeping -----------------------------------------
  // Raw result of the last unlock IPC attempt ("ok", "not-locked", or an
  // error string such as "Function not found.").
  property string lastUnlockResult: ""
  // Consecutive failed unlock attempts — drives the retry backoff.
  property int unlockFailures: 0
  // Timestamp of the last unlock IPC attempt.
  property var lastUnlockAttemptAt: 0
  // True between an accepted unlock request and the moment the lock
  // plugin actually releases the session lock.
  property bool unlockRequested: false
  property var unlockRequestedAt: 0

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

  // Is `path` the D-Bus object of the phone we are currently watching?
  //
  // A poll that was started for another phone must not decide the presence
  // of the current one: its cached value says nothing about this device.
  function isCurrentTargetPath(path) {
    if (!path) return false
    var dev = service.findTargetDevice()
    return !!(dev && dev.dbusPath === path)
  }

  // ---- RSSI tracking (requires BlueZ discovery on) ------------------
  // Use var for timestamps — Date.now() in 2026 is ~1.79e12 ms since epoch,
  // which overflows QML's 32-bit int (max 2.1e9) and silently truncates to
  // the lower 32 bits (~664e6), giving nonsense time deltas.
  property var lastRssi: 0
  property var lastRssiAt: 0
  // Stamps Date.now() ONLY when the RSSI value actually changes between
  // busctl polls. Used by the popup to flag cached readings — BlueZ
  // stops tracking RSSI for paired+bonded+trusted devices, so a long-
  // elapsed change timestamp is the fingerprint of that. Does NOT
  // update when the value is the same as before: a stationary phone
  // genuinely stays at one value, and we'd rather not flag a real "still
  // here" as stale.
  property var lastRssiValueChangeAt: 0
  // Baseline for the busctl fallback: the value the poll saw last time.
  // BlueZ's RSSI property is a *cache* — it is rewritten only when BlueZ
  // actually heard the device — so a value that does not change between two
  // polls proves nothing about the phone. Only a change is proof of life.
  // The first poll after a restart only seeds this baseline: the value it
  // returns may be hours old.
  property var lastPollRssi: 0
  // The device path the *running* poll reads. A poll that was started for
  // another phone says nothing about the current one, so its result is
  // dropped when the path no longer matches the target.
  property string pollPath: ""
  // The device path the poll baseline belongs to. A different device (a
  // re-pair) invalidates the baseline: its value says nothing about the new
  // device.
  property string pollBaselinePath: ""
  // The device path the running advertisement poll reads.
  property string advPath: ""

  // "Phone is advertising" evidence. BlueZ populates AdvertisingFlags /
  // ManufacturerData when an advertisement is processed while Discovering=true,
  // even if the BR/EDR ACL is asleep (some phones drop ACL during sleep while
  // still broadcasting BLE ads). We treat recent advertising presence as a
  // strong "phone is here" signal — used by the auto-unlock path so the
  // laptop can be re-armed when the user comes back with a sleeping-but-
  // broadcasting phone. The warning path also uses it via phoneLost().
  property var lastAdvAt: 0
  // Whole output of the last `busctl get-property ... AdvertisingFlags` poll.
  // Same string again = same cached ad = no freshness bump; different bytes =
  // a new ad actually arrived.
  property var lastAdvBytes: ""
  // True once the cached payload has been read at least once. The first
  // reading only seeds the comparison — it is not a new advertisement.
  property bool advBytesSeeded: false
  property bool advertisingEverObserved: false

  // Rolling RSSI history for the popup chart. Each entry: {t: ms, rssi: dBm}.
  // Only real busctl readings — never the synthetic `lastRssi = 0` we set
  // when the phone drops, otherwise the chart would lie about presence.
  property var rssiHistory: []
  // True once BlueZ has returned at least one real RSSI for this device.
  // While false, phoneLost() falls back to connection-only proximity
  // (relevant for paired+trusted devices where BlueZ never exposes RSSI).
  property bool rssiEverObserved: false
  // Where the current RSSI reading comes from: "helper" = the filtered
  // discovery helper (a real advertisement heartbeat), "poll" = the
  // busctl fallback, "none" = nothing yet.
  property string rssiSource: "none"
  // True while we have no evidence at all about the phone (right after
  // arming). The presence decision stays neutral until the first real
  // reading arrives, so the plugin never shouts "out of range" before it
  // has actually listened.
  property bool presenceWarmup: true
  // True once the helper has an active discovery session and its
  // PropertiesChanged subscription is live.
  property bool helperReady: false
  // Last error reported by the helper (empty = fine).
  property string helperError: ""
  // How many times the helper had to be restarted — surfaces a broken
  // installation in the status IPC instead of failing silently.
  property int helperRestarts: 0
  // True when the helper *should* be running. The single source of truth for
  // its lifecycle: a deliberate stop can never be undone by the exit handler,
  // and a rebind knows whether the helper is expected to come back.
  property bool helperWanted: false
  // True while the helper must be started again with a different command.
  // Quickshell applies a new command only on the *next* start, so the old
  // process has to exit first — otherwise the helper would keep watching
  // the previous phone.
  property bool helperRebindPending: false
  // Helper lines that were rejected because they belong to another device
  // (the phone that was selected before). Non-zero means a rebind is in
  // flight, or that a stale helper is still around.
  property int helperForeignEvents: 0
  // Helper lines that carried no MAC tag at all (an older helper build).
  property int helperUntaggedEvents: 0
  readonly property real distanceMeters: {
    if (!lastRssi || lastRssi === 0) return 0
    return Math.pow(10, (service.txPowerDbm - lastRssi) / (10 * service.pathLoss))
  }

  // The RSSI age in ms — 0 when nothing was ever read.
  //
  // A function, not a binding: a binding over Date.now() is only re-evaluated
  // when its dependencies change, so `Date.now() - lastRssiAt` would freeze at
  // the moment the last reading arrived and report an age of a few seconds
  // forever. The age has to be computed where it is used.
  function rssiAgeMs() {
    return Ble.rssiAgeMs(service.lastRssiAt, Date.now())
  }

  // How long we have heard nothing from the phone: the age of the most
  // recent piece of evidence (an RSSI reading or an advertisement), or the
  // time since we started waiting when there never was any.
  function silenceAgeMs() {
    return Ble.silenceAgeMs(service.presenceOpts())
  }

  // ---- Presence model ----------------------------------------------------
  // The decision lives in BleLogic.js so it can be unit-tested from node;
  // these two functions are thin adapters that feed it the live state.
  function presenceOpts() {
    var dev = service.findTargetDevice()
    return {
      now: Date.now(),
      connected: dev ? !!dev.connected : false,
      rssi: service.lastRssi,
      rssiAt: service.lastRssiAt,
      rssiEverObserved: service.rssiEverObserved,
      advAt: service.lastAdvAt,
      advertisingEverObserved: service.advertisingEverObserved,
      threshold: service.rssiThreshold,
      staleWindowMs: service.rssiStaleWindowMs,
      absentAfterMs: service.absentAfterMs,
      since: service.presenceSince,
      warmup: service.presenceWarmup
    }
  }

  // Any real observation ends the warm-up: from then on the decision is
  // driven by the RSSI value.
  function noteEvidence() {
    if (service.presenceWarmup) {
      service.presenceWarmup = false
      warmupTimer.stop()
    }
  }

  // Is the phone out of range? Two ways to be out of range:
  //
  //   1. the last RSSI value is below the threshold
  //   2. the phone stopped answering altogether — no ACL, no advertisement, no
  //      reading — for longer than the absence window
  //
  // While the silence is still shorter than the absence window the last known
  // value decides, so a single missed advertisement changes nothing. Once the
  // silence outlasts the window the phone counts as gone: a radio that has
  // been switched off (or a phone that walked out of range) must still
  // trigger the lock.
  //
  // The ACL is the safety gate: while the BR/EDR link is up the phone is
  // proven to be here, so a quiet BLE beacon never counts as absence.
  function phoneLost() {
    return Ble.phoneLost(service.presenceOpts())
  }

  // Positive evidence that the phone is back — gates the auto-unlock.
  // Deliberately stricter than phoneLost(): an old reading is not enough
  // to unlock, so a phone that stays silent after the user walked away can
  // never open the laptop on its own.
  function phonePresent() {
    return Ble.phonePresent(service.presenceOpts())
  }

  // Which channel currently carries the presence decision. "acl" = the
  // BR/EDR link is up, "rssi" = a fresh advertisement-driven reading,
  // "rssi-stale" = the last known value is old but still known,
  // "adv" = a recent advertisement without any RSSI, "none" = nothing.
  function presenceSource() {
    return Ble.presenceSource(service.presenceOpts())
  }

  // ---- Persisted state --------------------------------------------------
  PersistentProperties {
    id: persisted
    reloadableId: "leo-bleguard"
    property string targetMac: ""
    property bool armed: true
    property int rssiThreshold: service.defaultRssiThreshold
    property int lostEntryMs: service.defaultLostEntryMs
    property int absentAfterMs: service.defaultAbsentAfterMs

    onTargetMacChanged: service.saveSoon()
    onArmedChanged: service.saveSoon()
    onRssiThresholdChanged: service.saveSoon()
    onLostEntryMsChanged: service.saveSoon()
    onAbsentAfterMsChanged: service.saveSoon()
  }

  readonly property alias targetMac: persisted.targetMac
  readonly property alias armed: persisted.armed
  readonly property alias rssiThreshold: persisted.rssiThreshold
  readonly property alias absentAfterMs: persisted.absentAfterMs

  Timer {
    id: saveTimer
    interval: 2000
    repeat: false
    onTriggered: service.flushState()
  }

  // Writes the state file (including the last known RSSI and its age)
  // every 30 s, so a shell restart does not lose the only measurement we
  // have about how close the phone was.
  Timer {
    id: persistTimer
    interval: 30000
    repeat: true
    running: true
    onTriggered: service.flushState()
  }

  function saveSoon() { saveTimer.restart() }
  function flushStateNow() { saveTimer.stop(); service.flushState() }

  function flushState() {
    var payload = JSON.stringify({
      targetMac: persisted.targetMac,
      armed: persisted.armed,
      rssiThreshold: persisted.rssiThreshold,
      lostEntryMs: persisted.lostEntryMs,
      absentAfterMs: persisted.absentAfterMs,
      // The last known reading and its age. BlueZ removes the RSSI property
      // as soon as it stops seeing the device, so without this a shell
      // restart would throw away the only evidence we have about how close
      // the phone was — and the plugin would have nothing to decide with.
      lastRssi: service.lastRssi,
      // The absolute timestamp of the measurement. The age alone would have to
      // be recomputed from the *current* clock on every save, and rounding it
      // to seconds loses the sub-second precision that tells "5 s ago" from
      // "55 s ago". The absolute stamp keeps the real age across a restart,
      // so a restored reading is only "fresh" when it really was.
      lastRssiAt: service.lastRssiAt,
      lastRssiAgeSec: service.lastRssi ? Math.floor(service.rssiAgeMs() / 1000) : 0
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
      console.warn("bleguard: state load failed:", error, "— starting fresh")
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
          if (typeof parsed.lostEntryMs === "number") persisted.lostEntryMs = parsed.lostEntryMs
          if (typeof parsed.absentAfterMs === "number") persisted.absentAfterMs = parsed.absentAfterMs
          // Restore the last known reading. The age is preserved (the state
          // file carries the absolute timestamp of the measurement), so the
          // reading stays as old as it really is: it can keep the phone from
          // being reported as gone, but a stale reading can never unlock the
          // laptop on its own. When the file carries no usable age the
          // reading is restored as stale on purpose — an unknown age must
          // never look fresh.
          if (typeof parsed.lastRssi === "number" && parsed.lastRssi !== 0) {
            service.lastRssi = parsed.lastRssi
            service.lastRssiAt = Ble.restoreRssiAt(parsed, Date.now(), service.rssiStaleWindowMs)
            service.rssiEverObserved = true
            service.rssiSource = "saved"
          }
        }
      } catch (e) {
        console.warn("bleguard: malformed state file:", e)
      }
    }
    service.state = service.armed ? "ARMED" : "DISARMED"
    if (service.armed && service.targetMac) {
      rssiPollTimer.start()
      service.startWarmup()
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

  // ---- Filtered-discovery helper ----------------------------------------
  // BlueZ only republishes a device's RSSI property when the value moves by
  // at least 8 dBm (RSSI_THRESHOLD in device.c). A phone lying on the desk
  // oscillates by ~10 dBm, so the exported value stays frozen at whatever
  // was published first — the "RSSI stuck at -45 dBm while the phone is
  // right there" symptom, and the reason the chart never moved.
  //
  // When the adapter runs a *filtered* discovery session, BlueZ publishes the
  // RSSI on every received advertisement instead
  // (device_set_rssi_with_delta(dev, rssi, 0)). That turns the property into
  // a real heartbeat: every advertisement refreshes it even when the measured
  // value did not move.
  //
  // The filter has to be installed by the same D-Bus connection that later
  // calls StartDiscovery(), so a one-shot busctl cannot do it — a small
  // long-lived helper does. The helper streams the values on stdout:
  //
  //   ready          discovery is active, subscription live
  //   rssi <int>     the device's RSSI changed to <int> dBm
  //   error <text>   recoverable error, the helper keeps running
  Process {
    id: helperProc
    command: service.helperCommand()
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        service.onHelperLine(data)
      }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var line = String(data || "").trim()
        if (line.length > 0) console.warn("bleguard: helper: " + line)
      }
    }
    onExited: function(exitCode, exitStatus) {
      service.helperReady = false
      if (service.helperRebindPending) {
        // The old process is gone: now the new command takes effect. This is
        // the only moment where the helper can be pointed at another phone.
        service.helperRebindPending = false
        if (service.helperWanted && service.armed && service.targetMac
            && service.findTargetDevice()) {
          helperProc.command = service.helperCommand()
          helperProc.running = true
        } else {
          // The new target is not known to BlueZ yet: there is nothing to
          // watch. The poll timer starts the helper as soon as it shows up.
          service.helperWanted = false
        }
        return
      }
      if (exitCode === 70) {
        // Configuration error (the helper could not determine the phone it
        // has to watch): restarting would only repeat it.
        service.helperError = "helper could not determine the target device"
        console.warn("bleguard: helper configuration error, not restarting")
        return
      }
      if (!service.findTargetDevice()) {
        // The target is not known to BlueZ (a phone that was paired to
        // another machine, or a device that vanished). There is nothing to
        // watch: the command would be a no-op, and restarting it would only
        // spin. The poll timer brings the helper back as soon as the
        // device shows up again.
        service.helperWanted = false
        return
      }
      if (service.helperWanted && service.armed && service.targetMac) {
        // The helper is a long-lived session; if it dies (BlueZ restart,
        // D-Bus reset, ...) bring it back after a short delay.
        service.helperRestarts += 1
        helperRestartTimer.restart()
      }
    }
  }

  Timer {
    id: helperRestartTimer
    interval: 3000
    repeat: false
    onTriggered: {
      if (service.helperWanted && service.armed && service.targetMac && !helperProc.running) {
        helperProc.command = service.helperCommand()
        helperProc.running = true
      }
    }
  }

  // Bounds the warm-up: if BlueZ never tells us anything about the phone
  // (no RSSI, no advertisement), the plugin stops waiting and falls back
  // to the "no evidence" behaviour instead of staying silent forever.
  Timer {
    id: warmupTimer
    interval: 60000
    repeat: false
    onTriggered: service.presenceWarmup = false
  }

  function startWarmup() {
    service.presenceWarmup = true
    // The silence clock starts now: if the phone never answers at all, this
    // is the moment we measure the silence against.
    service.presenceSince = Date.now()
    warmupTimer.restart()
  }

  // Where the helper lives. The helper always ships next to this very file,
  // so the directory of the running QML is the primary candidate; the
  // explicit paths below keep a checkout usable without reinstalling and
  // survive a non-file URL (qrc, remote loader, ...).
  function helperPath() {
    var home = Quickshell.env("HOME")
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    var bases = []

    var selfDir = String(Qt.resolvedUrl("."))
    if (selfDir.indexOf("file://") === 0) selfDir = selfDir.substring(7)
    if (selfDir.length > 0 && selfDir.charAt(selfDir.length - 1) === "/")
      selfDir = selfDir.substring(0, selfDir.length - 1)
    if (selfDir) bases.push(selfDir)

    if (xdg) bases.push(xdg + "/omarchy/plugins/bleguard")
    bases.push(home + "/.config/omarchy/plugins/bleguard")

    var paths = []
    for (var i = 0; i < bases.length; i++) {
      if (!bases[i]) continue
      var p = bases[i] + "/bleguard-discovery.py"
      // The candidates are handed to a shell loop: a single quote would
      // break the quoting, so such a path is dropped instead of mangled.
      if (p.indexOf("'") >= 0) continue
      paths.push("'" + p + "'")
    }
    // The helper resolves its own location; the plugin only has to hand it
    // the adapter and device paths. The first existing candidate wins.
    return paths.join(" ")
  }

  function helperCommand() {
    var dev = service.findTargetDevice()
    var devicePath = dev && dev.dbusPath ? dev.dbusPath : ""
    var adapterPath = ""
    if (dev && dev.adapter && dev.adapter.dbusPath) adapterPath = dev.adapter.dbusPath
    else if (devicePath.indexOf("/dev_") > 0) adapterPath = devicePath.substring(0, devicePath.indexOf("/dev_"))
    if (!devicePath || !adapterPath) return ["false"]
    return ["bash", "-c",
      "for d in " + service.helperPath() + "; do " +
      "  [ -f \"$d\" ] && exec python3 \"$d\" \"$@\"; " +
      "done; " +
      "echo 'bleguard-discovery.py not found' >&2; exit 1",
      "bleguard-discovery", "--adapter", adapterPath, "--device", devicePath,
      // The MAC tags every line the helper prints: the consumer can then
      // reject the lines of a helper that still watches the previous phone.
      "--mac", String(service.targetMac).toUpperCase()]
  }

  function onHelperLine(data) {
    var line = String(data === undefined || data === null ? "" : data).trim()
    if (line.length === 0) return
    // Every helper line carries the MAC of the phone the helper watches. A
    // line from another device — the helper that has not exited yet after a
    // target change — must never touch the shared presence state: its
    // readings would keep the laptop unlocked or prevent the auto-lock.
    if (!Ble.helperLineMac(line)) {
      service.helperUntaggedEvents += 1
      return
    }
    var parsed = Ble.parseHelperLine(line, service.targetMac)
    if (!parsed) {
      service.helperForeignEvents += 1
      return
    }
    if (parsed.kind === "ready") {
      service.helperReady = true
      service.helperError = ""
      return
    }
    if (parsed.kind === "rssi-cache") {
      // The value BlueZ has cached from the last time it saw the device. It
      // may be hours old: it is a value, not proof of life. Recording it
      // without touching lastRssiAt keeps the age honest — otherwise a
      // restart would make a dead phone look fresh and alive.
      var cached = parsed.value
      if (!cached || cached === 0) return
      if (service.lastRssi !== cached) {
        service.lastRssiValueChangeAt = Date.now()
        service.lastRssi = cached
        service.rssiEverObserved = true
      }
      return
    }
    if (parsed.kind === "rssi") {
      var n = parsed.value
      if (!n || n === 0) return
      var now = Date.now()
      if (service.lastRssi !== n) {
        service.lastRssiValueChangeAt = now
      }
      // The whole point of the helper: the value is republished on every
      // advertisement, so lastRssiAt is a genuine heartbeat even when the
      // measured value did not move.
      service.lastRssi = n
      service.lastRssiAt = now
      service.rssiEverObserved = true
      service.rssiSource = "helper"
      service.helperReady = true
      service.noteEvidence()
      service.pushHistory(n, now)
      service.evaluateProximity()
      return
    }
    if (parsed.kind === "error") {
      service.helperError = parsed.text
      console.warn("bleguard: helper error: " + service.helperError)
    }
  }

  function startHelper() {
    if (!service.armed || !service.targetMac) return
    if (!service.findTargetDevice()) {
      // Nothing to watch: the target device is not known to BlueZ. Starting
      // the helper would only run a command that cannot do anything.
      service.helperWanted = false
      return
    }
    service.helperWanted = true
    if (helperProc.running) return
    helperProc.command = service.helperCommand()
    helperProc.running = true
  }

  function stopHelper() {
    service.helperWanted = false
    service.helperRebindPending = false
    helperRestartTimer.stop()
    if (helperProc.running) helperProc.running = false
    service.helperReady = false
  }

  // Point the helper at the current target.
  //
  // The helper watches exactly one phone, so a target change has to restart
  // it: the running process still holds the *old* device path and would keep
  // streaming the previous phone's readings. Quickshell applies a new
  // command only on the next start, so the old process is stopped first and
  // the new command is set when it has exited (see helperProc.onExited).
  function rebindHelper() {
    if (!service.armed || !service.targetMac) {
      stopHelper()
      return
    }
    // The running helper watches the *previous* phone: it has to go, whether
    // or not the new target is already known to BlueZ.
    if (helperProc.running) {
      service.helperRebindPending = true
      helperProc.running = false
      return
    }
    if (!service.findTargetDevice()) {
      // The new target is not known to BlueZ: there is nothing to watch yet.
      service.helperWanted = false
      return
    }
    service.helperWanted = true
    helperProc.command = service.helperCommand()
    helperProc.running = true
  }

  // Forget everything we knew about the previous phone: its last reading,
  // its advertisement, the poll baseline, the presence clocks and the
  // chart. The evidence of one phone says nothing about another, and a
  // stale reading must never decide the presence of the new one.
  function resetPresenceState() {
    service.lastRssi = 0
    service.lastRssiAt = 0
    service.lastRssiValueChangeAt = 0
    service.lastPollRssi = 0
    service.pollPath = ""
    service.pollBaselinePath = ""
    service.advPath = ""
    service.lastAdvAt = 0
    service.lastAdvBytes = ""
    service.advBytesSeeded = false
    service.advertisingEverObserved = false
    service.rssiEverObserved = false
    service.rssiSource = "none"
    service.phoneLostSince = 0
    service.phoneBackSince = 0
    service.presenceSince = 0
    service.rssiHistory = []
    service.helperReady = false
    // The lock was triggered by the previous phone: the new one has no
    // business unlocking it, and the pending unlock request is void.
    service.autoLockSource = false
    service.unlockRequested = false
    service.unlockFailures = 0
    service.lastUnlockResult = ""
  }

  Process {
    id: rssiProc
    command: ["busctl", "get-property", "org.bluez",
              "/placeholder", "org.bluez.Device1", "RSSI"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // The poll may have been started for the previous phone: its value
        // says nothing about the current one.
        if (!service.isCurrentTargetPath(service.pollPath)) return
        var n = Ble.parseBusctlRssi(text || "")
        if (n === null || n === 0) return
        var now = Date.now()
        // The busctl poll is a fallback: it reads BlueZ's *cached* RSSI, and
        // BlueZ only rewrites that property when it actually heard the
        // device. So:
        //   - the very first poll only tells us what BlueZ already had
        //     cached (possibly hours old): a value, not proof of life;
        //   - a value identical to the previous poll tells us nothing new.
        // Only a change against the previous poll proves the phone was
        // heard in between — and that is what refreshes the freshness clock
        // and closes the warm-up. The helper owns the heartbeat while it
        // runs; this poll only covers the devices BlueZ hides from it.
        var measured = Ble.pollProvesLife(service.lastPollRssi, n)
        if (service.lastRssi !== n) {
          service.lastRssiValueChangeAt = now
        }
        if (measured) {
          service.lastRssiAt = now
        }
        service.lastPollRssi = n
        service.lastRssi = n
        service.rssiEverObserved = true
        if (service.rssiSource !== "helper") service.rssiSource = "poll"
        if (measured) {
          service.noteEvidence()
          service.pushHistory(n, now)
        }
        service.evaluateProximity()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var msg = String(rssiProc.stdout ? rssiProc.stdout.text : "")
        if (msg.indexOf("No such property") >= 0 && rssiPollTimer.running) {
          // Some phones don't expose RSSI over BLE even while advertising.
          // Don't tear down the polling timer — keep evaluateProximity()
          // running so we still check the connection state.
          console.log("bleguard: RSSI not exposed by BlueZ for " +
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
    // A different device invalidates the poll baseline: the cached value of
    // the previous phone says nothing about this one.
    if (service.pollBaselinePath !== path) {
      service.pollBaselinePath = path
      service.lastPollRssi = 0
    }
    // The command of a running process is applied on its next start only, so
    // the command is not touched while the poll is in flight. The path that
    // is actually being read is recorded with the process, and the result is
    // checked against it: a poll that was started for the previous phone
    // must not decide the presence of the new one.
    //
    // Poll RSSI regardless of ACL state. Some phones expose RSSI even
    // while BR/EDR is asleep (it stays in BlueZ's advertising cache),
    // and on others a "No such property" response just leaves the timer
    // alive (see rssiProc.onExited). Skipping the poll when disconnected
    // leaves the chart frozen at the last reading.
    if (!rssiProc.running) {
      rssiProc.command = ["busctl", "get-property", "org.bluez",
                          path, "org.bluez.Device1", "RSSI"]
      service.pollPath = path
      rssiProc.running = true
    }
    if (!advProc.running) {
      advProc.command = ["busctl", "get-property", "org.bluez",
                         path, "org.bluez.Device1", "AdvertisingFlags"]
      service.advPath = path
      advProc.running = true
    }
    // The helper is the primary RSSI source: it holds the filtered
    // discovery session open and turns the RSSI into a heartbeat.
    service.startHelper()
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
        // The poll may have been started for the previous phone: its
        // advertisement says nothing about the current one.
        if (!service.isCurrentTargetPath(service.advPath)) return
        // busctl prints "ay <count> <bytes...>". Empty when no advertisement
        // is cached: "ay 0" or "ay 0\n". Same string twice = BlueZ still
        // handing back the same cached ad; treat that as no new ad and
        // don't refresh the freshness timestamp.
        var out = String(text || "").trim()
        var m = out.match(/^ay\s+(\d+)/)
        var count = m ? parseInt(m[1], 10) : 0
        if (count === 0) {
          // Nothing cached any more — forget the old payload so the next
          // advertisement registers as a change even if it repeats it.
          service.lastAdvBytes = ""
          return
        }
        if (!service.advBytesSeeded) {
          // The very first poll only tells us what BlueZ already had cached.
          // That is not evidence that an advertisement just arrived, so it
          // must not start the "recent advertisement" clock.
          service.lastAdvBytes = out
          service.advBytesSeeded = true
          return
        }
        if (out !== service.lastAdvBytes) {
          service.lastAdvBytes = out
          service.lastAdvAt = Date.now()
          service.advertisingEverObserved = true
          service.noteEvidence()
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
          console.log("bleguard: advProc exit " + exitCode + ": " + msg.trim())
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
    service.stopHelper()
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
          if (service.state === "UNLOCKING") {
            // Unlock requested, lock still up — the UNLOCKING timeout in
            // evaluateProximity() decides whether to retry.
          } else if (service.state !== "LOCKED") {
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
          service.unlockRequested = false
          service.unlockFailures = 0
          service.phoneBackSince = 0
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
  // counter, only a *stable* return does. Picked longer than typical
  // phone-environment flap (<5s) so a flaky link at the desk edge does not
  // spam the user.
  //
  // This is the delay between "the value crossed the threshold" and "the
  // notification appears and the lock procedure starts". Configurable (and
  // persisted) through the `Grace` field in the popup or the `setGraceMs`
  // IPC command.
  readonly property alias lostEntryMs: persisted.lostEntryMs
  // Stable-presence timer for auto-unlock. While LOCKED, the phone must be
  // "in range" (connected, RSSI above threshold, fresh) for this long before
  // we ask Omarchy's lock plugin to drop the session lock. Default 10s.
  readonly property int unlockStableMs: 10000
  // Backoff between unlock attempts after a failure, so a missing
  // `unlock` IPC method doesn't hammer the shell every poll cycle.
  readonly property int unlockRetryMs: 15000
  // How long we wait for the lock plugin to actually release the session
  // lock after accepting the unlock request. If it doesn't happen within
  // this window the request is treated as ineffective and retried.
  readonly property int unlockWaitMs: 8000

  function evaluateProximity() {
    if (service.state === "LOCKING") return
    if (!service.armed) return
    if (!service.targetMac) return  // not paired yet

    if (service.state === "UNLOCKING") {
      // The unlock request was accepted but the lock plugin has not
      // released the session lock yet. If that doesn't happen within
      // unlockWaitMs the request was ineffective — fall back to LOCKED so
      // the presence check can try again.
      if (service.unlockRequestedAt
          && (Date.now() - service.unlockRequestedAt) >= service.unlockWaitMs) {
        service.unlockRequested = false
        service.state = "LOCKED"
        console.warn("bleguard: unlock did not take effect, will retry")
      }
      return
    }

    if (service.state === "LOCKED") {
      // Auto-unlock path: only if this plugin triggered the lock (not a
      // manual `omarchy-system-lock` from a keybind).
      if (!service.autoLockSource) return
      // Unlocking needs *positive* evidence that the phone is back: a live
      // ACL, a fresh advertisement or a fresh RSSI above the threshold.
      // An old reading is not enough — otherwise a phone that stayed silent
      // after the user walked away would keep the laptop unlocked.
      if (!service.phonePresent()) {
        service.phoneBackSince = 0
      } else if (service.phoneBackSince === 0) {
        service.phoneBackSince = Date.now()
      } else if (Date.now() - service.phoneBackSince >= service.unlockStableMs) {
        service.triggerAutoUnlock()
      }
      return
    }

    // Out-of-range handling. The grace period lives in BleLogic.js so it is
    // unit-testable from node: the notification and the whole lock procedure
    // only start once the reading has been out of range for lostEntryMs, and
    // a *stable* return resets the counter so the next episode starts a fresh
    // grace period instead of firing the notification instantly.
    //
    // Note: the last reading is deliberately kept. It is the evidence the
    // presence decision is based on; the popup decides on its own how to
    // present an old value (see Panel.qml's rssiFresh), so there is no
    // reason to throw the information away here.
    var step = Ble.graceStep(service.state, {
      now: Date.now(),
      lost: service.phoneLost(),
      lostSince: service.phoneLostSince,
      backSince: service.phoneBackSince,
      lostEntryMs: service.lostEntryMs,
      backStableMs: service.backStableMs
    })
    service.phoneLostSince = step.lostSince
    service.phoneBackSince = step.backSince
    if (step.action === "enter-warning") {
      service.enterWarning()
    } else if (step.action === "cancel-warning") {
      service.cancelWarning()
    }
  }

  // ---- Auto-unlock -------------------------------------------------------
  // Phone has been "back in range" for unlockStableMs while LOCKED — ask
  // Omarchy's lock plugin (via IPC) to drop the session lock. Bypasses PAM:
  // BLE proximity + stable-presence timer is the second factor.
  // Requires the unlock IPC method in Omarchy's lock plugin
  // (see patches/install-lock-unlock-ipc.sh).
  //
  // `qs ipc call lock unlock` prints the handler's return value on stdout
  // and exits 0 even when the method does not exist ("Function not
  // found."), so the stdout content is the authoritative signal — never
  // the exit code.
  Process {
    id: unlockProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        service.lastUnlockResult = out
        if (out === "ok" || out === "not-locked") {
          service.unlockFailures = 0
          service.unlockRequested = true
          service.unlockRequestedAt = Date.now()
          service.state = "UNLOCKING"
          service.phoneBackSince = 0
          // autoLockSource stays true until the lock is actually released:
          // if the request doesn't take effect we want to be able to
          // retry, not to strand the service in UNLOCKING forever.
        } else {
          service.unlockFailures += 1
          service.unlockRequested = false
          console.warn("bleguard: unlock IPC failed: " + out)
          service.notifyUnlockFailure(out)
        }
      }
    }
  }

  function triggerAutoUnlock() {
    if (service.state !== "LOCKED") return
    if (!service.autoLockSource) return  // never auto-unlock a manual lock
    if (unlockProc.running) return
    // Back off between failed attempts so a missing `unlock` IPC method
    // doesn't spam the shell every poll cycle.
    if (service.unlockFailures > 0
        && service.lastUnlockAttemptAt
        && (Date.now() - service.lastUnlockAttemptAt) < service.unlockRetryMs) return
    service.lastUnlockAttemptAt = Date.now()
    unlockProc.command = ["bash", "-lc",
      "qs -p /usr/share/omarchy/shell ipc call lock unlock"]
    unlockProc.running = true
  }

  // Tell the user *why* the auto-unlock didn't happen. Silently staying
  // locked looks like a broken plugin; the most common cause is a missing
  // IPC patch on the lock plugin, which is a one-command fix.
  function notifyUnlockFailure(result) {
    if (service.unlockFailures !== 1) return  // notify once per streak
    var hint = String(result).indexOf("Function not found") >= 0
      ? "Omarchy's lock plugin has no 'unlock' method. Install it with:\n  sudo bash patches/install-lock-unlock-ipc.sh\nthen: omarchy restart shell"
      : "Unlock IPC failed: " + result
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "bleguard",
      "-u", "critical",
      "-t", "15000",
      "-i", "bluetooth-symbolic",
      "Auto-unlock failed",
      hint
    ])
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
    // Fresh lock cycle — clear the previous unlock bookkeeping.
    service.unlockFailures = 0
    service.unlockRequested = false
    service.lastUnlockResult = ""
    Quickshell.execDetached(["bash", "-lc", "omarchy-system-lock"])
    lockCheckTimer.start()
  }

  function postGraceNotification() {
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "bleguard",
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

  // The grace period between "the reading crossed the threshold" and "the
  // notification appears and the lock procedure starts". 0 = no delay.
  function setGraceMs(value) {
    var n = parseInt(value, 10)
    if (isNaN(n)) return false
    if (n < 0) n = 0
    if (n > 600000) n = 600000
    persisted.lostEntryMs = n
    return true
  }

  // How long the phone has to stay completely silent (no ACL, no
  // advertisement, no reading) before it counts as out of range.
  // 0 = the first missing heartbeat is enough.
  function setAbsentAfterMs(value) {
    var n = parseInt(value, 10)
    if (isNaN(n)) return false
    if (n < 0) n = 0
    if (n > 3600000) n = 3600000
    persisted.absentAfterMs = n
    return true
  }

  function setTarget(mac) {
    if (typeof mac !== "string") return false
    var next = mac.trim()
    var changed = next.toUpperCase() !== String(persisted.targetMac).trim().toUpperCase()
    persisted.targetMac = next
    if (changed) {
      // Everything we knew was about the *previous* phone: its last reading,
      // its advertisement, the poll baseline, the presence clocks. None of it
      // says anything about the new one, and a stale reading must never
      // decide the presence of another device.
      service.resetPresenceState()
      // The running helper still watches the old device: it has to be
      // stopped and started again with the new command, and until it is
      // rebound its lines are rejected by their MAC tag.
      service.rebindHelper()
    }
    // Fresh pairing — restart the warm-up so we don't immediately fire
    // a WARNING because RSSI hasn't been polled yet.
    service.state = service.armed ? "ARMED" : "DISARMED"
    if (service.armed && persisted.targetMac) {
      rssiPollTimer.start()
      service.startWarmup()
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
      service.unlockFailures = 0
      service.unlockRequested = false
      service.lastUnlockResult = ""
      service.state = "DISARMED"
    } else {
      service.state = "ARMED"
      if (persisted.targetMac) {
        rssiPollTimer.start()
        service.startRssiPoll()
        // Warm-up while the first reading arrives. Without this, if BlueZ
        // never exposes RSSI for a paired device, phoneLost() can
        // immediately trigger because both rssiAt and rssi stay at 0.
        service.startWarmup()
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

  // Custom control IPC on a separate target — `bleguard` itself is
  // already claimed by the base Omarchy Panel's IpcHandler (show/hide/toggle).
  IpcHandler {
    target: "bleguard.ctrl"

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
        rssiAgeMs: service.rssiAgeMs(),
        rssiValueChangeAt: service.lastRssiValueChangeAt,
        rssiSource: service.rssiSource,
        rssiFresh: Ble.isRssiFresh(service.presenceOpts()),
        advAt: service.lastAdvAt,
        advertisingEverObserved: service.advertisingEverObserved,
        presence: service.presenceSource(),
        presenceLevel: Ble.presenceLevel(service.presenceOpts()),
        presenceWarmup: service.presenceWarmup,
        phonePresent: service.phonePresent(),
        helperReady: service.helperReady,
        helperError: service.helperError,
        helperRestarts: service.helperRestarts,
        helperForeignEvents: service.helperForeignEvents,
        helperUntaggedEvents: service.helperUntaggedEvents,
        unlockResult: service.lastUnlockResult,
        unlockFailures: service.unlockFailures,
        unlockRequested: service.unlockRequested,
        distance: service.distanceMeters,
        historyPoints: service.rssiHistory.length,
        history: service.rssiHistory,
        discovering: Bluetooth.defaultAdapter ? Bluetooth.defaultAdapter.discovering : false,
        idle: service.idle,
        threshold: service.rssiThreshold,
        lostEntryMs: service.lostEntryMs,
        absentAfterMs: service.absentAfterMs,
        silenceAgeMs: Ble.silenceAgeMs(service.presenceOpts()),
        phoneLostSince: service.phoneLostSince,
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

    function setGraceMs(value: int): string {
      return service.setGraceMs(value) ? "ok" : "invalid"
    }

    function setAbsentAfterMs(value: int): string {
      return service.setAbsentAfterMs(value) ? "ok" : "invalid"
    }

    function lockNow(): string {
      service.triggerLock()
      return "locking"
    }
  }
}