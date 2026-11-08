import QtQuick
import QtQuick.Controls
import Ipvexa

// Segmented switch: options is a list of { value, label, tip }.
Rectangle {
    id: root
    property var options: []
    property string value: ""
    property int segHeight: 24
    signal picked(string value)

    implicitHeight: segHeight
    implicitWidth: row.implicitWidth + 4
    radius: 5
    color: "#0e1215"
    border.color: Theme.border

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 0
        Repeater {
            model: root.options
            Rectangle {
                required property var modelData
                readonly property bool on: modelData.value === root.value
                width: segText.implicitWidth + 18
                height: root.segHeight - 4
                radius: 4
                color: on ? Theme.accentSoft : segMa.containsMouse ? Theme.panelAlt : "transparent"
                border.color: on ? "#2a6f93" : "transparent"
                Text {
                    id: segText
                    anchors.centerIn: parent
                    text: modelData.label
                    color: parent.on ? Theme.accent : segMa.containsMouse ? Theme.text : Theme.textDim
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }
                MouseArea {
                    id: segMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(modelData.value)
                    ToolTip.visible: containsMouse && !!modelData.tip
                    ToolTip.text: modelData.tip || ""
                    ToolTip.delay: 600
                }
            }
        }
    }
}
