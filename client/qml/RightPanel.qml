import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Right panel (Nx-style): Notifications (camera events as they happen) and Health.
Rectangle {
    id: root
    color: Theme.panel
    property int tab: 0
    property var events: []          // newest first: {time, cam, name, kind, detail}
    property var lastState: ({})     // cam id -> {state, recording}
    property int unread: 0

    signal cameraFocusRequested(int cameraId, real time)

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

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- Tabs ----
        Row {
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            Repeater {
                model: [{ t: "Notifications", i: "bell" }, { t: "Health", i: "pulse" }]
                Rectangle {
                    width: root.width / 2
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
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

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
                       text: "Camera offline / online and recording changes appear here. Motion and AI events arrive in a later phase."
                       color: Theme.textFaint; font.pixelSize: 11 }
            }
        }

        // ---- Health ----
        Flickable {
            visible: root.tab === 1
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
                                Rectangle { width: 7; height: 7; radius: 3.5; color: Theme.stateColor(!modelData.enabled ? "disabled" : (m ? m.state : "offline")) }
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
