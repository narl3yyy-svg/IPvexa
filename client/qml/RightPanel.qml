import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Right panel (Nx-style): Notifications (camera status changes as they happen),
// Events (motion and bookmarks from the server, with thumbnails) and Health.
Rectangle {
    id: root
    color: Theme.panel
    property int tab: 0
    property var events: []          // newest first: {time, cam, name, kind, detail}
    property var lastState: ({})     // cam id -> {state, recording}
    property int unread: 0

    signal cameraFocusRequested(int cameraId, real time)

    // ---- Events tab data ----
    property var serverEvents: []
    property string eventKind: ""   // "" | motion | bookmark
    function loadEvents() {
        if (!Api.canPlayback) { serverEvents = []; return }
        var q = "/api/events?newest=1&limit=150&from=" + (Date.now() - 7 * 86400000) + (eventKind ? "&kind=" + eventKind : "")
        Api.call("GET", q, null, function (err, list) { if (!err) root.serverEvents = list || [] })
    }
    onEventKindChanged: loadEvents()
    Timer { interval: 10000; repeat: true; running: root.visible && root.tab === 1; triggeredOnStart: true; onTriggered: root.loadEvents() }
    function fmtLen(ms) {
        if (ms <= 0) return "now"
        var s = Math.round(ms / 1000)
        return s < 60 ? s + " s" : Math.floor(s / 60) + " min " + (s % 60) + " s"
    }

    function push(ev) {
        var list = [ev].concat(events)
        if (list.length > 200) list = list.slice(0, 200)
        events = list
        if (tab !== 0 || !visible) unread++
    }

    // Derive events from the camera status the app already polls every 2 s.
    Connections {
        target: Api
        function onCamerasChanged() {
            var seen = root.lastState, next = {}
            var now = Date.now()
            Api.cameras.forEach(function (c) {
                var m = c.status && c.status.main ? c.status.main : {}
                var st = !c.enabled ? "disabled" : (m.state || "offline")
                var cur = { state: st === "starting" ? (seen[c.id] ? seen[c.id].state : "starting") : st, recording: !!m.recording }
                next[c.id] = cur
                var prev = seen[c.id]
                if (!prev) return
                if (prev.state !== cur.state && (cur.state === "offline" || (cur.state === "online" && prev.state === "offline")))
                    root.push({ time: now, cam: c.id, name: c.name, kind: cur.state,
                                detail: cur.state === "offline" ? (m.last_error || "Stream lost") : "Stream restored" })
                if (prev.recording !== cur.recording && cur.state === "online")
                    root.push({ time: now, cam: c.id, name: c.name, kind: cur.recording ? "rec-on" : "rec-off",
                                detail: cur.recording ? "Recording started" : "Recording stopped" })
            })
            root.lastState = next
        }
    }

    function fmtBytes(b) {
        if (!b) return "0 B"
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0
        while (b >= 1024 && i < u.length - 1) { b /= 1024; i++ }
        return b.toFixed(b >= 100 || i === 0 ? 0 : 1) + " " + u[i]
    }
    function fmtDuration(s) {
        var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
        return d > 0 ? d + "d " + h + "h" : h > 0 ? h + "h " + m + "m" : m + "m"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- Tabs ----
        Row {
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            Repeater {
                model: [{ t: "Alerts", i: "bell" }, { t: "Events", i: "motion" }, { t: "Health", i: "pulse" }]
                Rectangle {
                    width: root.width / 3
                    height: 38
                    color: tma.containsMouse && root.tab !== index ? Theme.panelAlt : "transparent"
                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        TileIcon { kind: modelData.i; width: 13; height: 13; color: root.tab === index ? Theme.accent : Theme.textDim; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: modelData.t; color: root.tab === index ? Theme.text : Theme.textDim; font.pixelSize: 12; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
                        Rectangle {
                            visible: index === 0 && root.unread > 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(16, unreadText.implicitWidth + 8); height: 16; radius: 8
                            color: Theme.live
                            Text { id: unreadText; anchors.centerIn: parent; text: root.unread > 99 ? "99+" : root.unread; color: "white"; font.pixelSize: 9; font.weight: Font.Bold }
                        }
                    }
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: root.tab === index ? Theme.accent : "transparent" }
                    MouseArea { id: tma; anchors.fill: parent; hoverEnabled: true; onClicked: { root.tab = index; if (index === 0) root.unread = 0 } }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

        // ---- Notifications ----
        ListView {
            visible: root.tab === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.events
            spacing: 1
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: 54
                color: ema.containsMouse ? Theme.panelAlt : "transparent"
                Rectangle {
                    width: 3; height: parent.height - 12; anchors.verticalCenter: parent.verticalCenter; x: 6; radius: 1.5
                    color: modelData.kind === "offline" ? Theme.live : modelData.kind === "online" ? Theme.online
                         : modelData.kind === "rec-on" ? Theme.warn : Theme.textFaint
                }
                Column {
                    anchors.left: parent.left; anchors.leftMargin: 18
                    anchors.right: parent.right; anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    RowLayout {
                        width: parent.width
                        Text { Layout.fillWidth: true; text: modelData.name; color: Theme.text; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight }
                        Text { text: new Date(modelData.time).toLocaleTimeString(Qt.locale(), "HH:mm:ss"); color: Theme.textFaint; font.pixelSize: 10 }
                    }
                    Text {
                        width: parent.width
                        text: modelData.kind === "offline" ? "Camera offline" : modelData.kind === "online" ? "Camera back online" : modelData.detail
                        color: modelData.kind === "offline" ? "#ff8a93" : Theme.textDim
                        font.pixelSize: 11
                    }
                    Text {
                        visible: modelData.kind === "offline" && modelData.detail !== ""
                        width: parent.width
                        text: modelData.detail
                        color: Theme.textFaint
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                MouseArea {
                    id: ema
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.cameraFocusRequested(modelData.cam, modelData.time)
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 700
                    ToolTip.text: "Show this camera at " + new Date(modelData.time).toLocaleTimeString(Qt.locale(), "HH:mm:ss")
                }
            }
            Column {
                anchors.centerIn: parent
                visible: root.events.length === 0
                spacing: 8
                TileIcon { anchors.horizontalCenter: parent.horizontalCenter; kind: "bell"; width: 30; height: 30; color: Theme.textFaint }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "No notifications"; color: Theme.textDim; font.pixelSize: 13 }
                Text { anchors.horizontalCenter: parent.horizontalCenter; width: root.width - 40; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                       text: "Cameras going offline or coming back, and recording starting or stopping, appear here while the app is open."
                       color: Theme.textFaint; font.pixelSize: 11 }
            }
        }

        // ---- Events (server) ----
        ColumnLayout {
            visible: root.tab === 1
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            Segmented {
                Layout.margins: 8
                Layout.alignment: Qt.AlignHCenter
                value: root.eventKind === "" ? "all" : root.eventKind
                options: [{ value: "all", label: "All" }, { value: "motion", label: "Motion" }, { value: "bookmark", label: "Bookmarks" }]
                onPicked: (v) => root.eventKind = v === "all" ? "" : v
            }
            ListView {
                id: evList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 1
                model: root.serverEvents
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    required property var modelData
                    readonly property var cam: Theme.findCamera(Api.cameras, modelData.camera_id)
                    readonly property bool isBm: modelData.kind === "bookmark"
                    width: ListView.view.width
                    height: 64
                    color: evMa.containsMouse ? Theme.panelAlt : "transparent"
                    Rectangle {
                        id: thumbBox
                        x: 8; anchors.verticalCenter: parent.verticalCenter
                        width: 88; height: 50; radius: 4
                        color: "#0b0e10"
                        clip: true
                        Image {
                            id: thumb
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 176
                            // Only request thumbnails for rows on screen.
                            property int retry: 0
                            source: evList.visible ? Api.eventThumbUrl(modelData.id) + "&w=176" + (retry > 0 ? "&r=" + retry : "") : ""
                            // A brand-new event's snapshot may still be on its way: try again shortly.
                            Timer {
                                interval: 3000
                                running: thumb.status === Image.Error && thumb.retry < 3 && Date.now() - modelData.start < 120000
                                onTriggered: thumb.retry++
                            }
                        }
                        TileIcon {
                            anchors.centerIn: parent
                            visible: thumb.status !== Image.Ready
                            kind: isBm ? "bookmark" : "motion"
                            width: 16; height: 16
                            color: Theme.textFaint
                        }
                        Rectangle {
                            anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 3
                            width: kindText.implicitWidth + 8; height: 14; radius: 3
                            color: isBm ? "#c0f5a524" : "#c0e5484d"
                            Text { id: kindText; anchors.centerIn: parent; text: isBm ? "BOOKMARK" : "MOTION"; color: "white"; font.pixelSize: 8; font.weight: Font.Bold }
                        }
                    }
                    Column {
                        anchors.left: thumbBox.right; anchors.leftMargin: 10
                        anchors.right: parent.right; anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { width: parent.width; text: cam ? cam.name : "Camera " + modelData.camera_id; color: Theme.text; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight }
                        Text {
                            width: parent.width
                            text: new Date(modelData.start).toLocaleString(Qt.locale(), "ddd d MMM  HH:mm:ss")
                            color: Theme.textDim; font.pixelSize: 11
                        }
                        Text {
                            width: parent.width
                            text: isBm ? (modelData.note || "(no note)") + (modelData.author ? "  ·  " + modelData.author : "")
                                       : root.fmtLen(modelData.end > 0 ? modelData.end - modelData.start : 0)
                            color: Theme.textFaint; font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                    MouseArea {
                        id: evMa
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: (m) => {
                            if (m.button === Qt.RightButton) { evMenu.popup(); return }
                            root.cameraFocusRequested(modelData.camera_id, modelData.start + 8000)
                        }
                    }
                    Menu {
                        id: evMenu
                        MenuItem { text: "Play from here"; onTriggered: root.cameraFocusRequested(modelData.camera_id, modelData.start + 8000) }
                        MenuItem {
                            text: "Delete bookmark"
                            visible: isBm && (Api.isAdmin || modelData.author === Api.username)
                            height: visible ? implicitHeight : 0
                            onTriggered: Api.call("DELETE", "/api/events/" + modelData.id, null, function () { root.loadEvents() })
                        }
                    }
                }
                Column {
                    anchors.centerIn: parent
                    visible: evList.count === 0
                    spacing: 8
                    width: root.width - 40
                    TileIcon { anchors.horizontalCenter: parent.horizontalCenter; kind: "motion"; width: 30; height: 30; color: Theme.textFaint }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: Api.canPlayback ? "No events this week" : "Your account can't view recordings"; color: Theme.textDim; font.pixelSize: 13 }
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                        visible: Api.canPlayback
                        text: "Turn on motion detection in a camera's settings (Motion tab), or right-click the timeline to add a bookmark."
                        color: Theme.textFaint; font.pixelSize: 11
                    }
                }
            }
        }

        // ---- Health ----
        Flickable {
            visible: root.tab === 2
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: healthCol.implicitHeight + 16
            ScrollBar.vertical: ScrollBar {}
            Column {
                id: healthCol
                width: parent.width
                padding: 12
                spacing: 10

                // Storage
                Column {
                    width: healthCol.width - 24
                    spacing: 6
                    property var d: Api.system.disk
                    Text { text: "STORAGE"; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1 }
                    Rectangle {
                        width: parent.width; height: 8; radius: 4; color: "#12171a"
                        Rectangle {
                            height: parent.height; radius: 4
                            width: parent.d && parent.d.total ? parent.width * (1 - parent.d.free / parent.d.total) : 0
                            color: parent.d && parent.d.total && parent.d.free / parent.d.total < 0.12 ? Theme.live : Theme.accent
                        }
                    }
                    Text {
                        text: parent.d && parent.d.total ? root.fmtBytes(parent.d.total - parent.d.free) + " used of " + root.fmtBytes(parent.d.total)
                                                           + " · " + root.fmtBytes(parent.d.free) + " free" : "—"
                        color: Theme.textDim; font.pixelSize: 11
                    }
                    Text {
                        visible: Api.system.write_bps !== undefined
                        text: "Writing " + ((Api.system.write_bps || 0) * 8 / 1e6).toFixed(1) + " Mb/s  ·  "
                              + root.fmtBytes((Api.system.write_bps || 0) * 86400) + " per day"
                              + (Api.system.write_bps > 0 && parent.d && parent.d.free
                                 ? "  ·  ~" + Math.floor(parent.d.free / (Api.system.write_bps * 86400)) + " days of space left" : "")
                        color: Theme.textFaint; font.pixelSize: 10
                        width: parent.width
                        wrapMode: Text.Wrap
                    }
                    Text {
                        visible: !!Api.system.uptime_s
                        text: "Server " + (Api.system.version || "") + " · up " + root.fmtDuration(Api.system.uptime_s || 0)
                        color: Theme.textFaint; font.pixelSize: 10
                    }
                }
                Rectangle { width: healthCol.width - 24; height: 1; color: Theme.border }
                Text { text: "CAMERAS"; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1 }

                Repeater {
                    model: Api.cameras
                    Rectangle {
                        required property var modelData
                        readonly property var m: modelData.status && modelData.status.main ? modelData.status.main : null
                        readonly property var rec: (Api.system.recordings || []).filter(function (r) { return r.id === modelData.id })[0]
                        width: healthCol.width - 24
                        height: hc.implicitHeight + 14
                        radius: 6
                        color: "#151b1e"
                        border.color: Theme.border
                        Column {
                            id: hc
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: 8
                            spacing: 3
                            RowLayout {
                                width: parent.width
                                Rectangle { implicitWidth: 7; implicitHeight: 7; radius: 3.5; color: Theme.stateColor(!modelData.enabled ? "disabled" : (m ? m.state : "offline")) }
                                Text { Layout.fillWidth: true; text: modelData.name; color: Theme.text; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight }
                                Text { text: m ? m.state : "—"; color: Theme.textDim; font.pixelSize: 10 }
                            }
                            Text {
                                text: m && m.width ? (m.codec || "").toUpperCase() + " " + m.width + "×" + m.height + (m.fps ? " @ " + m.fps + " fps" : "")
                                                     + " · " + ((m.bitrate_bps || 0) / 1e6).toFixed(2) + " Mb/s" : "no stream info"
                                color: Theme.textDim; font.pixelSize: 10; font.family: Theme.mono
                            }
                            Text {
                                text: (m && m.recording ? "Recording" : "Not recording")
                                      + (rec ? " · " + root.fmtBytes(rec.bytes) + " stored" : "")
                                      + (m ? " · " + (m.viewers || 0) + " viewers · " + (m.restarts || 0) + " reconnects" : "")
                                color: Theme.textFaint; font.pixelSize: 10
                            }
                            Text {
                                visible: !!(m && m.state !== "online" && m.last_error)
                                width: parent.width
                                text: m && m.last_error ? m.last_error : ""
                                color: "#ff8a93"; font.pixelSize: 10; elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
