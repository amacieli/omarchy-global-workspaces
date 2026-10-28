import QtQuick
import Quickshell.Io

// Non-visual state for the login checklist: the rows, which are ticked, and the
// two backend calls. All data comes from lib/gws.py (picker-json) and is applied
// through bin/omarchy-gws-persist (relaunch --apply).
Item {
  id: state
  visible: false

  // Plugin directory (no trailing slash). Scripts are called by absolute path.
  property string root: ""

  property var rows: []
  property var ticked: ({})
  property bool loaded: false
  property bool applying: false
  property string error: ""
  readonly property int tickedCount: { var n = 0; for (var k in ticked) if (ticked[k]) n++; return n }

  signal loadFinished()
  signal applied()

  function reset() {
    rows = []; ticked = ({}); loaded = false; applying = false; error = ""
  }

  function isTicked(id) { return ticked[id] === true }

  function toggle(id) {
    var next = ({})
    for (var k in ticked) next[k] = ticked[k]
    next[id] = !next[id]
    ticked = next
  }

  // Tick everything, or untick everything when it is all ticked already.
  function toggleAll() {
    var all = rows.length > 0 && tickedCount === rows.length
    var next = ({})
    for (var i = 0; i < rows.length; i++) next[rows[i].id] = !all
    ticked = next
  }

  function tickedIds() {
    var ids = []
    for (var i = 0; i < rows.length; i++) if (ticked[rows[i].id]) ids.push(rows[i].id)
    return ids
  }

  function load() {
    if (loadProc.running) return
    error = ""
    loadProc.running = true
  }

  // Launch the ticked rows; every unticked row is dismissed from the record.
  function apply() {
    if (applying || applyProc.running) return
    error = ""
    applying = true
    applyProc.command = [root + "/bin/omarchy-gws-persist", "relaunch", "--apply"].concat(tickedIds())
    applyProc.running = true
  }

  Process {
    id: loadProc
    command: ["python3", state.root + "/lib/gws.py", "picker-json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          var list = parsed.rows || []
          var next = ({})
          for (var i = 0; i < list.length; i++) if (list[i].on) next[list[i].id] = true
          state.rows = list
          state.ticked = next
        } catch (e) {
          state.error = "could not read the recorded layout"
        }
        state.loaded = true
        state.loadFinished()
      }
    }
    stderr: StdioCollector {}
    onExited: (code) => {
      if (code !== 0 && !state.loaded) { state.error = "could not read the recorded layout"; state.loaded = true; state.loadFinished() }
    }
  }

  Process {
    id: applyProc
    stderr: StdioCollector { id: applyErr }
    onExited: (code) => {
      state.applying = false
      if (code === 0) state.applied()
      else state.error = (applyErr.text || "").trim() || "relaunch failed"
    }
  }
}
