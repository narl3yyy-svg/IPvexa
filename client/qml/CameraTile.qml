import QtQuick
import QtQuick.Controls
import QtMultimedia
import Ipvexa
import "Cells.js" as Cells

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
    property string sceneQuality: "auto"      // layout-wide: auto | high | low
    property string qualityOverride: ""       // this tile: "" (follow layout) | high | low
    readonly property string quality: qualityOverride !== "" ? qualityOverride : sceneQuality
    readonly property bool hasSub: hasCam && !!cam.sub_url
    readonly property bool motionNow: hasCam && !!cam.status && !!cam.status.motion

    // Digital zoom: 1 = whole picture. (zx, zy) is the centre of the view, as a
    // fraction of the picture.
    property real zoom: 1
    property real zx: 0.5
    property real zy: 0.5
    function resetZoom() { zoom = 1; zx = 0.5; zy = 0.5 }
    // Saved zoom from the layout ({ zoom, x, y } or undefined); user changes are
    // reported through zoomCommitted after a short pause.
    property var zoomState
    readonly property real fps: player.fps
    function applyZoomState() {
        if (zoomState && zoomState.zoom > 1) { zoom = zoomState.zoom; zx = zoomState.x; zy = zoomState.y; clampCentre() }
        else resetZoom()
    }
    onZoomStateChanged: applyZoomState()
    Component.onCompleted: applyZoomState()
    function userZoomChanged() { zoomCommit.restart() }
    Timer { id: zoomCommit; interval: 700; onTriggered: root.zoomCommitted(root.zoom > 1.01 ? { zoom: root.zoom, x: root.zx, y: root.zy } : null) }
    function clampCentre() {
        var h = 0.5 / zoom
        zx = Math.min(1 - h, Math.max(h, zx))
        zy = Math.min(1 - h, Math.max(h, zy))
    }
    onCameraIdChanged: applyZoomState()

    // Smart search: drag a box on the picture to look for motion only there.
    property bool selectingArea: false
    property bool editable: true      // false: no moving, resizing or removing (video walls)
    property string searchCells: ""   // area being searched on this tile (hex), shown as an outline

    signal clicked()
    signal maximizeToggled()
    signal fullscreenRequested()
    signal closeRequested()
    signal settingsRequested()
    signal qualityPicked(string q)
    signal areaChosen(string cells)
    signal zoomCommitted(var z)
    signal zoomTileRequested()
    signal areaSearchRequested()
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

    // Auto quality uses the high-resolution stream only when the tile is big enough to
    // show it (with some hysteresis so it doesn't flip back and forth).
    readonly property real physicalWidth: width * Screen.devicePixelRatio
    property string autoChoice: "sub"
    onPhysicalWidthChanged: {
        if (physicalWidth > 1100) autoChoice = "main"
        else if (physicalWidth < 900) autoChoice = "sub"
    }
    readonly property string streamChoice: !hasSub ? "main" : quality === "high" ? "main" : quality === "low" ? "sub" : autoChoice
    function nextQuality() {
        // Cycle: follow layout -> high -> low -> follow layout
        return qualityOverride === "" ? "high" : qualityOverride === "high" ? "low" : ""
    }

    VideoPlayer {
        id: player
        videoSink: video.videoSink
        cameraId: root.hasCam ? root.cameraId : 0
        stream: root.streamChoice
        live: Clock.live
        active: root.visible && root.hasCam && root.cam.enabled
    }

    Item {
        id: viewport
        anchors.fill: parent
        anchors.margins: root.border.width
        clip: true
        VideoOutput {
            id: video
            visible: root.hasCam
            width: viewport.width * root.zoom
            height: viewport.height * root.zoom
            x: viewport.width / 2 - root.zx * width
            y: viewport.height / 2 - root.zy * height
            fillMode: VideoOutput.PreserveAspectFit
        }
        // Smart search area (cells) drawn over the picture.
        Repeater {
            model: root.searchCells !== "" ? Cells.decode(root.searchCells) : []
            Rectangle {
                required property bool modelData
                required property int index
                visible: modelData
                readonly property rect cr: video.contentRect
                x: video.x + cr.x + (index % Cells.COLS) * cr.width / Cells.COLS
                y: video.y + cr.y + Math.floor(index / Cells.COLS) * cr.height / Cells.ROWS
                width: cr.width / Cells.COLS
                height: cr.height / Cells.ROWS
                color: "#30ff7a45"
                border.color: "#80ff7a45"
                border.width: 0.5
            }
        }
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
            TileIcon {
                visible: root.motionNow && Clock.live
                anchors.verticalCenter: parent.verticalCenter
                kind: "motion"; width: 13; height: 13
                color: "#ff6b6b"
            }
            Rectangle {
                visible: root.width > 260
                anchors.verticalCenter: parent.verticalCenter
                width: qBadge.implicitWidth + 8; height: 14; radius: 3
                color: root.streamChoice === "main" ? "#3a2fa8e0" : "#30ffffff"
                border.color: root.streamChoice === "main" ? "#802fa8e0" : "#40ffffff"
                Text {
                    id: qBadge
                    anchors.centerIn: parent
                    text: root.streamChoice === "main" ? "HD" : "SD"
                    color: root.streamChoice === "main" ? "#9fdcff" : "#d0d6da"
                    font.pixelSize: 9
                    font.weight: Font.Bold
                }
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
            TileButton {
                visible: root.hasSub
                label: root.qualityOverride === "high" ? "HD" : root.qualityOverride === "low" ? "SD" : "AUTO"
                active: root.qualityOverride !== ""
                tip: "Quality for this tile: " + (root.qualityOverride === "" ? "same as layout (" + root.sceneQuality + ")" : root.qualityOverride)
                     + ". Click to change."
                onClicked: root.qualityPicked(root.nextQuality())
            }
            TileButton { visible: !!(root.cam && root.cam.ptz) && Api.canPtz; icon: "ptz"; tip: "PTZ controls"; active: root.ptzMode; onClicked: root.ptzMode = !root.ptzMode }
            TileButton {
                visible: root.zoom > 1.01
                label: root.zoom.toFixed(1) + "×"
                active: true
                tip: "Digital zoom. Click to reset (or scroll back out)."
                onClicked: { root.resetZoom(); root.userZoomChanged() }
            }
            TileButton {
                visible: Api.canPlayback
                icon: "search"
                active: root.selectingArea || root.searchCells !== ""
                tip: root.searchCells !== "" ? "Clear smart search" : "Smart search: drag a box to find motion in that area"
                onClicked: {
                    if (root.searchCells !== "") root.areaChosen("")
                    else root.selectingArea = !root.selectingArea
                }
            }
            TileButton { icon: "info"; tip: "Stream information"; active: root.showInfo; onClicked: root.showInfo = !root.showInfo }
            TileButton { icon: root.maximized ? "restore" : "maximize"; tip: root.maximized ? "Restore (double-click)" : "Maximize (double-click)"; onClicked: root.maximizeToggled() }
            TileButton { icon: "fullscreen"; tip: "Full screen"; onClicked: root.fullscreenRequested() }
            TileButton { visible: Api.isAdmin && root.editable; icon: "settings"; tip: "Camera settings"; onClicked: root.settingsRequested() }
            TileButton { visible: root.editable; icon: "close"; tip: "Remove from layout (Delete)"; hoverColor: "#c0ff4757"; onClicked: root.closeRequested() }
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
                    "Stream: " + (root.streamChoice === "main" ? "high quality" : "low quality") + " (" + (root.qualityOverride || root.sceneQuality) + ")",
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
        visible: root.ptzMode && root.hasCam && !!root.cam.ptz && Api.canPtz && Clock.live && root.height > 200 && root.width > 220
        cameraId: root.cameraId
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 10
        z: 5
    }

    // ---- Resize handle (bottom-right) ----
    Item {
        id: grip
        visible: (hover.hovered || root.selected) && !root.maximized && root.hasCam && root.editable
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
        drag.target: root.maximized || root.zoom > 1.01 || !root.editable ? null : ghost
        property point panFrom
        property real panZx
        property real panZy
        drag.threshold: 14
        onPressed: (mouse) => {
            if (mouse.button !== Qt.LeftButton) return
            root.clicked()
            panFrom = Qt.point(mouse.x, mouse.y); panZx = root.zx; panZy = root.zy
        }
        onPositionChanged: (mouse) => {
            if (pressed && root.zoom > 1.01) {
                root.zx = panZx - (mouse.x - panFrom.x) / video.width
                root.zy = panZy - (mouse.y - panFrom.y) / video.height
                root.clampCentre()
                root.userZoomChanged()
            }
        }
        onWheel: (wheel) => {
            if (!root.hasCam) return
            // Zoom around the point under the mouse.
            var fx = (wheel.x - root.border.width - video.x) / video.width
            var fy = (wheel.y - root.border.width - video.y) / video.height
            var old = root.zoom
            var z = Math.max(1, Math.min(8, old * Math.pow(1.2, wheel.angleDelta.y / 120)))
            if (z === old) return
            root.zoom = z
            var vx = (wheel.x - root.border.width) / viewport.width, vy = (wheel.y - root.border.width) / viewport.height
            root.zx = fx - (vx - 0.5) / z
            root.zy = fy - (vy - 0.5) / z
            if (z <= 1.001) root.resetZoom(); else root.clampCentre()
            root.userZoomChanged()
        }
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

    // Smart search: drag a rectangle on the picture.
    MouseArea {
        id: areaMa
        visible: root.selectingArea
        anchors.fill: parent
        z: 20
        cursorShape: Qt.CrossCursor
        hoverEnabled: true
        property point a
        property point b
        property bool dragging: false
        // Fraction of the whole picture under a point. The (possibly zoomed) video
        // item spans the whole picture, so this also works while digitally zoomed.
        function frac(p) {
            var cr = video.contentRect
            return Qt.point((p.x - root.border.width - video.x - cr.x) / cr.width,
                            (p.y - root.border.width - video.y - cr.y) / cr.height)
        }
        onPressed: (m) => { a = Qt.point(m.x, m.y); b = a; dragging = true }
        onPositionChanged: (m) => { if (dragging) b = Qt.point(m.x, m.y) }
        onReleased: {
            dragging = false
            root.selectingArea = false
            if (Math.abs(b.x - a.x) < 6 || Math.abs(b.y - a.y) < 6) return
            var fa = frac(a), fb = frac(b)
            var cells = Cells.fromRect(Math.max(0, Math.min(1, fa.x)), Math.max(0, Math.min(1, fa.y)),
                                       Math.max(0, Math.min(1, fb.x)), Math.max(0, Math.min(1, fb.y)))
            if (Cells.count(cells) > 0) root.areaChosen(Cells.encode(cells))
        }
        Rectangle {
            anchors.fill: parent
            color: "#40000000"
            Text {
                anchors.centerIn: parent
                visible: !areaMa.dragging
                text: "Drag a box around the area to search for motion  ·  click to cancel"
                color: "white"
                font.pixelSize: 12
                style: Text.Outline; styleColor: "#a0000000"
            }
        }
        Rectangle {
            visible: areaMa.dragging
            x: Math.min(areaMa.a.x, areaMa.b.x); y: Math.min(areaMa.a.y, areaMa.b.y)
            width: Math.abs(areaMa.b.x - areaMa.a.x); height: Math.abs(areaMa.b.y - areaMa.a.y)
            color: "#30ff7a45"
            border.color: "#ff7a45"
            border.width: 2
        }
    }

    Menu {
        id: tileMenu
        MenuItem { text: root.maximized ? "Restore" : "Maximize"; onTriggered: root.maximizeToggled() }
        MenuItem { text: "Full screen"; onTriggered: root.fullscreenRequested() }
        Menu {
            title: "Quality"
            enabled: root.hasSub
            MenuItem { text: "Same as layout (" + root.sceneQuality + ")"; checkable: true; checked: root.qualityOverride === ""; onTriggered: root.qualityPicked("") }
            MenuItem { text: "High (main stream)"; checkable: true; checked: root.qualityOverride === "high"; onTriggered: root.qualityPicked("high") }
            MenuItem { text: "Low (substream)"; checkable: true; checked: root.qualityOverride === "low"; onTriggered: root.qualityPicked("low") }
        }
        MenuItem { visible: !!(root.cam && root.cam.ptz) && Api.canPtz; height: visible ? implicitHeight : 0; text: root.ptzMode ? "Hide PTZ controls" : "PTZ controls"; onTriggered: root.ptzMode = !root.ptzMode }
        MenuItem { text: root.showInfo ? "Hide stream information" : "Stream information"; onTriggered: root.showInfo = !root.showInfo }
        MenuItem { visible: root.zoom > 1.01; height: visible ? implicitHeight : 0; text: "Reset zoom"; onTriggered: { root.resetZoom(); root.userZoomChanged() } }
        MenuItem { visible: root.zoom > 1.01; height: visible ? implicitHeight : 0; text: "Open zoomed area as new tile"; onTriggered: root.zoomTileRequested() }
        MenuItem {
            visible: Api.canPlayback; height: visible ? implicitHeight : 0
            text: root.searchCells !== "" ? "Clear smart search" : "Smart search in an area…"
            onTriggered: { if (root.searchCells !== "") root.areaChosen(""); else root.selectingArea = true }
        }
        MenuSeparator {}
        MenuItem { visible: Api.isAdmin; height: visible ? implicitHeight : 0; text: "Camera settings…"; onTriggered: root.settingsRequested() }
        MenuSeparator {}
        MenuItem { visible: root.editable; height: visible ? implicitHeight : 0; text: "Remove from layout"; onTriggered: root.closeRequested() }
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
