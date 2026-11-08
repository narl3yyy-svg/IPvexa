import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Dark, rounded dialog frame used for every dialog in the app. Standard buttons are
// drawn as AppButtons, right-aligned in a footer that lines up with the content.
Dialog {
    id: root
    modal: true
    padding: 20
    topPadding: 16
    bottomPadding: 16
    property string subtitle: ""

    // Keep dialogs on screen in smaller windows.
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
        radius: 10
        border.color: Theme.borderStrong
        Rectangle {
            z: -1
            anchors.fill: parent
            anchors.margins: -6
            radius: 16
            color: "#38000000"
        }
    }

    header: Item {
        visible: root.title !== ""
        implicitHeight: root.title !== "" ? (root.subtitle !== "" ? 64 : 52) : 0
        Column {
            anchors.left: parent.left
            anchors.leftMargin: 20
            anchors.right: closeBtn.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
                text: root.title
                color: Theme.text
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }
            Text {
                visible: root.subtitle !== ""
                text: root.subtitle
                color: Theme.textDim
                font.pixelSize: 12
                elide: Text.ElideRight
                width: parent.width
            }
        }
        IconButton {
            id: closeBtn
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            iconKind: "close"
            iconSize: 11
            size: 28
            onClicked: root.reject()
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
    }

    footer: DialogButtonBox {
        visible: count > 0
        alignment: Qt.AlignRight
        spacing: 8
        leftPadding: 20; rightPadding: 20; topPadding: 14; bottomPadding: 16
        background: Rectangle {
            color: "transparent"
            Rectangle { width: parent.width; height: 1; color: Theme.border }
        }
        delegate: AppButton {
            kind: DialogButtonBox.buttonRole === DialogButtonBox.AcceptRole
                  || DialogButtonBox.buttonRole === DialogButtonBox.YesRole ? "primary" : "secondary"
        }
    }

    Overlay.modal: Rectangle { color: "#b0050608" }
}
