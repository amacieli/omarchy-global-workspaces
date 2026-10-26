import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.amacieli.global-workspaces"

  // ── Global-mode detection ─────────────────────────────────────────────────
  // Probe for the toggle flag file with a Process (bash test), re-triggered
  // whenever the toggles directory changes. This is the same pattern Bar.qml
  // uses for windowNoGapsToggle — it avoids StandardPaths (QtCore, not
  // imported) and FileView.exists (not a Quickshell property).

  readonly property string globalToggleDir:
    (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state"))
    + "/omarchy/toggles/hypr"

  property bool globalModeActive: false

  Process {
    id: globalFlagProbe
    running: true
    command: ["bash", "-c",
      "[[ -f ${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr/workspace-global.lua ]] && echo yes || echo no"]
    stdout: SplitParser {
      onRead: function(line) { root.globalModeActive = String(line).trim() === "yes" }
    }
  }

  // Re-probe whenever the toggles directory is created, deleted, or modified.
  FileView {
    path: root.globalToggleDir
    watchChanges: true
    printErrors: false
    onFileChanged: globalFlagProbe.running = true
  }

  // Periodic re-probe timer: FileView.watchChanges can miss events after rapid
  // changes (documented in Bar.qml). Without this fallback, the widget can show
  // the wrong slots until the shell restarts. Re-run the probe every 2 seconds
  // to catch any state drift.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: globalFlagProbe.running = true
  }

  // ── Slot/ID mapping helpers ───────────────────────────────────────────────
  // In local mode (globalModeActive == false):
  //   slot == raw workspace ID (IDs 1–10, one set per machine).
  // In global mode (globalModeActive == true):
  //   Each monitor owns IDs (base+1)..(base+10).
  //   slot = ((id - 1) % 10) + 1 maps any raw ID back to a logical slot 1–10.
  //   Example: monitor-2 base=10: ID 12 → slot 2.

  function slotOfId(id) {
    if (!root.globalModeActive) return id
    if (id <= 0) return -1
    // Use the highest known workspace ID as the upper bound rather than a
    // hardcoded 99. A tenth distinct monitor name gets base 90, pushing IDs
    // above 99. Math.max(99, maxKnownId) keeps the bound correct and never
    // tighter than the original hardcoded value.
    var values = Hyprland.workspaces.values
    var maxKnownId = 99
    for (var i = 0; i < values.length; i++) {
      if (values[i].id > maxKnownId) maxKnownId = values[i].id
    }
    if (id > maxKnownId) return -1
    return ((id - 1) % 10) + 1
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  // Returns true if any workspace mapped to this slot (across all monitors) has windows.
  function slotOccupied(slot) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (slotOfId(id) === slot && values[i].toplevels.values.length > 0) return true
    }
    return false
  }

  // Returns true if the currently focused workspace maps to this slot.
  function slotFocused(slot) {
    if (Hyprland.focusedWorkspace === null) return false
    return slotOfId(Hyprland.focusedWorkspace.id) === slot
  }

  function workspaceIds() {
    var slots = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      var slot = slotOfId(id)
      // Slots 1–5 are always shown. Beyond that, show a slot only while it is
      // occupied or focused: persistent (empty) workspaces exist for all ten
      // slots, so existence alone must not make a slot appear.
      if (slot > 5 && slot <= 10 && slots.indexOf(slot) === -1
          && (root.slotOccupied(slot) || root.slotFocused(slot))) slots.push(slot)
    }

    slots.sort(function(left, right) { return left - right })
    return slots
  }

  // Click handlers run the plugin's own scripts by absolute path, so they work
  // without bin/ on PATH. Global mode switches every monitor together; local
  // mode focuses the raw workspace on the current monitor, like the built-in.
  readonly property string binDir:
    Qt.resolvedUrl("bin").toString().replace(/^file:\/\//, "")

  function focusWorkspace(slot) {
    if (root.globalModeActive) {
      Quickshell.execDetached([root.binDir + "/omarchy-switch-to-aw", String(slot)])
    } else {
      Quickshell.execDetached(["hyprctl", "dispatch",
        "hl.dsp.focus({ workspace = \"" + slot + "\" })"])
    }
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        required property int modelData

        // modelData is always a logical slot (1–10) in both local and global mode.
        readonly property bool occupied: root.slotOccupied(modelData)
        readonly property bool focused: root.slotFocused(modelData)

        bar: root.bar
        text: focused ? "\uDB85\uDCFB" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }
      }
    }
  }
}
