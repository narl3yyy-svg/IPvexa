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

    // Dark palette for every control, popup and dialog. Set here (not only in C++)
    // because desktop themes such as Plasma override the application palette.
    palette {
        window: Theme.panel
        windowText: Theme.text
        base: "#0f1217"
        alternateBase: Theme.panelAlt
        text: Theme.text
        button: "#232933"
        buttonText: Theme.text
        brightText: "#ffffff"
        highlight: Theme.accent
        highlightedText: "#ffffff"
        placeholderText: Theme.textFaint
        toolTipBase: Theme.raised
        toolTipText: Theme.text
        light: "#3a4250"
        midlight: "#2c333e"
        mid: "#1d222a"
        dark: "#0a0c0f"
        shadow: "#000000"
        link: Theme.accent
        disabled.text: Theme.textFaint
        disabled.buttonText: Theme.textFaint
        disabled.windowText: Theme.textFaint
        disabled.button: "#1a1e25"
    }

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
