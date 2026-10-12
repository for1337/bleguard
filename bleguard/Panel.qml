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
  // Used by the popup to flag BlueZ's cached readings — paired+bonded+
  // trusted ColorOS devices stop exposing fresh RSSI from advertisements,
  // so a long-elapsed change timestamp is the fingerprint of that quirk.
  readonly property var lastRssiValueChangeAt: svc && svc.lastRssiValueChangeAt !== undefined ? Number(svc.lastRssiValueChangeAt) : 0
  // Show a "cached" hint when the last real RSSI change is older than this.
  // Long enough that a stationary phone (genuine -39 sustained) doesn't
  // trigger; short enough that a 1m+ range change shows up within seconds
  // when BlueZ is actually updating.
  readonly property int rssiCachedAfterMs: 60000
  readonly property bool rssiAppearsStale: lastRssi !== 0
    && lastRssiValueChangeAt !== 0
    && (Date.now() - lastRssiValueChangeAt) > rssiCachedAfterMs
  readonly property real distance: svc && svc.distanceMeters !== undefined ? Number(svc.distanceMeters) : 0
  readonly property int threshold: svc ? svc.rssiThreshold : -85
  readonly property bool idle: svc ? svc.idle : false
  readonly property var rssiHistory: svc ? svc.rssiHistory : []
  // True once Service.qml has received at least one valid RSSI from BlueZ.
  // When false after the plugin has been armed, BlueZ is hiding RSSI for
  // this device — almost always the ColorOS paired+trusted quirk — and
  // the chart will sit empty. We surface this as a non-"Collecting data…"
  // message so the user doesn't think the plugin is still loading.
  readonly property bool rssiEverObserved: svc ? svc.rssiEverObserved : false

  // True only when we have a *fresh* RSSI reading (polled within 15s).
  // BlueZ caches the last value in memory even after the device disappears,
  // so we gate the display on both a non-zero value AND a recent timestamp.
  readonly property bool rssiFresh: lastRssi !== 0
    && lastRssiAt !== 0
    && Date.now() - lastRssiAt <= 15000

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
                  text: root.rssiFresh ? (root.lastRssi + " dBm") : "—"
                  color: root.rssiFresh ? root.foreground : root.dim
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  Layout.preferredWidth: Style.space(110)
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
                    if (!root.rssiFresh) return "—"
                    var bars = Ble.signalBars(root.lastRssi)
                    var out = ""
                    for (var i = 0; i < 4; i++) out += (i < bars ? "█" : "")
                    return out || "—"
                  }
                  color: root.rssiFresh ? root.foreground : root.dim
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                }
              }
            }

            // Footer note when RSSI is stale or never observed. Two flavors: the
            // RSSI value stopped updating at all (BlueZ caches it for
            // paired+bonded+trusted ColorOS devices — see omarchy-ble-
            // paired-stops-rssi memory), or it was never observed (older
            // BR/EDR-only phones that don't BLE-advertise). Either way
            // the plugin is still using BLE advertising as ground truth
            // for proximity.
            Text {
              visible: !root.rssiFresh && root.armed && root.targetMac !== ""
              text: root.lastRssi === 0
                ? "RSSI not exposed by BlueZ for this device. Most often: paired+trusted phones (ColorOS) hide RSSI after bonding — BLE advertising still works, plugin still detects presence."
                : "Phone out of BLE range — no live RSSI."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
              Layout.topMargin: Style.space(-4)
            }

            // Footer hint when the RSSI value once moved but stopped.
            // Different from the "never observed" case above: the chart
            // is showing a real value but it has not updated in a while,
            // which is the typical "BlueZ cached" fingerprint.
            Text {
              visible: root.rssiAppearsStale && root.armed
              text: "RSSI hasn't updated in " + Math.floor((Date.now() - root.lastRssiValueChangeAt) / 60000) + " min — BlueZ appears to cache RSSI for paired devices. Plugin still uses BLE advertising for proximity."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
              Layout.topMargin: Style.space(4)
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
                      if (!root.rssiFresh || !root.distance) return "—"
                      if (root.distance < 1.0)
                        return (root.distance * 100).toFixed(0) + " cm"
                      if (root.distance < 10)
                        return root.distance.toFixed(2) + " m"
                      return root.distance.toFixed(1) + " m"
                    }
                  color: root.distance ? root.foreground : root.dim
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
              readonly property int thr: root.threshold
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
                  ctx.fillText("thr " + chart.thr, pad + 2, thrY - 6)

                  if (!chart.history || chart.history.length < 2) {
                    ctx.fillStyle = root.dim
                    ctx.textAlign = "center"
                    ctx.textBaseline = "middle"
                    // If the plugin is armed and has a target but BlueZ has
                    // never given us a usable RSSI, this is almost always
                    // the paired+trusted ColorOS quirk — don't mislead the
                    // user with an indefinite "Collecting data…".
                    if (chart.armed && chart.targetSet && !chart.rssiEverObserved) {
                      ctx.fillText("No RSSI — BlueZ isn't exposing one for this device.",
                                   width / 2, height / 2 - 8)
                      ctx.font = "8px monospace"
                      ctx.fillText("Plugin still uses BLE advertising for proximity.",
                                   width / 2, height / 2 + 8)
                    } else {
                      ctx.fillText("Collecting data…", width / 2, height / 2)
                    }
                    return
                  }

                  // X axis: oldest at left, newest at right
                  var h0 = chart.history
                  var tMin = h0[0].t
                  var tMax = h0[h0.length - 1].t
                  var tRange = Math.max(tMax - tMin, 1)

                  function xForT(t) {
                    return pad + (t - tMin) / tRange * w
                  }

                  // Soft fill under the line
                  ctx.fillStyle = Qt.rgba(root.foreground.r,
                                               root.foreground.g,
                                               root.foreground.b, 0.10)
                  ctx.beginPath()
                  ctx.moveTo(xForT(h0[0].t), yForRssi(h0[0].rssi))
                  for (var i = 1; i < h0.length; i++) {
                    ctx.lineTo(xForT(h0[i].t), yForRssi(h0[i].rssi))
                  }
                  ctx.lineTo(xForT(h0[h0.length - 1].t), pad + h)
                  ctx.lineTo(xForT(h0[0].t), pad + h)
                  ctx.closePath()
                  ctx.fill()

                  // RSSI line
                  ctx.strokeStyle = root.foreground
                  ctx.lineWidth = 1.5
                  ctx.lineJoin = "round"
                  ctx.beginPath()
                  for (var j = 0; j < h0.length; j++) {
                    var px = xForT(h0[j].t)
                    var py = yForRssi(h0[j].rssi)
                    if (j === 0) ctx.moveTo(px, py)
                    else ctx.lineTo(px, py)
                  }
                  ctx.stroke()

                  // Latest point dot
                  var last = h0[h0.length - 1]
                  ctx.fillStyle = root.foreground
                  ctx.beginPath()
                  ctx.arc(xForT(last.t), yForRssi(last.rssi), 2.5, 0, Math.PI * 2)
                  ctx.fill()

                  // "now" label on the right edge
                  ctx.fillStyle = root.dim
                  ctx.textAlign = "right"
                  ctx.textBaseline = "bottom"
                  ctx.font = "9px monospace"
                  ctx.fillText("now →", width - pad - 2, height - 2)

                  // Current value label next to the latest point
                  var curLabel = last.rssi + " dBm"
                  ctx.fillStyle = root.foreground
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
          text: "When your phone leaves BLE range and you're idle for 30 seconds, the screen locks via Omarchy. " +
                "Bring the phone back (or unlock manually) to re-arm."
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