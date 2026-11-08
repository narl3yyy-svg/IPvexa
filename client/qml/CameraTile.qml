import QtQuick
import QtQuick.Controls
import QtMultimedia
import Ipvexa

// One camera on the scene. Drag it to move (drop on another tile to swap), drag the
// corner handle to resize, double-click to maximize. Toolbar appears on hover.
Rectangle {
    id: root
    property int itemIndex: -1
    property int cameraId: 0
    property bool selected: false
    property bool maximized: false
    property Item dragLayer
    property bool dragging: dragMa.drag.active
    readonly property var cam: Theme.findCamera(Api.cameras, cameraId)
    readonly property bool hasCam: cameraId > 0 && !!cam && !!cam.id
    readonly property var mainStatus: hasCam && cam.status ? cam.status.main : null
    property bool ptzMode: false
    property bool showInfo: false

    signal clicked()
    signal maximizeToggled()
    signal fullscreenRequested()
    signal closeRequested()
    signal settingsRequested()
    signal cameraDropped(int cameraId)
    signal tileDropped(int fromIndex)
    signal resizeMoved(point scenePos)
    signal resizeFinished(point scenePos)

    function offlineReason() {
        var e = root.mainStatus && root.mainStatus.last_error ? root.mainStatus.last_error : ""
        if (e.indexOf("401") >= 0 || e.toLowerCase().indexOf("unauthorized") >= 0)
            return "Wrong camera login (RTSP username/password)"
        if (e.indexOf("404") >= 0) return "Stream path not found — check the stream URL"
        if (e.toLowerCase().indexOf("refused") >= 0) return "Camera refused the connection (RTSP port closed?)"
        if (e.toLowerCase().indexOf("timed out") >= 0 || e.toLowerCase().indexOf("timeout") >= 0
                || e.toLowerCase().indexOf("no route") >= 0) return "Camera unreachable on the network"
        return e !== "" ? "Camera offline" : "No signal"
    }

    color: "#000000"
    clip: true
    border.width: selected ? 2 : 1
    border.color: drop.containsDrag ? Theme.accent : selected ? Theme.accent : "#262f35"
    opacity: dragging ? 0.45 : 1

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
        visible: root.hasCam
        anchors.fill: parent
        anchors.margins: root.border.width
        fillMode: VideoOutput.PreserveAspectFit
    }

    // ---- State overlay (connecting / offline / no recording) ----
    Item {
        anchors.fill: parent
        visible: root.hasCam && player.state !== "playing"
        Rectangle { anchors.fill: parent; color: "#c0000000"; visible: player.state === "nodata" }
        Column {
            anchors.centerIn: parent
            spacing: 8
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                running: visible
                visible: ["connecting", "loading", "reconnecting"].indexOf(player.state) >= 0
                         && !(root.mainStatus && root.mainStatus.state === "offline")
                width: 30; height: 30
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    if (root.mainStatus && root.mainStatus.state === "offline" && player.state !== "nodata" && player.state !== "loading")
                        return root.offlineReason()
                    switch (player.state) {
                    case "connecting": return "Connecting…"
                    case "reconnecting": return "Reconnecting…"
                    case "loading": return "Loading recording…"
                    case "offline": return root.offlineReason()
                    case "nodata": return "NO DATA"
                    case "idle": return root.cam && !root.cam.enabled ? "Disabled" : ""
                    default: return ""
                    }
                }
                color: player.state === "offline" || (root.mainStatus && root.mainStatus.state === "offline") ? Theme.live : Theme.textDim
                font.pixelSize: player.state === "nodata" ? 16 : 13
                font.weight: Font.DemiBold
                font.letterSpacing: player.state === "nodata" ? 3 : 0
            }
        }
    }

    // ---- Top bar: name (always) + toolbar (hover/selected) ----
    Rectangle {
        id: header
        visible: root.hasCam
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.border.width }
        height: 30
        gradient: Gradient {
            GradientStop { position: 0; color: "#d0000000" }
            GradientStop { position: 1; color: "#00000000" }
        }
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -2
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
                style: Text.Outline; styleColor: "#80000000"
            }
            Rectangle {
                visible: root.mainStatus && root.mainStatus.recording
                anchors.verticalCenter: parent.verticalCenter
                width: 8; height: 8; radius: 4
                color: Theme.live
                SequentialAnimation on opacity {
                    running: parent.visible; loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 900 }
                    NumberAnimation { to: 1; duration: 900 }
                }
            }
        }
        Row {
            id: toolbar
            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -2
            spacing: 3
            visible: hover.hovered || root.selected
            TileButton { visible: !!(root.cam && root.cam.ptz); icon: "ptz"; tip: "PTZ controls"; active: root.ptzMode; onClicked: root.ptzMode = !root.ptzMode }
            TileButton { icon: "info"; tip: "Stream information"; active: root.showInfo; onClicked: root.showInfo = !root.showInfo }
            TileButton { icon: root.maximized ? "restore" : "maximize"; tip: root.maximized ? "Restore (double-click)" : "Maximize (double-click)"; onClicked: root.maximizeToggled() }
            TileButton { icon: "fullscreen"; tip: "Full screen"; onClicked: root.fullscreenRequested() }
            TileButton { visible: Api.role === "admin"; icon: "settings"; tip: "Camera settings"; onClicked: root.settingsRequested() }
            TileButton { icon: "close"; tip: "Remove from layout (Delete)"; hoverColor: "#c0ff4757"; onClicked: root.closeRequested() }
        }
    }

    // ---- Stream info panel ----
    Rectangle {
        visible: root.showInfo && root.hasCam
        anchors { left: parent.left; top: header.bottom; margins: 8 }
        width: infoCol.implicitWidth + 16
        height: infoCol.implicitHeight + 12
        radius: 4
        color: "#c0101417"
        border.color: "#30ffffff"
        Column {
            id: infoCol
            anchors.centerIn: parent
            spacing: 2
            Repeater {
                model: [
                    player.info,
                    root.mainStatus ? "Camera: " + (root.mainStatus.width || "?") + "×" + (root.mainStatus.height || "?") + " " + (root.mainStatus.codec || "").toUpperCase() : "",
                    root.mainStatus ? "Bitrate: " + ((root.mainStatus.bitrate_bps || 0) / 1e6).toFixed(2) + " Mb/s" : "",
                    "Stream: " + (root.streamChoice === "main" ? "high (main)" : "low (sub)"),
                    root.mainStatus && root.mainStatus.recording ? "Recording" : "Not recording"
                ]
                Text { visible: modelData !== ""; text: modelData; color: "#d6dbe0"; font.pixelSize: 10; font.family: Theme.mono }
            }
        }
    }

    // ---- Bottom-left: time ----
    Rectangle {
        visible: root.hasCam && player.state === "playing" && root.height > 90
        anchors { left: parent.left; bottom: parent.bottom; margins: 6 + root.border.width }
        width: timeText.implicitWidth + 12
        height: 18
        radius: 3
        color: Clock.live ? "#b0000000" : "#c00f2a4d"
        Text {
            id: timeText
            anchors.centerIn: parent
            text: Clock.live ? "LIVE" : new Date(player.frameTime).toLocaleString(Qt.locale(), "yyyy-MM-dd  HH:mm:ss")
            color: Clock.live ? "#ff6b77" : "#cfe3ff"
            font.pixelSize: 10
            font.family: Theme.mono
            font.weight: Font.Bold
        }
    }

    // PTZ pad (toggle with the PTZ toolbar button).
    PtzControls {
        visible: root.ptzMode && root.hasCam && !!root.cam.ptz && Clock.live && root.height > 200 && root.width > 220
        cameraId: root.cameraId
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 10
        z: 5
    }

    // ---- Resize handle (bottom-right) ----
    Item {
        id: grip
        visible: (hover.hovered || root.selected) && !root.maximized && root.hasCam
        width: 18; height: 18
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        z: 6
        Canvas {
            anchors.fill: parent
            onPaint: {
                var c = getContext("2d"); c.reset()
                c.strokeStyle = "#d0ffffff"; c.lineWidth = 1.5
                c.beginPath()
                c.moveTo(width - 3, height - 12); c.lineTo(width - 12, height - 3)
                c.moveTo(width - 3, height - 7); c.lineTo(width - 7, height - 3)
                c.stroke()
            }
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.SizeFDiagCursor
            preventStealing: true
            onPositionChanged: (m) => { if (pressed) root.resizeMoved(mapToItem(null, m.x, m.y)) }
            onReleased: (m) => root.resizeFinished(mapToItem(null, m.x, m.y))
        }
    }

    HoverHandler { id: hover }

    // Click / double-click / right-click / drag-to-move.
    MouseArea {
        id: dragMa
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        drag.target: root.maximized ? null : ghost
        drag.threshold: 14
        onPressed: (mouse) => { if (mouse.button === Qt.LeftButton) root.clicked() }
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) { root.clicked(); tileMenu.popup() }
        }
        onDoubleClicked: (mouse) => { if (mouse.button === Qt.LeftButton) root.maximizeToggled() }
        onReleased: if (drag.active) ghost.Drag.drop()
    }

    // Floating copy shown while dragging the tile.
    Rectangle {
        id: ghost
        property int itemIndex: root.itemIndex
        property int cameraId: root.cameraId
        width: Math.min(root.width, 220); height: Math.min(root.height, 124)
        radius: 4
        color: "#cc1a2024"
        border.color: Theme.accent
        border.width: 2
        visible: dragMa.drag.active
        Drag.active: dragMa.drag.active
        Drag.keys: ["tile"]
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2
        Column {
            anchors.centerIn: parent
            spacing: 4
            TileIcon { anchors.horizontalCenter: parent.horizontalCenter; kind: "camera"; width: 22; height: 22; color: Theme.accent }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.cam ? root.cam.name : ""; color: "white"; font.pixelSize: 12 }
        }
        states: State {
            when: dragMa.drag.active
            ParentChange { target: ghost; parent: root.dragLayer }
        }
        onVisibleChanged: if (!visible) { x = 0; y = 0 }
    }

    Menu {
        id: tileMenu
        MenuItem { text: root.maximized ? "Restore" : "Maximize"; onTriggered: root.maximizeToggled() }
        MenuItem { text: "Full screen"; onTriggered: root.fullscreenRequested() }
        MenuItem { visible: !!(root.cam && root.cam.ptz); height: visible ? implicitHeight : 0; text: root.ptzMode ? "Hide PTZ controls" : "PTZ controls"; onTriggered: root.ptzMode = !root.ptzMode }
        MenuItem { text: root.showInfo ? "Hide stream information" : "Stream information"; onTriggered: root.showInfo = !root.showInfo }
        MenuSeparator {}
        MenuItem { text: "Camera settings…"; enabled: Api.role === "admin"; onTriggered: root.settingsRequested() }
        MenuSeparator {}
        MenuItem { text: "Remove from layout"; onTriggered: root.closeRequested() }
    }

    DropArea {
        id: drop
        anchors.fill: parent
        keys: ["camera", "tile"]
        onDropped: (ev) => {
            if (!ev.source) return
            if (ev.keys.indexOf("tile") >= 0 && ev.source.itemIndex !== undefined) {
                if (ev.source.itemIndex !== root.itemIndex) root.tileDropped(ev.source.itemIndex)
            } else if (ev.source.cameraId > 0) {
                root.cameraDropped(ev.source.cameraId)
            }
        }
    }
}
