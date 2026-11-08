import QtQuick
import QtQuick.Controls

// Compact flat toolbar button with a text glyph, optional label and tooltip.
AbstractButton {
    id: root
    property string glyph: ""
    property string tip: ""
    property bool active: false
    property color tint: Theme.text
    property int size: 30

    implicitHeight: size
    implicitWidth: text.length > 0 ? row.implicitWidth + 16 : size
    hoverEnabled: true
    focusPolicy: Qt.NoFocus

    ToolTip.visible: tip.length > 0 && hovered
    ToolTip.text: tip
    ToolTip.delay: 600

    background: Rectangle {
        radius: Theme.radius
        color: root.active ? Theme.accentSoft
             : root.down ? Theme.raised
             : root.hovered ? Theme.panelAlt : "transparent"
        border.color: root.active ? Theme.accent : "transparent"
        border.width: 1
    }
    contentItem: Row {
        id: row
        spacing: 6
        anchors.centerIn: parent
        Text {
            visible: root.glyph.length > 0
            text: root.glyph
            color: root.enabled ? (root.active ? Theme.accent : root.tint) : Theme.textFaint
            font.pixelSize: root.size * 0.5
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: root.text.length > 0
            text: root.text
            color: root.enabled ? (root.active ? Theme.accent : root.tint) : Theme.textFaint
            font.pixelSize: 12
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
