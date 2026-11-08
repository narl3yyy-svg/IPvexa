import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

Rectangle {
    color: Theme.bg

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#121a1f" }
            GradientStop { position: 1.0; color: Theme.bg }
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: 400
        height: col.implicitHeight + 64
        radius: 12
        color: Theme.panel
        border.color: Theme.border

        ColumnLayout {
            id: col
            anchors.fill: parent
            anchors.margins: 32
            spacing: 0

            RowLayout {
                spacing: 12
                Logo { size: 40 }
                ColumnLayout {
                    spacing: 1
                    Text { text: "IPvexa"; color: Theme.text; font.pixelSize: 24; font.weight: Font.Bold; font.letterSpacing: 0.3 }
                    Text { text: "Video Management System"; color: Theme.textDim; font.pixelSize: 12 }
                }
            }

            Text { Layout.topMargin: 26; text: "Server"; color: Theme.textDim; font.pixelSize: 12 }
            TextField { id: server; Layout.topMargin: 6; Layout.fillWidth: true; text: Api.savedServer; placeholderText: "192.168.1.10:7480" }
            Text { Layout.topMargin: 14; text: "Username"; color: Theme.textDim; font.pixelSize: 12 }
            TextField { id: user; Layout.topMargin: 6; Layout.fillWidth: true; text: Api.savedUser; onAccepted: pass.forceActiveFocus() }
            RowLayout {
                Layout.topMargin: 14
                Layout.fillWidth: true
                Text { text: "Password"; color: Theme.textDim; font.pixelSize: 12 }
                Item { Layout.fillWidth: true }
                Text {
                    text: "Forgot password?"
                    color: forgotMa.containsMouse ? Theme.text : Theme.accent
                    font.pixelSize: 12
                    MouseArea { id: forgotMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: forgot.visible = !forgot.visible }
                }
            }
            TextField {
                id: pass
                Layout.topMargin: 6
                Layout.fillWidth: true
                echoMode: TextInput.Password
                focus: true
                onAccepted: if (loginBtn.enabled) loginBtn.clicked()
            }

            Rectangle {
                id: forgot
                visible: false
                Layout.topMargin: 12
                Layout.fillWidth: true
                implicitHeight: forgotText.implicitHeight + 20
                radius: 6
                color: "#132630"
                border.color: "#1f4558"
                Text {
                    id: forgotText
                    anchors.fill: parent
                    anchors.margins: 10
                    wrapMode: Text.Wrap
                    textFormat: Text.StyledText
                    color: Theme.textDim
                    font.pixelSize: 12
                    lineHeight: 1.15
                    text: "Passwords can't be recovered, but they can be reset:<br>"
                        + "• An administrator can set a new one in <b>User management</b>.<br>"
                        + "• On the server computer, run:<br>"
                        + "<font face='monospace' color='#e3e8eb'>&nbsp;&nbsp;ipvexa-server passwd " + (user.text.trim() || "admin") + "</font>"
                }
            }

            CheckBox { id: remember; Layout.topMargin: 10; text: "Stay signed in"; checked: true }

            Text {
                id: err
                Layout.topMargin: 6
                Layout.fillWidth: true
                visible: text.length > 0
                color: Theme.live
                wrapMode: Text.Wrap
                font.pixelSize: 12
            }

            AppButton {
                id: loginBtn
                Layout.topMargin: 14
                Layout.fillWidth: true
                implicitHeight: 38
                kind: "primary"
                enabled: !Api.busy && pass.text.length > 0 && user.text.trim().length > 0
                text: Api.busy ? "Connecting…" : "Sign in"
                onClicked: {
                    err.text = ""
                    Api.login(server.text, user.text, pass.text, remember.checked, function (e) {
                        if (e) err.text = e
                    })
                }
            }
        }
    }

    Text {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 14
        text: "IPvexa " + Qt.application.version + "  ·  offline  ·  self-hosted"
        color: Theme.textFaint
        font.pixelSize: 11
    }
}
