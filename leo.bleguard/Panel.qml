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
  moduleName: "leo.bleguard"
  ipcTarget: "leo.bleguard"

  // Without these, root.bar.shell.serviceFor() returns null and the panel stays empty.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var svc: root.bar && root.bar.shell ? root.bar.shell.serviceFor("leo.bleguard") : null

  readonly property string state: svc ? svc.state : "DISARMED"
  readonly property bool armed: svc ? svc.armed : false
  readonly property string targetMac: svc ? svc.targetMac : ""
  readonly property int lastRssi: svc ? svc.lastRssi : 0
  readonly property int lastRssiAt: svc ? svc.lastRssiAt : 0
  readonly property int threshold: svc ? svc.rssiThreshold : -85
  readonly property bool idle: svc ? svc.idle : false

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
            visible: root.armed && !root.targetMac

            Text {
              text: "No phone paired yet. Pick the device you carry with you:"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Math.min(Style.space(280),
                Style.space(36) + Math.max(0, root.svc ? root.svc.listPaired().length : 0) * Style.space(32))
              color: root.surface
              radius: Style.cornerRadius
              border.color: Qt.darker(root.surface, 1.3)
              border.width: 1

              ListView {
                id: pairList
                anchors.fill: parent
                anchors.margins: Style.space(4)
                clip: true
                currentIndex: -1
                spacing: 2
                model: root.svc ? root.svc.listPaired() : []
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  width: pairList.width
                  height: Style.space(32)
                  color: index % 2 === 0 ? root.surface : Qt.lighter(root.surface, 2.0)
                  radius: Style.cornerRadius / 2

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(12)

                    Text {
                      text: modelData.name || "(unnamed)"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                      Layout.preferredWidth: Style.space(200)
                    }
                    Text {
                      text: modelData.address
                      color: root.dim
                      font.family: "monospace"
                      font.pixelSize: Style.font.caption
                      Layout.preferredWidth: Style.space(140)
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                      text: "Pick"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (root.svc) root.svc.setTarget(modelData.address)
                    }
                  }
                }

                Text {
                  anchors.centerIn: parent
                  visible: pairList.count === 0
                  text: "No paired BLE devices found.\nPair your phone with `bluetoothctl pair <mac>` first."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignHCenter
                }
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

            // Footer note when RSSI is stale or never observed (e.g. BR/EDR
            // phone that doesn't expose one, or phone currently out of range).
            Text {
              visible: !root.rssiFresh && root.armed && root.targetMac !== ""
              text: root.lastRssi === 0
                ? "RSSI not exposed by BlueZ for this device (BR/EDR phones usually don't advertise over BLE)."
                : "Phone out of BLE range — no live RSSI."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
              Layout.topMargin: Style.space(-4)
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