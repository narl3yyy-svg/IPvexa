import QtQuick
import QtQuick.Controls
import QtMultimedia
import Ipvexa

// One video tile: live or recorded video, overlay with name/status, drop target.
Rectangle {
    id: root
    property int slotIndex: 0
    property int cameraId: 0
    property bool selected: false
    property Item dragLayer
    readonly property bool dragging: false
    readonly property var cam: Theme.findCamera(Api.cameras, cameraId)
    readonly property bool hasCam: cameraId > 0 && !!cam && !!cam.id
    readonly property var mainStatus: hasCam && cam.status ? cam.status.main : null

    signal clicked()
    signal doubleClicked()
    signal dropped(int cameraId)
    signal closeRequested()

    color: "#050608"
    radius: 3
    clip: true
    border.width: selected ? 2 : 1
    border.color: drop.containsDrag ? Theme.accent : selected ? Theme.accent : Theme.border

    // Use the high-resolution stream only when the tile is big enough to show it.
    readonly property real physicalWidth: width * Screen.devicePixelRatio
    property string streamChoice: "sub"
    onPhysicalWidthChanged: {
        if (physicalWidth > 1100) streamChoice = "main"
        else if (physicalWidth < 900) streamChoice = "sub"
    }

    VideoPlayer {
        id: player
        videoSink: video.videoSink
        cameraId: root.hasCam ? root.cameraId : 0
        stream: root.streamChoice
        live: Clock.live
        active: root.visible && root.hasCam && root.cam.enabled
    }

    VideoOutput {
        id: video
        anchors.fill: parent
        anchors.margins: root.border.width
        fillMode: VideoOutput.PreserveAspectFit
    }

    // ---- Empty slot ----
    Column {
        anchors.centerIn: parent
        visible: !root.hasCam
        spacing: 6
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "＋"; color: Theme.textFaint; font.pixelSize: Math.min(root.height / 5, 40) }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.height > 120
            text: "Drag a camera here"
            color: Theme.textFaint
            font.pixelSize: 12
        }
    }

    // ---- State overlay (connecting / offline / no recording) ----
    Rectangle {
        anchors.fill: parent
        anchors.margins: root.border.width
        visible: root.hasCam && player.state !== "playing"
        color: player.state === "nodata" ? "#c0050608" : "transparent"
        Column {
            anchors.centerIn: parent
            spacing: 6
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                running: visible
                visible: ["connecting", "loading", "reconnecting"].indexOf(player.state) >= 0
                width: 32; height: 32
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    switch (player.state) {
                    case "connecting": return "Connecting…"
                    case "reconnecting": return "Reconnecting…"
                    case "loading": return "Loading recording…"
                    case "offline": return root.mainStatus && root.mainStatus.last_error ? "Camera offline" : "No signal"
                    case "nodata": return "NO RECORDING"
                    case "idle": return root.cam && !root.cam.enabled ? "Disabled" : ""
                    default: return ""
                    }
                }
                color: player.state === "offline" ? Theme.live : Theme.textDim
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.letterSpacing: player.state === "nodata" ? 2 : 0
            }
        }
    }

    // ---- Top overlay: name + status ----
    Rectangle {
        id: header
        visible: root.hasCam
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.border.width }
        height: 26
        gradient: Gradient {
            GradientStop { position: 0; color: "#cc000000" }
            GradientStop { position: 1; color: "#00000000" }
        }
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7; height: 7; radius: 3.5
                color: Theme.stateColor(root.mainStatus ? root.mainStatus.state : "offline")
            }
            Text {
                text: root.cam ? root.cam.name : ""
                color: "white"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                style: Text.Raised; styleColor: "#000000"
            }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Text {
                visible: hover.hovered && root.width > 300
                anchors.verticalCenter: parent.verticalCenter
                text: player.info
                color: "#d0d4da"
                font.pixelSize: 10
                font.family: Theme.mono
            }
            Rectangle {
                visible: root.mainStatus && root.mainStatus.recording
                anchors.verticalCenter: parent.verticalCenter
                width: recText.implicitWidth + 10; height: 16; radius: 3
                color: "#99000000"
                border.color: "#80ff4757"
                Text { id: recText; anchors.centerIn: parent; text: "● REC"; color: Theme.live; font.pixelSize: 9; font.weight: Font.Bold }
            }
            Text {
                visible: hover.hovered
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                color: closeMa.containsMouse ? "white" : "#b0b6bf"
                font.pixelSize: 13
                MouseArea { id: closeMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; onClicked: root.closeRequested() }
            }
        }
    }

    // ---- Bottom overlay: time ----
    Rectangle {
        visible: root.hasCam && player.state === "playing" && root.height > 90
        anchors { left: parent.left; bottom: parent.bottom; margins: 6 + root.border.width }
        width: timeText.implicitWidth + 12
        height: 18
        radius: 3
        color: Clock.live ? "#cc000000" : "#cc0f2a4d"
        Text {
            id: timeText
            anchors.centerIn: parent
            text: Clock.live ? "● LIVE" : new Date(player.frameTime).toLocaleString(Qt.locale(), "yyyy-MM-dd  HH:mm:ss")
            color: Clock.live ? Theme.live : "#cfe3ff"
            font.pixelSize: 10
            font.family: Theme.mono
            font.weight: Font.Bold
        }
    }

    HoverHandler { id: hover }
    MouseArea {
        anchors.fill: parent
        z: -1
        onClicked: root.clicked()
        onDoubleClicked: root.doubleClicked()
    }

    DropArea {
        id: drop
        anchors.fill: parent
        keys: ["camera"]
        onDropped: (ev) => { if (ev.source && ev.source.cameraId > 0) root.dropped(ev.source.cameraId) }
    }
}
