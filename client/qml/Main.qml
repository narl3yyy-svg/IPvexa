import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Ipvexa

ApplicationWindow {
    id: window
    width: 1600
    height: 950
    minimumWidth: 960
    minimumHeight: 600
    visible: true
    title: Api.loggedIn ? "Ipvexa — " + Api.serverUrl.replace(/^https?:\/\//, "") : "Ipvexa"
    color: Theme.bg

    Component.onCompleted: Api.restoreSession()

    Loader {
        anchors.fill: parent
        sourceComponent: Api.loggedIn ? mainView : loginView
    }
    Component { id: loginView; LoginView {} }
    Component { id: mainView; MainView { window: window } }

    Shortcut {
        sequence: "F11"
        onActivated: window.visibility = window.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
    }

    // Transient error toast.
    Rectangle {
        id: toast
        property string message: ""
        visible: opacity > 0
        opacity: 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 120
        width: Math.min(toastText.implicitWidth + 32, parent.width - 40)
        height: 38
        radius: Theme.radius
        color: "#3a1c20"
        border.color: Theme.live
        Text {
            id: toastText
            anchors.centerIn: parent
            text: toast.message
            color: Theme.text
            font.pixelSize: 13
        }
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Timer { id: toastTimer; interval: 4000; onTriggered: toast.opacity = 0 }
        Connections {
            target: Api
            function onError(message) {
                toast.message = message
                toast.opacity = 1
                toastTimer.restart()
            }
        }
    }
}
