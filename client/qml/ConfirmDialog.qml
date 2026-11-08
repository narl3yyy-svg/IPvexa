import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Yes/no question. Set title, message, confirmText (and danger for destructive actions),
// then open(); `confirmed` fires on yes.
AppDialog {
    id: root
    property string message: ""
    property string confirmText: "OK"
    property bool danger: false
    signal confirmed()

    width: 420
    footer: Item {
        implicitHeight: 64
        Rectangle { width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 8
            Item { Layout.fillWidth: true }
            AppButton { text: "Cancel"; onClicked: root.reject() }
            AppButton {
                id: yes
                text: root.confirmText
                kind: root.danger ? "danger" : "primary"
                onClicked: { root.accept(); root.confirmed() }
            }
        }
    }
    onOpened: yes.forceActiveFocus()

    contentItem: Text {
        text: root.message
        color: Theme.textDim
        font.pixelSize: 13
        wrapMode: Text.Wrap
        lineHeight: 1.15
    }
}
