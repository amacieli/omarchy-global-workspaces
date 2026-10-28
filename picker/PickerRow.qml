import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One recorded app: tick box, workspace slot, monitor, app name.
Item {
  id: row

  required property var modelData
  required property int index
  property bool ticked: false
  property bool hasCursor: false
  property int workspaceWidth: 0
  property int monitorWidth: 0

  signal clicked()
  signal hovered()

  readonly property color dim: Qt.darker(Commons.Color.foreground, 1.4)

  implicitHeight: Style.spacing.controlHeight
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.hasCursor ? Util.alpha(Commons.Color.foreground, 0.08) : "transparent"
    Behavior on color { ColorAnimation { duration: 100 } }
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(12)

    Rectangle {
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: Style.space(16); Layout.preferredHeight: Style.space(16)
      radius: Style.space(3)
      color: row.ticked ? Commons.Color.accent : "transparent"
      border.width: Style.normalBorderWidth
      border.color: row.ticked ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, 0.4)
      Text {
        anchors.centerIn: parent
        visible: row.ticked
        text: "\u2713"
        color: Commons.Color.background
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      Layout.preferredWidth: row.workspaceWidth
      text: String(row.modelData.workspace)
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      Layout.preferredWidth: row.monitorWidth
      text: row.modelData.monitor + (row.modelData.connected ? "" : "  (not connected)")
      color: row.modelData.connected ? row.dim : Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      Layout.fillWidth: true
      text: row.modelData.app + (row.modelData.sideEffect ? "   Steam/VM" : "")
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: row.hovered()
    onClicked: row.clicked()
  }
}
