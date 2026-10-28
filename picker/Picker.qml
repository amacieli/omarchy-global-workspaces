import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Login checklist for Global Persisted mode, drawn like the Omarchy menu: a card
// centered on a dimmed full-screen overlay. Summoned by bin/omarchy-gws-summon.
//
//   Enter  launch the ticked apps, dismiss the unticked ones from the record
//   Esc    leave everything as it was (also: click outside the card)
//
// Rules live in lib/gws.py and bin/omarchy-gws-persist; this file only draws them.
Item {
  id: root

  // Injected by the shell (absent in the dev preview).
  property var shell: null
  property var manifest: null

  property bool opened: false
  property int cursor: 0
  property var targetScreen: null
  property bool confirmEmpty: false
  property bool showEmpty: false

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    u = u.replace(/^file:\/\//, "").replace(/\/picker\/?$/, "")
    return u
  }

  PickerState {
    id: pickerState
    root: root.pluginDir
    onLoadFinished: {
      if (!root.opened) return
      if (pickerState.rows.length === 0 && !pickerState.error && !root.showEmpty) root.dismiss()
    }
    onApplied: root.dismiss()
  }

  // The screen whose centre is closest to the centre of all screens together.
  function middleScreen() {
    var s = Quickshell.screens
    if (!s || s.length === 0) return null
    var minX = 1e9, maxX = -1e9
    for (var i = 0; i < s.length; i++) {
      minX = Math.min(minX, s[i].x)
      maxX = Math.max(maxX, s[i].x + s[i].width)
    }
    var mid = (minX + maxX) / 2, best = s[0], bestDist = 1e9
    for (var j = 0; j < s.length; j++) {
      var d = Math.abs(s[j].x + s[j].width / 2 - mid)
      if (d < bestDist) { bestDist = d; best = s[j] }
    }
    return best
  }

  // Host lifecycle: summon -> open(payloadJson); hide -> close().
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") || ({}) } catch (e) { payload = ({}) }
    if (payload.root) pickerState.root = String(payload.root)
    showEmpty = payload.showEmpty === true
    confirmEmpty = false
    cursor = 0
    targetScreen = middleScreen()
    pickerState.reset()
    opened = true
    pickerState.load()
  }

  function close() {
    if (!opened) return
    opened = false
    confirmEmpty = false
  }

  // Close from inside (Esc, Skip, done): also tell the host so it can unload us.
  function dismiss() {
    close()
    if (shell && manifest && typeof shell.hide === "function") shell.hide(manifest.id)
  }

  function launch() {
    if (pickerState.applying) return
    if (pickerState.rows.length === 0) { dismiss(); return }
    // Launching with nothing ticked dismisses every recorded app: make it deliberate.
    if (pickerState.tickedCount === 0) { confirm.selectedIndex = 0; confirmEmpty = true; return }
    pickerState.apply()
  }

  function move(delta) {
    var n = pickerState.rows.length
    if (n === 0) return
    cursor = Math.max(0, Math.min(n - 1, cursor + delta))
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  function toggleCursor() {
    var r = pickerState.rows[cursor]
    if (r) pickerState.toggle(r.id)
  }

  function handleKey(event) {
    if (pickerState.applying) { event.accepted = true; return }
    if (confirmEmpty) { event.accepted = confirm.handleKey(event); return }
    var k = event.key
    if (k === Qt.Key_Escape) dismiss()
    else if (k === Qt.Key_Down || k === Qt.Key_J) move(1)
    else if (k === Qt.Key_Up || k === Qt.Key_K) move(-1)
    else if (k === Qt.Key_Space || k === Qt.Key_X) toggleCursor()
    else if (k === Qt.Key_A) pickerState.toggleAll()
    else if (k === Qt.Key_Return || k === Qt.Key_Enter) launch()
    else return
    event.accepted = true
  }

  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened && pickerState.loaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-gws-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: Commons.Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      readonly property int rowH: Style.spacing.controlHeight
      readonly property int listMax: Math.max(rowH * 3, panel.height * 0.5)
      width: Math.min(panel.width - Style.space(32), Style.space(780))
      height: card.contentTopInset + card.contentBottomInset + body.implicitHeight
      anchors.centerIn: parent
      color: Commons.Color.menu.background
      borderSpec: Border.flat(Commons.Color.menu.border, Style.normalBorderWidth)
      radius: Style.cornerRadius
      padding: Style.space(18)

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: (event) => root.handleKey(event)

        ColumnLayout {
          id: body
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: card.contentTopInset
          anchors.leftMargin: card.contentLeftInset
          anchors.rightMargin: card.contentRightInset
          spacing: Style.space(10)

          Text {
            text: "Relaunch apps"
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: "From your last session. Launch dismisses the unticked apps from the record; Esc leaves everything as it was."
            wrapMode: Text.WordWrap
            color: Qt.darker(Commons.Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // Column header.
          RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Style.spacing.rowPaddingX
            Layout.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.space(12)
            Item { Layout.preferredWidth: Style.space(16) }
            Repeater {
              model: [
                { t: "WORKSPACE", w: Style.space(100), fill: false },
                { t: "MONITOR", w: Style.space(280), fill: false },
                { t: "APP", w: 0, fill: true }
              ]
              Text {
                required property var modelData
                Layout.preferredWidth: modelData.w
                Layout.fillWidth: modelData.fill
                text: modelData.t
                color: Qt.darker(Commons.Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Util.alpha(Commons.Color.foreground, 0.12) }

          ListView {
            id: list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(card.listMax, contentHeight)
            visible: pickerState.rows.length > 0
            clip: true
            interactive: contentHeight > height
            model: pickerState.rows
            delegate: PickerRow {
              width: list.width
              ticked: pickerState.ticked[modelData.id] === true
              hasCursor: root.cursor === index
              workspaceWidth: Style.space(100)
              monitorWidth: Style.space(280)
              onClicked: { root.cursor = index; pickerState.toggle(modelData.id) }
              onHovered: root.cursor = index
            }
          }

          Text {
            visible: pickerState.rows.length === 0 && !pickerState.error
            text: "Nothing recorded to relaunch."
            color: Qt.darker(Commons.Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            Layout.fillWidth: true
            visible: pickerState.error !== ""
            text: pickerState.error
            wrapMode: Text.WordWrap
            color: Commons.Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Util.alpha(Commons.Color.foreground, 0.12) }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)
            Text {
              Layout.fillWidth: true
              text: pickerState.applying ? "Launching " + pickerState.tickedCount + " app(s)..."
                  : "j/k move   space toggle   a all   enter launch   esc leave"
              color: Qt.darker(Commons.Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Button {
              bordered: true
              text: "Skip"
              enabled: !pickerState.applying
              onClicked: root.dismiss()
            }
            Button {
              bordered: true
              selected: true
              text: pickerState.tickedCount > 0 ? "Launch " + pickerState.tickedCount : "Launch"
              enabled: !pickerState.applying && pickerState.rows.length > 0
              onClicked: root.launch()
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: confirm
      anchors.fill: parent
      z: 10
      opened: root.confirmEmpty
      message: "Nothing is ticked. Launching now removes all " + pickerState.rows.length + " recorded apps."
      cancelText: "Back"
      confirmText: "Remove all"
      onCanceled: root.confirmEmpty = false
      onConfirmed: { root.confirmEmpty = false; pickerState.apply() }
    }
  }
}
