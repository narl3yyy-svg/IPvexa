import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Dark, rounded dialog frame used for every dialog in the app.
Dialog {
    id: root
    modal: true
    padding: 20
    topPadding: 8

    // Keep dialogs on screen in smaller windows; content scrolls if needed.
    parent: Overlay.overlay
    anchors.centerIn: parent
    height: Math.min(implicitHeight, parent ? parent.height - 40 : implicitHeight)

    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 }
        NumberAnimation { property: "scale"; from: 0.97; to: 1; duration: 120; easing.type: Easing.OutCubic }
    }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 90 } }

    background: Rectangle {
        color: Theme.panel
        radius: 12
        border.color: Theme.borderStrong
        // soft shadow
        Rectangle {
            z: -1
            anchors.fill: parent
            anchors.margins: -1
            radius: 13
            color: "transparent"
            border.color: "#40000000"
            border.width: 6
        }
    }

    header: Item {
        visible: root.title !== ""
        implicitHeight: root.title !== "" ? 52 : 0
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            text: root.title
            color: Theme.text
            font.pixelSize: 16
            font.weight: Font.DemiBold
        }
        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 28; height: 28; radius: 6
            color: closeMa.containsMouse ? Theme.raised : "transparent"
            Text { anchors.centerIn: parent; text: "✕"; color: Theme.textDim; font.pixelSize: 13 }
            MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.reject() }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
    }

    Overlay.modal: Rectangle { color: "#b0050608" }
}
