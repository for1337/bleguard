import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth

import qs.Commons
import qs.Ui

import "BleLogic.js" as Ble

Panel {
  id: root
  moduleName: "bleguard"
  ipcTarget: "bleguard"

  // Without these, root.bar.shell.serviceFor() returns null and the panel stays empty.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var svc: root.bar && root.bar.shell ? root.bar.shell.serviceFor("bleguard") : null

  // IMPORTANT: lastRssiAt is var in Service.qml because Date.now() in 2026
  // is ~1.79e12 ms — fits in a JS double but overflows QML's 32-bit int.
// Convert back via Number() and * 1 to avoid auto-int coercion.
readonly property string state: svc ? svc.state : "DISARMED"
  readonly property bool armed: svc ? svc.armed : false
  readonly property string targetMac: svc ? svc.targetMac : ""
  readonly property int lastRssi: svc && svc.lastRssi !== undefined ? Number(svc.lastRssi) : 0
  readonly property var lastRssiAt: svc && svc.lastRssiAt !== undefined ? Number(svc.lastRssiAt) : 0
  // Stamps only when the RSSI VALUE actually changes (not on every poll).
  readonly property var lastRssiValueChangeAt: svc && svc.lastRssiValueChangeAt !== undefined ? Number(svc.lastRssiValueChangeAt) : 0
  readonly property int threshold: svc ? svc.rssiThreshold : -85
  readonly property bool idle: svc ? svc.idle : false
  readonly property var rssiHistory: svc ? svc.rssiHistory : []
  // True once Service.qml has received at least one valid RSSI from BlueZ.
  // When false after the plugin has been armed, BlueZ is hiding RSSI for
  // this device — almost always the paired+trusted quirk — and
  // the chart will sit empty. We surface this as a non-"Collecting data…"
  // message so the user doesn't think the plugin is still loading.
  readonly property bool rssiEverObserved: svc ? svc.rssiEverObserved : false

  // 1 Hz heartbeat. Several values below depend on the *age* of the last
  // reading, so they have to be recomputed even when no new reading
  // arrives — a plain property binding would freeze at the moment the
  // reading was published.
  property int tick: 0
  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: root.tick += 1
  }

  // How long a reading stays "fresh". The service owns this value (the
  // filtered-discovery helper turns every advertisement into a heartbeat),
  // the panel just mirrors it.
  readonly property int staleWindowMs: {
    root.tick
    return root.svc && root.svc.rssiStaleWindowMs !== undefined ? Number(root.svc.rssiStaleWindowMs) : 45000
  }

  // Read the live values straight from the service instead of going through
  // the cached bindings above: Quickshell can drop the change notification
  // of a service property across the process boundary, which would freeze
  // the age of the reading (and with it the "old" markers and the chart).
  // Re-reading them on every tick keeps them correct anyway.
  function svcRssi() {
    return root.svc && root.svc.lastRssi !== undefined ? Number(root.svc.lastRssi) : 0
  }
  function svcRssiAt() {
    return root.svc && root.svc.lastRssiAt !== undefined ? Number(root.svc.lastRssiAt) : 0
  }
  function svcThreshold() {
    return root.svc && root.svc.rssiThreshold !== undefined ? Number(root.svc.rssiThreshold) : -85
  }
  // The grace period: how long the reading has to stay out of range before
  // the notification appears and the lock procedure starts. Stored in ms,
  // shown in seconds.
  function svcGraceMs() {
    return root.svc && root.svc.lostEntryMs !== undefined ? Number(root.svc.lostEntryMs) : 5000
  }
  readonly property int graceSeconds: {
    root.tick
    return Math.round(root.svcGraceMs() / 1000)
  }

  readonly property int rssiValue: {
    root.tick
    return root.svcRssi()
  }

  // True when the last RSSI is recent enough to trust.
  readonly property bool rssiFresh: {
    root.tick
    var at = root.svcRssiAt()
    return root.svcRssi() !== 0
      && at !== 0
      && (Date.now() - at) <= root.staleWindowMs
  }

  // A value we have, but that is older than the freshness window: the
  // phone stopped advertising (its own duty cycle), it did not leave.
  readonly property bool rssiStale: root.svcRssi() !== 0 && !root.rssiFresh
  readonly property int rssiAgeSec: {
    root.tick
    var at = root.svcRssiAt()
    return at !== 0 ? Math.floor((Date.now() - at) / 1000) : 0
  }

  // Distance estimate, recomputed here for the same reason as above.
  readonly property real distance: {
    root.tick
    var v = root.svcRssi()
    if (!v) return 0
    var tx = root.svc && root.svc.txPower !== undefined ? Number(root.svc.txPower) : -59
    var pl = root.svc && root.svc.pathLoss !== undefined ? Number(root.svc.pathLoss) : 2.5
    return Math.pow(10, (tx - v) / (10 * pl))
  }

  // Which channel carries the decision right now: "acl" (BR/EDR link),
  // "rssi" (fresh reading), "rssi-stale" (last known value), "adv"
  // (advertisement only), "none" (nothing).
  readonly property string presenceLevel: {
    root.tick
    return root.svc ? root.svc.presenceSource() : "none"
  }

  // The rule the plugin actually applies: the RSSI *value* decides,
  // compared against the threshold. A value at or above the threshold
  // means the phone is close enough → in range → stay unlocked.
  readonly property bool inRange: {
    root.tick
    var v = root.svcRssi()
    if (v === 0) return false
    return v >= root.svcThreshold()
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string iconText: {
    switch (state) {
      case "ARMED":   return "󰐜"   // shield-check
      case "WARNING": return "󰀦"   // warning
      case "WAITING": return "󰀦"
      case "LOCKING": return "󰮃"   // ball-pulse
      case "LOCKED":  return "󰍢"   // lock
      default:        return "󰐛"   // shield-off (DISARMED + unknown)
    }
  }

  readonly property string tooltipText: Ble.stateLabel(state)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    tooltipText: root.tooltipText

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)
    padding: Style.space(16)
    centerOnBar: true

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      ColumnLayout {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---- Header -----------------------------------------------------
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: root.iconText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            Layout.alignment: Qt.AlignVCenter
          }

          ColumnLayout {
            spacing: 0
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true

            Text {
              text: "BLE Auto-Lock"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: Ble.stateLabel(root.state)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Toggle ---------------------------------------------------
          Switch {
            checked: root.armed
            onToggled: {
              if (!root.svc) return
              if (checked) root.svc.setArmed(true)
              else root.svc.setArmed(false)
            }
          }
        }

        // ---- Disarmed / no device --------------------------------------
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: pairingBlock.visible ? pairingBlock.implicitHeight : disarmedBlock.visible ? disarmedBlock.implicitHeight : 0

          ColumnLayout {
            id: disarmedBlock
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.armed === false

            Text {
              text: "Auto-lock is off. Flip the switch to enable it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }
          }

          ColumnLayout {
            id: pairingBlock
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.armed && !root.targetMac && root.svc && root.svc.listPaired().length === 0

            Text {
              text: "No phone paired yet. Pick the device you carry with you from the menu above — or pair it first with `bluetoothctl pair <mac>`."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }
          }
        }

        // ---- Device picker (always visible when armed) -----------------
        // Hoisted out of pairingBlock so the user can change device or
        // unpair from the popup at any time — not only during the
        // first-time setup wizard.
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: devicePicker.visible ? devicePicker.implicitHeight + Style.space(8) : 0
          visible: root.armed

          ColumnLayout {
            id: devicePicker
            anchors.fill: parent
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(40)
                color: root.surface
                radius: Style.cornerRadius
                border.color: Qt.darker(root.surface, 1.3)
                border.width: 1

                ComboBox {
                  id: pairCombo
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  enabled: root.svc && root.svc.listPaired().length > 0
                  model: root.svc ? root.svc.listPaired() : []
                  textRole: "name"
                  valueRole: "address"

                  // Keep the dropdown synchronized with the persisted
                  // target so reopening the popup shows the currently
                  // paired phone selected, even after a shell restart.
                  Connections {
                    target: root.svc
                    function onTargetMacChanged() { pairCombo.syncToTarget() }
                  }
                  function syncToTarget() {
                    var paired = root.svc ? root.svc.listPaired() : []
                    var cur = (root.targetMac || "").toLowerCase()
                    for (var i = 0; i < paired.length; i++) {
                      if ((paired[i].address || "").toLowerCase() === cur) {
                        currentIndex = i
                        return
                      }
                    }
                    currentIndex = -1
                  }
                  Component.onCompleted: syncToTarget()

                  // Show "<name>  ·  <mac>" in the collapsed trigger so
                  // the user can confirm the MAC of the selected phone.
                  displayText: {
                    if (currentIndex < 0) return "Pick device…"
                    var item = model[currentIndex]
                    if (!item) return ""
                    var mac = item.address || ""
                    return (item.name || "(unnamed)") + (mac ? "  ·  " + mac : "")
                  }

                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  onActivated: if (root.svc && currentValue) root.svc.setTarget(currentValue)
                }
              }

              Button {
                text: "Unpair"
                visible: root.targetMac !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.svc) root.svc.setTarget("")
              }
            }
          }
        }

        // ---- Status (armed + paired) -----------------------------------
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: visible ? statusBlock.implicitHeight : 0
          visible: root.armed && root.targetMac !== ""

          ColumnLayout {
            id: statusBlock
            anchors.fill: parent
            spacing: Style.space(8)

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(28)
              color: Qt.darker(root.surface, 1.08)
              radius: Style.cornerRadius

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(8)

                Text {
                  text: "RSSI"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.preferredWidth: Style.space(60)
                }
                Text {
                  text: {
                    if (root.rssiValue === 0) return "—"
                    // A stale value is still the best evidence we have:
                    // show it, but mark it as old instead of hiding it.
                    return root.rssiValue + " dBm" + (root.rssiStale ? " (old)" : "")
                  }
                  color: root.rssiValue === 0 ? root.dim : (root.rssiStale ? root.dim : root.foreground)
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  Layout.preferredWidth: Style.space(140)
                  elide: Text.ElideRight
                }
                Text {
                  text: "Signal"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.preferredWidth: Style.space(60)
                }
                Text {
                  text: {
                    if (root.rssiValue === 0) return "—"
                    var bars = Ble.signalBars(root.rssiValue)
                    var out = ""
                    for (var i = 0; i < 4; i++) out += (i < bars ? "█" : "")
                    return out || "—"
                  }
                  color: root.rssiValue === 0 ? root.dim : (root.rssiStale ? root.dim : root.foreground)
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                }
              }
            }

            // Footer note under the RSSI box.
            //
            // Three cases, three very different meanings:
            //   1. BlueZ never exposed an RSSI at all (older BR/EDR-only
            //      phones) — the plugin falls back to the advertisement
            //      channel.
            //   2. The phone went quiet: its beacon duty cycle, NOT a range
            //      problem. The last known value is still shown and still
            //      drives the decision. This is the case that used to
            //      produce a bogus "Phone out of range" notification.
            //   3. A fresh reading — nothing to warn about.
            Text {
              visible: root.armed && root.targetMac !== "" && (root.rssiValue === 0 || root.rssiStale)
              text: {
                if (root.rssiValue === 0)
                  return "RSSI not exposed by BlueZ for this device. Most often: paired+trusted phones hide RSSI after bonding — BLE advertising still works, plugin still detects presence."
                var mins = Math.max(1, Math.floor(root.rssiAgeSec / 60))
                var verdict = root.inRange ? "still counted as IN RANGE" : "still counted as OUT OF RANGE"
                return "Phone quiet for " + mins + " min (its beacon duty cycle, not a range problem). " +
                       "Last known " + root.rssiValue + " dBm vs threshold " + root.svcThreshold() + " → " + verdict + "."
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
              Layout.topMargin: Style.space(-4)
            }

            // ---- Presence row -------------------------------------------
            // Makes the decision explicit: which channel is carrying it and
            // what the current RSSI value means against the threshold.
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(28)
              color: Qt.darker(root.surface, 1.08)
              radius: Style.cornerRadius
              visible: root.armed && root.targetMac !== ""

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(8)

                Text {
                  text: "Presence"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.preferredWidth: Style.space(60)
                }
                Text {
                  text: {
                    if (root.presenceLevel === "acl") return "connected (BR/EDR link up)"
                    if (root.rssiValue === 0) return "unknown — no reading yet"
                    var rel = root.inRange ? "≥" : "<"
                    var base = root.rssiValue + " dBm " + rel + " thr " + root.svcThreshold() + " → " + (root.inRange ? "in range" : "out of range")
                    if (root.rssiStale) return base + " (last known)"
                    return base
                  }
                  color: root.rssiValue === 0 ? root.dim : (root.inRange ? root.foreground : Qt.darker(root.foreground, 1.4))
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
              }
            }

            // ---- Distance box ----
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(28)
              color: Qt.darker(root.surface, 1.08)
              radius: Style.cornerRadius

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(8)

                Text {
                  text: "Distance"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.preferredWidth: Style.space(60)
                }
                Text {
                  text: {
                      if (!root.rssiValue || !root.distance) return "—"
                      if (root.distance < 1.0)
                        return (root.distance * 100).toFixed(0) + " cm"
                      if (root.distance < 10)
                        return root.distance.toFixed(2) + " m"
                      return root.distance.toFixed(1) + " m"
                    }
                  color: !root.rssiValue ? root.dim : (root.rssiStale ? root.dim : root.foreground)
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                }
              }
            }

            // ---- RSSI history chart ----
            // Canvas doesn't auto-redraw on QML property updates, so we bind
            // history/threshold to local aliases and call requestPaint() on change.
            Rectangle {
              id: chartFrame
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(120)
              color: Qt.darker(root.surface, 1.08)
              radius: Style.cornerRadius
              border.color: Qt.darker(root.surface, 1.3)
              border.width: 1

              readonly property var history: root.rssiHistory
              readonly property int thr: root.svcThreshold()
              readonly property int rssiMin: -100
              readonly property int rssiMax: -30
              readonly property bool rssiEverObserved: root.rssiEverObserved
              readonly property bool armed: root.armed
              readonly property bool targetSet: root.targetMac !== ""

              Canvas {
                id: chart
                anchors.fill: parent
                anchors.margins: Style.space(6)
                antialiasing: true
                renderTarget: Canvas.Image

                property var history: chartFrame.history
                property int thr: chartFrame.thr
                property int rssiMin: chartFrame.rssiMin
                property int rssiMax: chartFrame.rssiMax
                property bool rssiEverObserved: chartFrame.rssiEverObserved
                property bool armed: chartFrame.armed
                property bool targetSet: chartFrame.targetSet

                // Quickshell panels sometimes lose the property-
                // change notification when the source is reached
                // through serviceFor() → chartFrame.thr →
                // chart.thr (multiple QObject hops across IPC).
                // Add an explicit Connections so the canvas
                // always repaints when the user's threshold
                // changes — the binding still works, this is a
                // safety net so the dashed thr line moves even
                // if the chain fails.
                Connections {
                  target: root
                  function onThresholdChanged() {
                    chart.thr = root.svcThreshold()
                    chart.requestPaint()
                  }
                  function onRssiHistoryChanged() {
                    chart.history = root.rssiHistory
                    chart.requestPaint()
                  }
                }

                onHistoryChanged: chart.requestPaint()
                onThrChanged: chart.requestPaint()
                onRssiMinChanged: chart.requestPaint()
                onRssiMaxChanged: chart.requestPaint()
                onWidthChanged: chart.requestPaint()
                onHeightChanged: chart.requestPaint()
                onRssiEverObservedChanged: chart.requestPaint()
                onArmedChanged: chart.requestPaint()
                onTargetSetChanged: chart.requestPaint()

                // Safety net: repaint at 1 Hz in case the history signal
                // ever stops propagating (e.g. array reassigned to itself).
                Timer {
                    running: chart.visible
                    interval: 1000
                    repeat: true
                    onTriggered: chart.requestPaint()
                  }

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()

                  // Background
                  ctx.fillStyle = chartFrame.color
                  ctx.fillRect(0, 0, width, height)

                  var pad = 4
                  var w = width - pad * 2
                  var h = height - pad * 2
                  var rssiRange = chart.rssiMax - chart.rssiMin

                  function yForRssi(r) {
                    return pad + (chart.rssiMax - r) / rssiRange * h
                  }

                  // Gridlines every 10 dBm
                  ctx.strokeStyle = Qt.darker(chartFrame.color, 1.4)
                  ctx.lineWidth = 1
                  ctx.font = "9px monospace"
                  ctx.fillStyle = root.dim
                  ctx.textBaseline = "middle"
                  for (var r = chart.rssiMin; r <= chart.rssiMax; r += 20) {
                    var y = Math.round(yForRssi(r)) + 0.5
                    ctx.beginPath()
                    ctx.moveTo(pad, y)
                    ctx.lineTo(width - pad, y)
                    ctx.stroke()
                    ctx.fillText(r, width - pad - 22, y)
                  }

                  // Threshold line
                  var thrY = Math.round(yForRssi(chart.thr)) + 0.5
                  ctx.strokeStyle = Qt.rgba(root.foreground.r,
                                                   root.foreground.g,
                                                   root.foreground.b, 0.45)
                  ctx.setLineDash([4, 4])
                  ctx.lineWidth = 1
                  ctx.beginPath()
                  ctx.moveTo(pad, thrY)
                  ctx.lineTo(width - pad, thrY)
                  ctx.stroke()
                  ctx.setLineDash([])
                  ctx.fillStyle = root.dim
                  ctx.textAlign = "left"
                  // Spell out the rule the plugin applies, so the chart and
                  // the state can never look contradictory: the curve above
                  // the dashed line means a strong signal → phone close.
                  var thrLabelY = (thrY - 8) > (pad + 6) ? (thrY - 8) : (thrY + 10)
                  ctx.fillText("thr " + chart.thr + "  ·  below = out of range", pad + 2, thrLabelY)

                  if (!chart.history || chart.history.length < 2) {
                    ctx.fillStyle = root.dim
                    ctx.textAlign = "center"
                    ctx.textBaseline = "middle"
                    // If the plugin is armed and has a target but BlueZ has
                    // never given us a usable RSSI, this is almost always
                    // the paired+trusted quirk — don't mislead the
                    // user with an indefinite "Collecting data…".
                    if (chart.armed && chart.targetSet && !chart.rssiEverObserved) {
                      ctx.fillText("No RSSI — BlueZ isn't exposing one for this device.",
                                   width / 2, height / 2 - 8)
                      ctx.font = "8px monospace"
                      ctx.fillText("Plugin still uses BLE advertising for proximity.",
                                   width / 2, height / 2 + 8)
                    } else if (root.rssiValue !== 0) {
                      // We have a value, but it is older than the freshness
                      // window: the phone went quiet. Draw the last known
                      // level as a dashed line instead of an empty chart —
                      // that is the level the decision is currently based on.
                      var ly = Math.round(yForRssi(root.rssiValue)) + 0.5
                      ctx.strokeStyle = Qt.rgba(root.foreground.r,
                                                   root.foreground.g,
                                                   root.foreground.b, 0.5)
                      ctx.setLineDash([3, 4])
                      ctx.lineWidth = 1
                      ctx.beginPath()
                      ctx.moveTo(pad, ly)
                      ctx.lineTo(width - pad, ly)
                      ctx.stroke()
                      ctx.setLineDash([])
                      ctx.fillStyle = root.dim
                      ctx.font = "bold 10px monospace"
                      ctx.fillText("last known " + root.rssiValue + " dBm",
                                   width / 2, ly - 10)
                      ctx.font = "8px monospace"
                      ctx.fillText("phone quiet for " +
                                   Math.max(1, Math.floor(root.rssiAgeSec / 60)) +
                                   " min — no new advertisements",
                                   width / 2, ly + 12)
                    } else {
                      ctx.fillText("Collecting data…", width / 2, height / 2)
                    }
                    return
                  }

                  // X axis: oldest at left, newest at right. The axis ends
                  // at "now" even when the last reading is older, so the
                  // silence of a quiet phone is visible as empty space
                  // instead of a line frozen at the right edge.
                  var h0 = chart.history
                  var tMin = h0[0].t
                  var tMax = Math.max(h0[h0.length - 1].t, Date.now())
                  var tRange = Math.max(tMax - tMin, 1)

                  function xForT(t) {
                    return pad + (t - tMin) / tRange * w
                  }

                  // Split the history into contiguous segments. A gap longer
                  // than the freshness window means the phone stopped
                  // advertising: the line breaks there instead of pretending
                  // the measured value stayed constant.
                  var gapMs = root.staleWindowMs
                  var segments = []
                  var seg = []
                  for (var k = 0; k < h0.length; k++) {
                    if (seg.length > 0 && (h0[k].t - h0[seg.length - 1].t) > gapMs) {
                      segments.push(seg)
                      seg = []
                    }
                    seg.push(h0[k])
                  }
                  if (seg.length > 0) segments.push(seg)

                  // Soft fill under the most recent segment only: filling
                  // across a gap would draw a triangle over a period for
                  // which we have no data at all.
                  var lastSeg = segments[segments.length - 1]
                  ctx.fillStyle = Qt.rgba(root.foreground.r,
                                               root.foreground.g,
                                               root.foreground.b, 0.10)
                  ctx.beginPath()
                  ctx.moveTo(xForT(lastSeg[0].t), yForRssi(lastSeg[0].rssi))
                  for (var i = 1; i < lastSeg.length; i++) {
                    ctx.lineTo(xForT(lastSeg[i].t), yForRssi(lastSeg[i].rssi))
                  }
                  ctx.lineTo(xForT(lastSeg[lastSeg.length - 1].t), pad + h)
                  ctx.lineTo(xForT(lastSeg[0].t), pad + h)
                  ctx.closePath()
                  ctx.fill()

                  // RSSI line, broken at the gaps
                  ctx.strokeStyle = root.foreground
                  ctx.lineWidth = 1.5
                  ctx.lineJoin = "round"
                  for (var s = 0; s < segments.length; s++) {
                    var sg = segments[s]
                    ctx.beginPath()
                    for (var j = 0; j < sg.length; j++) {
                      var px = xForT(sg[j].t)
                      var py = yForRssi(sg[j].rssi)
                      if (j === 0) ctx.moveTo(px, py)
                      else ctx.lineTo(px, py)
                    }
                    ctx.stroke()
                  }

                  // Latest point dot — hollow when it is only the last known
                  // value of a silent phone, so a frozen chart cannot be
                  // mistaken for a live reading.
                  var last = h0[h0.length - 1]
                  var lastIsStale = (Date.now() - last.t) > gapMs
                  ctx.strokeStyle = root.foreground
                  ctx.fillStyle = lastIsStale ? "transparent" : root.foreground
                  ctx.lineWidth = 1.5
                  ctx.beginPath()
                  ctx.arc(xForT(last.t), yForRssi(last.rssi), 2.5, 0, Math.PI * 2)
                  if (lastIsStale) ctx.stroke()
                  else ctx.fill()

                  // "now" label on the right edge
                  ctx.fillStyle = root.dim
                  ctx.textAlign = "right"
                  ctx.textBaseline = "bottom"
                  ctx.font = "9px monospace"
                  ctx.fillText("now →", width - pad - 2, height - 2)

                  // Current value label next to the latest point
                  var curLabel = last.rssi + " dBm" + (lastIsStale ? " (old)" : "")
                  ctx.fillStyle = lastIsStale ? root.dim : root.foreground
                  ctx.font = "bold 10px monospace"
                  ctx.textAlign = "right"
                  ctx.textBaseline = "middle"
                  var curY = yForRssi(last.rssi)
                  // Place label slightly above or below the dot depending on space
                  var labelY = curY > pad + h - 16 ? curY - 10 : curY + 10
                  ctx.fillText(curLabel, width - pad - 4, labelY)
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(28)
              color: Qt.darker(root.surface, 1.08)
              radius: Style.cornerRadius

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(8)

                Text {
                  text: "Idle"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.preferredWidth: Style.space(60)
                }
                Text {
                  text: root.idle ? "idle (≥30s)" : "active"
                  color: root.idle ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Button {
                text: "Lock now"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.armed && root.state !== "LOCKED" && root.state !== "LOCKING"
                onClicked: if (root.svc) root.svc.lockNow()
              }
              Item { Layout.fillWidth: true }
              NumberField {
                id: graceField
                label: "Grace (s)"
                value: root.graceSeconds
                from: 0
                to: 300
                stepSize: 1
                foreground: root.foreground
                fontFamily: root.fontFamily
                fieldWidth: Style.space(110)
                onModified: function(v) {
                  if (root.svc) root.svc.setGraceMs(v * 1000)
                }
              }
              NumberField {
                id: thresholdField
                label: "Threshold (dBm)"
                value: root.threshold
                from: -100
                to: -30
                stepSize: 1
                foreground: root.foreground
                fontFamily: root.fontFamily
                fieldWidth: Style.space(110)
                onModified: function(v) {
                  if (root.svc) root.svc.setThreshold(v)
                }
              }
            }
          }
        }

        Text {
          text: "The RSSI value is compared against the threshold: above it the phone counts as close (stay unlocked), below it as out of range — " +
                "after " + root.graceSeconds + " s below the threshold the warning appears, then the screen locks via Omarchy " +
                (root.svc && root.svc.graceSeconds !== undefined ? root.svc.graceSeconds : 10) + " s later if you are idle, " +
                "or as soon as you have been idle for 30 s. " +
                "If the phone stops advertising, the last known value keeps the decision instead of reporting a false \"out of range\". " +
                "Unlocking requires fresh proof that the phone is back."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
      }
    }
  }
}