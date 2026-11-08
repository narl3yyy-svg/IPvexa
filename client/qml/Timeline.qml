import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Playback controls + zoomable timeline showing recorded footage (green), motion (red)
// and bookmarks (amber) for the selected camera.
// Wheel = zoom around the cursor, drag = pan, click = jump, right-click = bookmark / export.
Rectangle {
    id: root
    color: Theme.panel
    property int cameraId: 0
    property string cameraName: ""

    // Visible range (unix ms)
    property real viewEnd: Date.now() + 5 * 60000
    property real viewStart: viewEnd - 3600000
    property bool follow: true
    property var chunks: []
    property var events: []          // motion + bookmarks in (and around) the view
    property string searchCells: ""  // smart search: only motion inside this area
    property real fps: 0              // frame rate of the selected tile (for frame stepping)
    signal bookmarkRequested(real time)
    signal exportRequested(real from, real to)
    signal searchCleared()
    readonly property int motionCount: {
        var n = 0
        for (var i = 0; i < events.length; i++) if (events[i].kind === "motion") n++
        return n
    }
    readonly property real span: viewEnd - viewStart
    readonly property real pos: Clock.position

    function fetch() {
        if (cameraId <= 0) { chunks = []; canvas.requestPaint(); return }
        var pad = span * 0.5
        var cam = cameraId
        var from = Math.floor(viewStart - pad), to = Math.ceil(viewEnd + pad)
        Api.fetchTimeline(cam, from, to, function (err, data) {
            if (!err && data && cam === root.cameraId) {
                root.chunks = data.chunks || []
                canvas.requestPaint()
            }
        })
        // Skip motion when zoomed out too far to see it (keeps requests small).
        var q = "/api/events?camera=" + cam + "&from=" + from + "&to=" + to + "&limit=3000"
        if (span > 3 * 86400000) q += "&kind=bookmark"
        if (searchCells !== "") q += "&cells=" + searchCells
        Api.call("GET", q, null, function (err, list) {
            if (!err && cam === root.cameraId) {
                root.events = list || []
                canvas.requestPaint()
            }
        })
    }
    onSearchCellsChanged: fetch()

    // Jump to the previous / next event (motion or bookmark) from the playhead.
    function jumpEvent(dir) {
        var best = null
        for (var i = 0; i < events.length; i++) {
            var t = events[i].start
            if (dir > 0 && t > pos + 1500 && (best === null || t < best)) best = t
            if (dir < 0 && t < pos - 1500 && (best === null || t > best)) best = t
        }
        if (best !== null) {
            follow = true
            Clock.seek(best - 2000)
            if (best < viewStart || best > viewEnd) zoomTo(span, best, 0.5)
        }
    }
    function recordedAt(t) {
        for (var i = 0; i < chunks.length; i++) if (t >= chunks[i][0] && t < chunks[i][1]) return true
        return false
    }
    function stepFrame(dir) { follow = true; Clock.stepFrame(dir, fps > 0 ? fps : 15) }
    function eventAt(x) {
        var t = canvas.timeAt(x), tol = root.span / canvas.width * 4
        for (var i = events.length - 1; i >= 0; i--) {
            var e = events[i]
            if (e.kind === "bookmark" && Math.abs(t - e.start) <= tol) return e
        }
        return null
    }
    onCameraIdChanged: fetch()
    Timer { id: fetchDebounce; interval: 150; onTriggered: root.fetch() }
    Timer { interval: 5000; running: true; repeat: true; onTriggered: root.fetch() }
    onViewStartChanged: { fetchDebounce.restart(); canvas.requestPaint() }
    onViewEndChanged: { fetchDebounce.restart(); canvas.requestPaint() }

    // Keep the playhead in view while playing.
    onPosChanged: {
        if (follow && !dragArea.pressed) {
            if (pos > viewStart + span * 0.92 || pos < viewStart) {
                var s = span
                viewEnd = pos + s * 0.25
                viewStart = viewEnd - s
            }
        }
        canvas.requestPaint()
    }

    function zoomTo(newSpan, anchorTime, anchorFrac) {
        newSpan = Math.max(15000, Math.min(newSpan, 90 * 86400000))
        viewStart = anchorTime - newSpan * anchorFrac
        viewEnd = viewStart + newSpan
    }

    function fmtPos(ms) {
        var d = new Date(ms)
        return d.toLocaleDateString(Qt.locale(), "ddd d MMM yyyy") + "  " + d.toLocaleTimeString(Qt.locale(), "HH:mm:ss")
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 8

        // ---------- Transport controls ----------
        ColumnLayout {
            spacing: 4
            Layout.alignment: Qt.AlignVCenter
            RowLayout {
                spacing: 2
                Layout.alignment: Qt.AlignHCenter
                IconButton { iconKind: "prev"; iconSize: 12; size: 26; tip: "Previous motion or bookmark"; enabled: Api.canPlayback; onClicked: root.jumpEvent(-1) }
                IconButton { iconKind: "back"; iconSize: 13; tip: "Back 10 s (←)"; enabled: Api.canPlayback; onClicked: Clock.step(-10000) }
                IconButton {
                    iconKind: Clock.playing ? "pause" : "play"
                    size: 34
                    iconSize: 16
                    tint: Theme.text
                    tip: "Play / pause (Space)"
                    enabled: Api.canPlayback
                    onClicked: Clock.togglePlay()
                }
                IconButton { iconKind: "forward"; iconSize: 13; tip: "Forward 10 s (→)"; enabled: !Clock.live && Api.canPlayback; onClicked: Clock.step(10000) }
                IconButton { iconKind: "next"; iconSize: 12; size: 26; tip: "Next motion or bookmark"; enabled: !Clock.live && Api.canPlayback; onClicked: root.jumpEvent(1) }
            }
            RowLayout {
                spacing: 2
                IconButton {
                    text: "◂◂"; size: 20
                    tip: "Play backwards (rewind scan at the chosen speed)"
                    enabled: Api.canPlayback
                    active: Clock.reverse
                    onClicked: { root.follow = true; Clock.reverse = !Clock.reverse }
                }
                IconButton { text: "‹|"; size: 20; tip: "Previous frame (,)"; enabled: Api.canPlayback; onClicked: root.stepFrame(-1) }
                IconButton { text: "|›"; size: 20; tip: "Next frame (.)"; enabled: Api.canPlayback && !Clock.live; onClicked: root.stepFrame(1) }
                Repeater {
                    model: [1, 2, 4, 8, 16]
                    IconButton {
                        text: modelData + "×"
                        size: 20
                        enabled: !Clock.live
                        active: !Clock.live && Clock.speed === modelData && (Clock.playing || Clock.reverse)
                        onClicked: Clock.speed = modelData
                    }
                }
            }
        }

        // ---------- Timeline canvas ----------
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Canvas {
                id: canvas
                anchors.fill: parent
                anchors.topMargin: 6
                anchors.bottomMargin: 6
                renderStrategy: Canvas.Cooperative
                property real hoverX: -1

                function timeAt(x) { return root.viewStart + x / width * root.span }
                function xAt(t) { return (t - root.viewStart) / root.span * width }

                readonly property var steps: [1e3, 2e3, 5e3, 1e4, 15e3, 3e4, 6e4, 12e4, 3e5, 6e5, 9e5, 18e5,
                    36e5, 72e5, 108e5, 216e5, 432e5, 864e5, 1728e5, 6048e5]

                onPaint: {
                    var ctx = getContext("2d")
                    var w = width, h = height
                    ctx.reset()
                    ctx.fillStyle = Theme.panelAlt
                    ctx.fillRect(0, 0, w, h)

                    var tz = -new Date().getTimezoneOffset() * 60000
                    var pxPerMs = w / root.span
                    var label = steps[steps.length - 1], minor = 0
                    for (var i = 0; i < steps.length; i++) if (steps[i] * pxPerMs >= 95) { label = steps[i]; break }
                    for (var j = steps.length - 1; j >= 0; j--)
                        if (steps[j] < label && label % steps[j] === 0 && steps[j] * pxPerMs >= 9) { minor = steps[j]; break }

                    var laneTop = 26, laneH = h - laneTop - 6
                    // Future (after now): darker
                    var nowX = xAt(Date.now())
                    if (nowX < w) {
                        ctx.fillStyle = "#101318"
                        ctx.fillRect(Math.max(0, nowX), 0, w - Math.max(0, nowX), h)
                    }

                    // Minor ticks
                    if (minor > 0) {
                        ctx.strokeStyle = "#2b313c"
                        ctx.lineWidth = 1
                        ctx.beginPath()
                        var t0 = Math.floor((root.viewStart + tz) / minor) * minor - tz
                        for (var t = t0; t <= root.viewEnd; t += minor) {
                            var x = Math.round(xAt(t)) + 0.5
                            ctx.moveTo(x, 16); ctx.lineTo(x, 21)
                        }
                        ctx.stroke()
                    }
                    // Major ticks + labels
                    ctx.font = "11px sans-serif"
                    ctx.textBaseline = "top"
                    var t1 = Math.floor((root.viewStart + tz) / label) * label - tz
                    for (var tt = t1; tt <= root.viewEnd + label; tt += label) {
                        var lx = Math.round(xAt(tt)) + 0.5
                        var d = new Date(tt)
                        var midnight = d.getHours() === 0 && d.getMinutes() === 0 && d.getSeconds() === 0
                        ctx.strokeStyle = midnight ? "#56607a" : "#3a414e"
                        ctx.beginPath(); ctx.moveTo(lx, 12); ctx.lineTo(lx, h); ctx.stroke()
                        var txt = label >= 864e5 || midnight ? d.toLocaleDateString(Qt.locale(), "ddd d MMM")
                                : label < 6e4 ? d.toLocaleTimeString(Qt.locale(), "HH:mm:ss")
                                : d.toLocaleTimeString(Qt.locale(), "HH:mm")
                        ctx.fillStyle = midnight ? Theme.text : Theme.textDim
                        ctx.fillText(txt, lx + 4, 1)
                    }

                    // Recorded footage lane
                    ctx.fillStyle = "#1b2028"
                    ctx.fillRect(0, laneTop, w, laneH)
                    var grad = ctx.createLinearGradient(0, laneTop, 0, laneTop + laneH)
                    grad.addColorStop(0, Theme.recordedHi)
                    grad.addColorStop(1, Theme.recorded)
                    ctx.fillStyle = grad
                    for (var c = 0; c < root.chunks.length; c++) {
                        var a = xAt(root.chunks[c][0]), b = xAt(root.chunks[c][1])
                        if (b < 0 || a > w) continue
                        ctx.fillRect(Math.max(0, a), laneTop, Math.max(1.5, Math.min(w, b) - Math.max(0, a)), laneH)
                    }

                    // Motion (lower half of the lane) and bookmarks (flags on top)
                    var nowMs = Date.now()
                    var motionTop = laneTop + laneH * 0.45
                    ctx.fillStyle = root.searchCells !== "" ? "#ff7a45" : "#e5484d"
                    for (var k = 0; k < root.events.length; k++) {
                        var ev = root.events[k]
                        if (ev.kind !== "motion") continue
                        var ma = xAt(ev.start), mb = xAt(ev.end > 0 ? ev.end : nowMs)
                        if (mb < 0 || ma > w) continue
                        ctx.fillRect(Math.max(0, ma), motionTop, Math.max(2, Math.min(w, mb) - Math.max(0, ma)), laneTop + laneH - motionTop)
                    }
                    for (var q = 0; q < root.events.length; q++) {
                        var bk = root.events[q]
                        if (bk.kind !== "bookmark") continue
                        var ba = xAt(bk.start), bb = xAt(bk.end)
                        if (bb < -8 || ba > w + 8) continue
                        ctx.fillStyle = "#40f5a524"
                        ctx.fillRect(ba, laneTop, Math.max(2, bb - ba), laneH)
                        ctx.fillStyle = Theme.warn
                        ctx.fillRect(Math.round(ba), laneTop - 4, 2, laneH + 4)
                        ctx.beginPath()
                        ctx.moveTo(ba + 2, laneTop - 4); ctx.lineTo(ba + 10, laneTop); ctx.lineTo(ba + 2, laneTop + 4); ctx.closePath()
                        ctx.fill()
                    }

                    // Hover line
                    if (hoverX >= 0) {
                        ctx.strokeStyle = "#80ffffff"
                        ctx.beginPath(); ctx.moveTo(hoverX + 0.5, laneTop - 4); ctx.lineTo(hoverX + 0.5, h); ctx.stroke()
                    }

                    // Playhead
                    var px = xAt(root.pos)
                    if (px >= -2 && px <= w + 2) {
                        var col = Clock.live ? Theme.live : Theme.accent
                        ctx.fillStyle = col
                        ctx.fillRect(Math.round(px) - 1, 12, 2, h - 12)
                        ctx.beginPath()
                        ctx.moveTo(px - 6, 12); ctx.lineTo(px + 6, 12); ctx.lineTo(px, 19); ctx.closePath()
                        ctx.fill()
                    }
                }

                MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    hoverEnabled: true
                    property real pressX: 0
                    property real pressStart: 0
                    property bool moved: false
                    cursorShape: pressed && moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: (m) => {
                        if (m.button === Qt.RightButton) {
                            timeMenu.time = canvas.timeAt(m.x)
                            timeMenu.popup()
                            return
                        }
                        pressX = m.x; pressStart = root.viewStart; moved = false
                    }
                    onPositionChanged: (m) => {
                        canvas.hoverX = m.x
                        if (pressed) {
                            if (Math.abs(m.x - pressX) > 4) moved = true
                            if (moved) {
                                root.follow = false
                                var s = root.span
                                root.viewStart = pressStart - (m.x - pressX) / width * s
                                root.viewEnd = root.viewStart + s
                            }
                        }
                        canvas.requestPaint()
                    }
                    onExited: { canvas.hoverX = -1; canvas.requestPaint() }
                    onReleased: (m) => {
                        if (m.button !== Qt.LeftButton) return
                        if (!moved) {
                            root.follow = true
                            Clock.seek(Math.round(canvas.timeAt(m.x)))
                        }
                    }
                    onWheel: (w) => {
                        var frac = w.x / width
                        var anchor = canvas.timeAt(w.x)
                        var factor = Math.pow(1.25, -w.angleDelta.y / 120)
                        root.zoomTo(root.span * factor, anchor, frac)
                    }
                }

                Menu {
                    id: timeMenu
                    property real time: 0
                    MenuItem { text: "Play from here"; onTriggered: { root.follow = true; Clock.seek(Math.round(timeMenu.time)) } }
                    MenuItem { text: "Add bookmark here…"; enabled: root.cameraId > 0; onTriggered: root.bookmarkRequested(timeMenu.time) }
                    MenuItem {
                        text: "Export clip from here…"
                        enabled: root.cameraId > 0 && Api.canExport
                        onTriggered: root.exportRequested(timeMenu.time, timeMenu.time + 60000)
                    }
                }

                // Picture preview above the timeline while hovering over recorded footage.
                Timer {
                    id: previewDelay
                    interval: 250
                    onTriggered: {
                        var t = canvas.timeAt(canvas.hoverX)
                        preview.time = root.cameraId > 0 && Api.canPlayback && root.recordedAt(t) ? Math.round(t / 1000) * 1000 : 0
                    }
                }
                Connections {
                    target: canvas
                    function onHoverXChanged() {
                        if (canvas.hoverX < 0) { preview.time = 0; previewDelay.stop() }
                        else previewDelay.restart()
                    }
                }
                Rectangle {
                    id: preview
                    property real time: 0
                    visible: time > 0 && canvas.hoverX >= 0 && previewImg.status === Image.Ready
                    z: 20
                    width: 224; height: 126 + 4
                    x: Math.min(Math.max(0, canvas.hoverX - width / 2), canvas.width - width)
                    y: -height - 24
                    radius: 4
                    color: "#000"
                    border.color: Theme.borderStrong
                    Image {
                        id: previewImg
                        anchors.fill: parent
                        anchors.margins: 2
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        source: preview.time > 0 ? Api.frameUrl(root.cameraId, preview.time) + "&w=224" : ""
                    }
                }

                // Hover time tooltip
                Rectangle {
                    visible: canvas.hoverX >= 0
                    x: Math.min(Math.max(0, canvas.hoverX - width / 2), canvas.width - width)
                    y: -height - 2
                    width: hoverText.implicitWidth + 10
                    height: 18
                    radius: 3
                    color: Theme.raised
                    border.color: Theme.borderStrong
                    Text {
                        id: hoverText
                        anchors.centerIn: parent
                        readonly property var bm: canvas.hoverX >= 0 ? root.eventAt(canvas.hoverX) : null
                        text: canvas.hoverX < 0 ? ""
                            : bm ? "Bookmark: " + (bm.note || "(no note)") + (bm.author ? "  ·  " + bm.author : "")
                            : new Date(canvas.timeAt(canvas.hoverX)).toLocaleString(Qt.locale(), "ddd d MMM HH:mm:ss")
                        color: Theme.text
                        font.pixelSize: 10
                    }
                }
            }
        }

        // ---------- Right: position + LIVE ----------
        ColumnLayout {
            spacing: 4
            Layout.preferredWidth: 220
            Layout.fillWidth: false // nested layouts with fill-width children are greedy by default
            Layout.alignment: Qt.AlignVCenter
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Item { Layout.fillWidth: true }
                Rectangle {
                    visible: root.searchCells !== ""
                    implicitWidth: srch.implicitWidth + 12
                    implicitHeight: 18
                    radius: 9
                    color: "#3aff7a45"
                    border.color: "#ff7a45"
                    Text {
                        id: srch
                        anchors.centerIn: parent
                        text: "Smart search: " + root.motionCount + " · clear ✕"
                        color: "#ffb08f"
                        font.pixelSize: 10
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.searchCleared() }
                }
                Text {
                    Layout.maximumWidth: 150
                    text: root.cameraName.length > 0 ? root.cameraName : "No camera selected"
                    color: Theme.textDim
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignRight
                }
            }
            Text {
                Layout.fillWidth: true
                text: root.fmtPos(root.pos)
                color: Clock.live ? Theme.text : "#9cc8ff"
                font.pixelSize: 13
                font.family: Theme.mono
                horizontalAlignment: Text.AlignRight
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 4
                IconButton { text: "1h"; size: 20; tip: "Zoom to 1 hour"; onClicked: root.zoomTo(3600000, root.pos, 0.75) }
                IconButton { text: "1d"; size: 20; tip: "Zoom to 1 day"; onClicked: root.zoomTo(86400000, root.pos, 0.75) }
                IconButton { text: "7d"; size: 20; tip: "Zoom to 1 week"; onClicked: root.zoomTo(7 * 86400000, root.pos, 0.85) }
                IconButton {
                    id: calBtn
                    iconKind: "calendar"; iconSize: 12; size: 22; tip: "Go to a date"
                    onClicked: calendar.open()
                    CalendarPopup {
                        id: calendar
                        y: -height - 6
                        x: calBtn.width - width
                        selected: new Date(root.pos)
                        onPicked: (d) => {
                            // Jump to the start of that day and show the whole day.
                            root.follow = true
                            Clock.seek(d.getTime())
                            root.zoomTo(86400000, d.getTime(), 0)
                        }
                    }
                }
                Rectangle {
                    implicitWidth: liveTxt.implicitWidth + 20
                    implicitHeight: 22
                    radius: 4
                    color: Clock.live ? Theme.live : liveMa.containsMouse ? Theme.raised : Theme.panelAlt
                    border.color: Theme.live
                    Text {
                        id: liveTxt
                        anchors.centerIn: parent
                        text: "● LIVE"
                        color: Clock.live ? "white" : Theme.live
                        font.pixelSize: 11
                        font.weight: Font.Bold
                    }
                    MouseArea {
                        id: liveMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: { root.follow = true; Clock.goLive() }
                    }
                }
            }
        }
    }
}
