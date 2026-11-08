import QtQuick
import QtQuick.Controls
import Ipvexa

// Standard push button. kind: "primary" (accent), "secondary", "danger" or "ghost".
Button {
    id: root
    property string kind: "secondary"
    property string tip: ""

    implicitHeight: 32
    implicitWidth: Math.max(84, label.implicitWidth + 32)
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    padding: 0

    ToolTip.visible: tip.length > 0 && hovered
    ToolTip.text: tip
    ToolTip.delay: 500

    readonly property color base: kind === "primary" ? Theme.accent
                                 : kind === "danger" ? "#3a1d22"
                                 : kind === "ghost" ? "transparent" : Theme.raised

    background: Rectangle {
        radius: 6
        opacity: root.enabled ? 1 : 0.45
        color: root.down ? Qt.darker(root.base, 1.25)
             : root.hovered ? (root.kind === "ghost" ? Theme.panelAlt : Qt.lighter(root.base, 1.12))
             : root.base
        border.width: root.kind === "primary" ? 0 : 1
        border.color: root.kind === "danger" ? "#6b2d36" : root.visualFocus ? Theme.accent : Theme.borderStrong
        Behavior on color { ColorAnimation { duration: 90 } }
    }
    contentItem: Item {
        Text {
            id: label
            anchors.centerIn: parent
            text: root.text
            color: !root.enabled ? Theme.textFaint
                 : root.kind === "primary" ? "white"
                 : root.kind === "danger" ? "#ff8a95" : Theme.text
            font.pixelSize: 13
            font.weight: Font.DemiBold
        }
    }
}
