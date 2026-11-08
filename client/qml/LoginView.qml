import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

Rectangle {
    color: Theme.bg

    // Subtle backdrop
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#101521" }
            GradientStop { position: 1.0; color: Theme.bg }
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: 380
        height: col.implicitHeight + 56
        radius: 12
        color: Theme.panel
        border.color: Theme.border

        ColumnLayout {
            id: col
            anchors.fill: parent
            anchors.margins: 28
            spacing: 12

            RowLayout {
                spacing: 10
                Rectangle {
                    width: 36; height: 36; radius: 9
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#3b9bff" }
                        GradientStop { position: 1; color: "#1f5fd1" }
                    }
                    Text { anchors.centerIn: parent; text: "◉"; color: "white"; font.pixelSize: 20 }
                }
                ColumnLayout {
                    spacing: 0
                    Text { text: "Ipvexa"; color: Theme.text; font.pixelSize: 22; font.weight: Font.Bold }
                    Text { text: "Video Management System"; color: Theme.textDim; font.pixelSize: 12 }
                }
            }
            Item { height: 8 }

            Label { text: "Server"; color: Theme.textDim; font.pixelSize: 12 }
            TextField { id: server; Layout.fillWidth: true; text: Api.savedServer; placeholderText: "http://192.168.1.10:7480" }
            Label { text: "Username"; color: Theme.textDim; font.pixelSize: 12 }
            TextField { id: user; Layout.fillWidth: true; text: Api.savedUser }
            Label { text: "Password"; color: Theme.textDim; font.pixelSize: 12 }
            TextField {
                id: pass
                Layout.fillWidth: true
                echoMode: TextInput.Password
                focus: true
                onAccepted: loginBtn.clicked()
            }
            CheckBox { id: remember; text: "Stay signed in"; checked: true }

            Text {
                id: err
                Layout.fillWidth: true
                visible: text.length > 0
                color: Theme.live
                wrapMode: Text.Wrap
                font.pixelSize: 12
            }

            Button {
                id: loginBtn
                Layout.fillWidth: true
                Layout.preferredHeight: 38
                enabled: !Api.busy && pass.text.length > 0
                text: Api.busy ? "Connecting…" : "Sign in"
                highlighted: true
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
        text: "Ipvexa " + Qt.application.version + " · offline · self-hosted"
        color: Theme.textFaint
        font.pixelSize: 11
    }
}
