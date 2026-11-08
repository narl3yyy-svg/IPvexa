import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Change the signed-in user's own password.
AppDialog {
    id: root
    title: "Change password"
    subtitle: "Signed in as " + Api.username
    width: 440
    property string errorText: ""
    property bool saving: false
    property bool done: false

    onOpened: { cur.text = ""; nw.text = ""; again.text = ""; errorText = ""; done = false; cur.forceActiveFocus() }

    function save() {
        errorText = ""
        if (nw.text.length < 8) { errorText = "The new password must be at least 8 characters."; return }
        if (nw.text !== again.text) { errorText = "The new passwords don't match."; return }
        saving = true
        Api.call("POST", "/api/me/password", { current: cur.text, "new": nw.text }, function (err) {
            saving = false
            if (err) errorText = err
            else { done = true; closer.start() }
        })
    }
    Timer { id: closer; interval: 1200; onTriggered: root.close() }

    contentItem: GridLayout {
        columns: 2
        columnSpacing: 12
        rowSpacing: 10
        FieldLabel { text: "Current password" }
        TextField { id: cur; Layout.fillWidth: true; echoMode: TextInput.Password; onAccepted: nw.forceActiveFocus() }
        FieldLabel { text: "New password" }
        TextField { id: nw; Layout.fillWidth: true; echoMode: TextInput.Password; placeholderText: "at least 8 characters"; onAccepted: again.forceActiveFocus() }
        FieldLabel { text: "Repeat new" }
        TextField { id: again; Layout.fillWidth: true; echoMode: TextInput.Password; onAccepted: root.save() }
        Text {
            Layout.columnSpan: 2
            Layout.fillWidth: true
            visible: text !== ""
            text: root.done ? "✓  Password changed. Other devices have been signed out." : root.errorText
            color: root.done ? Theme.online : Theme.live
            wrapMode: Text.Wrap
            font.pixelSize: 12
        }
    }

    footer: Item {
        implicitHeight: 64
        Rectangle { width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 8
            Item { Layout.fillWidth: true }
            AppButton { text: "Cancel"; onClicked: root.close() }
            AppButton { text: root.saving ? "Saving…" : "Change password"; kind: "primary"; enabled: !root.saving && !root.done; onClicked: root.save() }
        }
    }
}
