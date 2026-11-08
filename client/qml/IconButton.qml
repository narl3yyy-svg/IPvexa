import QtQuick
import QtQuick.Controls
import Ipvexa

// Flat toolbar button: a vector icon, a text label, or both, always centred.
AbstractButton {
    id: root
    property string iconKind: ""    // TileIcon kind
    property string tip: ""
    property bool active: false
    property color tint: Theme.textDim
    property int size: 28
    property int iconSize: 14

    implicitHeight: size
    implicitWidth: text.length > 0 ? row.implicitWidth + 18 : size
    hoverEnabled: true
    focusPolicy: Qt.NoFocus
    padding: 0

    ToolTip.visible: tip.length > 0 && hovered
    ToolTip.text: tip
    ToolTip.delay: 600

    readonly property color fg: !enabled ? Theme.textFaint : active ? Theme.accent : hovered ? Theme.text : tint

    background: Rectangle {
        radius: 5
        color: root.down ? Theme.raised : root.active ? Theme.accentSoft : root.hovered ? Theme.panelAlt : "transparent"
        Behavior on color { ColorAnimation { duration: 90 } }
    }
    contentItem: Item {
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 6
            TileIcon {
                visible: root.iconKind !== ""
                anchors.verticalCenter: parent.verticalCenter
                kind: root.iconKind
                width: root.iconSize; height: root.iconSize
                color: root.fg
            }
            Text {
                visible: root.text.length > 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.text
                color: root.fg
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }
        }
    }
}
