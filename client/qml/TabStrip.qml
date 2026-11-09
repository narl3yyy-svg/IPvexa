import QtQuick
import QtQuick.Controls
import Ipvexa

// Underlined text tabs (dialogs and panels).
Item {
    id: root
    property var tabs: []           // list of labels
    property int current: 0
    // Clicking a tab only reports it; the owner sets current, so a binding to it
    // keeps working (e.g. a dialog going back to its first tab when reopened).
    signal selected(int index)
    implicitHeight: 38
    implicitWidth: row.implicitWidth

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
    Row {
        id: row
        height: parent.height
        spacing: 22
        Repeater {
            model: root.tabs
            Item {
                required property string modelData
                required property int index
                width: t.implicitWidth
                height: row.height
                Text {
                    id: t
                    anchors.centerIn: parent
                    text: modelData
                    color: index === root.current ? Theme.text : ma.containsMouse ? Theme.text : Theme.textDim
                    font.pixelSize: 13
                    font.weight: index === root.current ? Font.DemiBold : Font.Normal
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 2
                    radius: 1
                    color: Theme.accent
                    visible: index === root.current
                }
                MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selected(index) }
            }
        }
    }
}
