import QtQuick
import QtQuick.Controls
import Ipvexa

// Pan/tilt/zoom pad shown on a PTZ camera tile. Press and hold to move, release to stop.
// While held, the move is repeated so the server's safety auto-stop never kicks in.
Item {
    id: root
    property int cameraId: 0
    property real speed: 0.5
    property string error: ""
    property var presets: []
    width: 132
    height: 132 + 34

    property real _pan: 0
    property real _tilt: 0
    property real _zoom: 0
    property bool _moving: false

    function start(pan, tilt, zoom) {
        _pan = pan; _tilt = tilt; _zoom = zoom; _moving = true
        send()
        repeat.restart()
    }
    function send() {
        Api.call("POST", "/api/cameras/" + cameraId + "/ptz/move", { pan: _pan, tilt: _tilt, zoom: _zoom }, function (err) {
            root.error = err ? err : ""
        })
    }
    function stop() {
        if (!_moving) return
        _moving = false
        repeat.stop()
        Api.call("POST", "/api/cameras/" + cameraId + "/ptz/stop", null, function (err) { if (err) root.error = err })
    }
    function loadPresets() {
        Api.call("GET", "/api/cameras/" + cameraId + "/ptz/presets", null, function (err, data) {
            if (err) { root.error = err; return }
            root.presets = data || []
        })
    }
    Timer { id: repeat; interval: 700; repeat: true; onTriggered: root.send() }
    Component.onDestruction: stop()
    onVisibleChanged: if (!visible) stop()

    // ---- D-pad ----
    Rectangle {
        id: pad
        width: 132; height: 132; radius: 66
        color: "#a0101318"
        border.color: "#40ffffff"

        component Arrow: Rectangle {
            id: arrow
            property string glyph
            property real pan
            property real tilt
            width: 34; height: 34; radius: 17
            color: ma.pressed ? Theme.accent : ma.containsMouse ? "#40ffffff" : "transparent"
            Text { anchors.centerIn: parent; text: arrow.glyph; color: "white"; font.pixelSize: 15 }
            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                onPressed: root.start(arrow.pan * root.speed, arrow.tilt * root.speed, 0)
                onReleased: root.stop()
                onCanceled: root.stop()
            }
        }

        Arrow { glyph: "▲"; pan: 0;  tilt: 1;  x: 49; y: 6 }
        Arrow { glyph: "▼"; pan: 0;  tilt: -1; x: 49; y: 92 }
        Arrow { glyph: "◀"; pan: -1; tilt: 0;  x: 6;  y: 49 }
        Arrow { glyph: "▶"; pan: 1;  tilt: 0;  x: 92; y: 49 }
        Arrow { glyph: "◤"; pan: -1; tilt: 1;  x: 19; y: 19; width: 28; height: 28 }
        Arrow { glyph: "◥"; pan: 1;  tilt: 1;  x: 85; y: 19; width: 28; height: 28 }
        Arrow { glyph: "◣"; pan: -1; tilt: -1; x: 19; y: 85; width: 28; height: 28 }
        Arrow { glyph: "◢"; pan: 1;  tilt: -1; x: 85; y: 85; width: 28; height: 28 }
        Rectangle {
            anchors.centerIn: parent
            width: 30; height: 30; radius: 15
            color: "#30ffffff"
            Text { anchors.centerIn: parent; text: "PTZ"; color: "#d0d4da"; font.pixelSize: 8; font.weight: Font.Bold }
        }
    }

    // ---- Zoom + presets ----
    Row {
        anchors.top: pad.bottom
        anchors.topMargin: 4
        anchors.horizontalCenter: pad.horizontalCenter
        spacing: 4
        Repeater {
            model: [{ t: "−", z: -1, tip: "Zoom out" }, { t: "+", z: 1, tip: "Zoom in" }]
            Rectangle {
                width: 30; height: 28; radius: 6
                color: zma.pressed ? Theme.accent : "#a0101318"
                border.color: "#40ffffff"
                Text { anchors.centerIn: parent; text: modelData.t; color: "white"; font.pixelSize: 16 }
                MouseArea {
                    id: zma
                    anchors.fill: parent
                    preventStealing: true
                    onPressed: root.start(0, 0, modelData.z * root.speed)
                    onReleased: root.stop()
                    onCanceled: root.stop()
                }
            }
        }
        Rectangle {
            width: 60; height: 28; radius: 6
            color: pma.containsMouse ? "#40ffffff" : "#a0101318"
            border.color: "#40ffffff"
            Text { anchors.centerIn: parent; text: "Presets ▾"; color: "white"; font.pixelSize: 10 }
            MouseArea {
                id: pma
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { root.loadPresets(); presetMenu.popup() }
            }
        }
    }

    Menu {
        id: presetMenu
        Repeater {
            model: root.presets
            MenuItem {
                text: modelData.name
                onTriggered: Api.call("POST", "/api/cameras/" + root.cameraId + "/ptz/goto", { token: modelData.token },
                                      function (err) { if (err) root.error = err })
            }
        }
        MenuItem { enabled: false; visible: root.presets.length === 0; text: "No presets yet" }
        MenuSeparator {}
        MenuItem { text: "Save current position…"; onTriggered: presetName.open() }
    }

    Dialog {
        id: presetName
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        title: "Save PTZ preset"
        standardButtons: Dialog.Save | Dialog.Cancel
        onOpened: { nameField.text = ""; nameField.forceActiveFocus() }
        onAccepted: if (nameField.text.trim() !== "")
            Api.call("POST", "/api/cameras/" + root.cameraId + "/ptz/presets", { name: nameField.text.trim() },
                     function (err) { if (err) root.error = err })
        TextField { id: nameField; width: 240; placeholderText: "Driveway"; onAccepted: presetName.accept() }
    }

    // Error bubble
    Rectangle {
        visible: root.error !== ""
        anchors.bottom: pad.top
        anchors.bottomMargin: 6
        anchors.right: pad.right
        width: Math.min(260, errText.implicitWidth + 16)
        height: errText.implicitHeight + 10
        radius: 4
        color: "#e03a1c20"
        border.color: Theme.live
        Text {
            id: errText
            anchors.fill: parent
            anchors.margins: 5
            text: root.error
            color: "white"
            font.pixelSize: 10
            wrapMode: Text.Wrap
        }
        MouseArea { anchors.fill: parent; onClicked: root.error = "" }
    }
}
