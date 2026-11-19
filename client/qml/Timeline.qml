import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Playback controls + zoomable timeline showing recorded footage (green), motion (red)
// and bookmarks (amber) for the selected camera. In sync mode every camera on the
// layout plays the same moment; a thin strip shows when any of them recorded.
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
    property bool sync: true          // all cameras on the layout follow the timeline
    property var cameraIds: []        // cameras on the layout (for the sync strip)
    property var allChunks: []        // footage of any camera on the layout (merged)
    signal syncToggled()
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
        fetchAll(from, to)
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

    // Footage of every camera on the layout, merged into one list of ranges.
    property int allGen: 0
    function fetchAll(from, to) {
        var ids = sync ? cameraIds.filter(function (id, i, a) { return id > 0 && a.indexOf(id) === i }) : []
        var gen = ++allGen
        if (ids.length < 2) { allChunks = []; return }
        var lists = [], left = ids.length
        ids.forEach(function (id) {
            Api.fetchTimeline(id, from, to, function (err, data) {
                if (gen !== root.allGen) return
                if (!err && data && data.chunks) lists.push(data.chunks)
                if (--left > 0) return
                var all = [].concat.apply([], lists).sort(function (a, b) { return a[0] - b[0] })
                var merged = []
                all.forEach(function (c) {
                    var n = merged.length
                    if (n > 0 && c[0] <= merged[n - 1][1] + 3000) merged[n - 1][1] = Math.max(merged[n - 1][1], c[1])
                    else merged.push([c[0], c[1]])
                })
                root.allChunks = merged
                canvas.requestPaint()
            })
        })
    }
    onSyncChanged: fetch()
    onCameraIdsChanged: fetchDebounce.restart()

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
        // Zoomed to somewhere else: stop pulling the view back to the playhead.
        if (pos < viewStart || pos > viewEnd) follow = false
    }

    function fmtPos(ms) {
        var d = new Date(ms)
        return d.toLocaleDateString(Qt.locale(), "ddd d MMM yyyy") + "  " + d.toLocaleTimeString(Qt.locale(), "HH:mm:ss")
    }

    Rectangle {
        visible: !Clock.live
        width: parent.width
        height: 2
        color: "#1f6fd1"
        z: 5
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
                IconButton {
                    text: "Sync"; size: 20
                    active: root.sync
                    tip: root.sync ? "Sync is on: every camera on the layout plays the same moment. Click to play back only the selected camera."
                                   : "Sync is off: only the selected camera plays back, the others stay live. Click to sync all cameras."
                    onClicked: root.syncToggled()
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
                anchors.bottomMargin: 14
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

                    // Two-row ruler: the day (or month) on top, the time (or day) below.
                    var rowH = 14, laneTop = 2 * rowH + 6, laneH = h - laneTop - 4
                    // Future (after now): darker
                    var nowX = xAt(Date.now())
                    if (nowX < w) {
                        ctx.fillStyle = "#101318"
                        ctx.fillRect(Math.max(0, nowX), 0, w - Math.max(0, nowX), h)
                    }
                    ctx.fillStyle = "#151a20"
                    ctx.fillRect(0, 0, w, rowH)

                    // Minor ticks
                    if (minor > 0) {
                        ctx.strokeStyle = "#2b313c"
                        ctx.lineWidth = 1
                        ctx.beginPath()
                        var t0 = Math.floor((root.viewStart + tz) / minor) * minor - tz
                        for (var t = t0; t <= root.viewEnd; t += minor) {
                            var x = Math.round(xAt(t)) + 0.5
                            ctx.moveTo(x, 2 * rowH + 1); ctx.lineTo(x, laneTop - 1)
                        }
                        ctx.stroke()
                    }
                    ctx.font = "11px sans-serif"
                    ctx.textBaseline = "top"
                    var daysBelow = label >= 864e5
                    // Top row: days (or months when the bottom row shows days), with
                    // the one at the left edge always named.
                    var bigs = []
                    var cur = new Date(root.viewStart)
                    var big = daysBelow ? new Date(cur.getFullYear(), cur.getMonth(), 1) : new Date(cur.getFullYear(), cur.getMonth(), cur.getDate())
                    while (big.getTime() <= root.viewEnd) {
                        bigs.push(big.getTime())
                        big = daysBelow ? new Date(big.getFullYear(), big.getMonth() + 1, 1) : new Date(big.getFullYear(), big.getMonth(), big.getDate() + 1)
                    }
                    var bigText = function (ms) {
                        return daysBelow ? new Date(ms).toLocaleDateString(Qt.locale(), "MMMM yyyy")
                                         : new Date(ms).toLocaleDateString(Qt.locale(), "dddd d MMMM yyyy")
                    }
                    for (var bi = 0; bi < bigs.length; bi++) {
                        var bx = xAt(bigs[bi])
                        var nextX = bi + 1 < bigs.length ? xAt(bigs[bi + 1]) : w
                        var tx = Math.max(bx, 0) + 6
                        if (bx > 0) {
                            ctx.strokeStyle = "#56607a"
                            ctx.beginPath(); ctx.moveTo(Math.round(bx) + 0.5, 0); ctx.lineTo(Math.round(bx) + 0.5, h); ctx.stroke()
                        }
                        var bt = bigText(bigs[bi])
                        var tw = ctx.measureText(bt).width
                        // Slide the label left out of the way of the next one.
                        tx = Math.min(tx, nextX - tw - 8)
                        if (tx + tw > 0 && tx < w) {
                            ctx.fillStyle = Theme.text
                            ctx.fillText(bt, tx, 1)
                        }
                    }
                    // Bottom row: major ticks with times (or days).
                    var t1 = Math.floor((root.viewStart + tz) / label) * label - tz
                    for (var tt = t1; tt <= root.viewEnd + label; tt += label) {
                        var lx = Math.round(xAt(tt)) + 0.5
                        var d = new Date(tt)
                        ctx.strokeStyle = "#3a414e"
                        ctx.beginPath(); ctx.moveTo(lx, rowH); ctx.lineTo(lx, h); ctx.stroke()
                        var txt = daysBelow ? d.toLocaleDateString(Qt.locale(), "ddd d")
                                : label < 6e4 ? d.toLocaleTimeString(Qt.locale(), "HH:mm:ss")
                                : d.toLocaleTimeString(Qt.locale(), "HH:mm")
                        ctx.fillStyle = Theme.textDim
                        ctx.fillText(txt, lx + 4, rowH + 1)
                    }

                    // Sync: thin strip above the lane = footage on any camera of the layout
                    if (root.sync && root.allChunks.length > 0) {
                        ctx.fillStyle = "#5a8fd0"
                        for (var ac = 0; ac < root.allChunks.length; ac++) {
                            var aa = xAt(root.allChunks[ac][0]), ab = xAt(root.allChunks[ac][1])
                            if (ab < 0 || aa > w) continue
                            ctx.fillRect(Math.max(0, aa), laneTop - 4, Math.max(1.5, Math.min(w, ab) - Math.max(0, aa)), 2)
                        }
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
                        ctx.fillRect(Math.round(px) - 1, rowH, 2, h - rowH)
                        ctx.beginPath()
                        ctx.moveTo(px - 6, rowH); ctx.lineTo(px + 6, rowH); ctx.lineTo(px, rowH + 7); ctx.closePath()
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
                    // Double-click zooms in on that spot.
                    onDoubleClicked: (m) => {
                        if (m.button === Qt.LeftButton) root.zoomTo(root.span * 0.4, canvas.timeAt(m.x), m.x / width)
                    }
                    onWheel: (w) => {
                        var frac = w.x / width
                        var anchor = canvas.timeAt(w.x)
                        var factor = Math.pow(1.25, -w.angleDelta.y / 120)
                        root.zoomTo(root.span * factor, anchor, frac)
                    }
                }

                // Scroll strip: where the visible part sits in the surrounding days.
                // Drag the handle (or click the strip) to move along the timeline.
                Item {
                    id: strip
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.bottom
                    anchors.topMargin: 3
                    height: 7
                    // The range covered: whole local days around the view, at least
                    // three times what is shown (frozen while dragging).
                    property real rangeStart: 0
                    property real rangeEnd: 1
                    property bool frozen: false
                    function update() {
                        if (frozen) return
                        var pad = root.span
                        var a = new Date(root.viewStart - pad), b = new Date(root.viewEnd + pad)
                        rangeStart = new Date(a.getFullYear(), a.getMonth(), a.getDate()).getTime()
                        rangeEnd = new Date(b.getFullYear(), b.getMonth(), b.getDate() + 1).getTime()
                    }
                    Connections {
                        target: root
                        function onViewStartChanged() { strip.update() }
                        function onViewEndChanged() { strip.update() }
                    }
                    Component.onCompleted: update()
                    readonly property real len: Math.max(1, rangeEnd - rangeStart)
                    Rectangle { anchors.fill: parent; radius: 3.5; color: "#151a20" }
                    // Midnights
                    Repeater {
                        model: Math.min(60, Math.round(strip.len / 86400000) - 1)
                        Rectangle {
                            required property int index
                            x: (new Date(new Date(strip.rangeStart).getFullYear(), new Date(strip.rangeStart).getMonth(),
                                         new Date(strip.rangeStart).getDate() + index + 1).getTime() - strip.rangeStart) / strip.len * strip.width
                            width: 1; height: strip.height
                            color: "#2b313c"
                        }
                    }
                    Rectangle {
                        id: thumb
                        x: (root.viewStart - strip.rangeStart) / strip.len * strip.width
                        width: Math.max(14, root.span / strip.len * strip.width)
                        height: strip.height
                        radius: 3.5
                        color: stripMa.pressed || stripMa.containsMouse ? "#7f8b99" : "#56607a"
                    }
                    MouseArea {
                        id: stripMa
                        anchors.fill: parent
                        anchors.topMargin: -4
                        anchors.bottomMargin: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        property real grab: 0.5   // where on the handle it was taken
                        function moveTo(x) {
                            var s = root.span
                            root.follow = false
                            root.viewStart = strip.rangeStart + (x - grab * thumb.width) / strip.width * strip.len
                            root.viewEnd = root.viewStart + s
                        }
                        onPressed: (m) => {
                            strip.frozen = true
                            grab = m.x >= thumb.x && m.x <= thumb.x + thumb.width ? (m.x - thumb.x) / thumb.width : 0.5
                            moveTo(m.x)
                        }
                        onPositionChanged: (m) => { if (pressed) moveTo(m.x) }
                        onReleased: { strip.frozen = false; strip.update() }
                        ToolTip.visible: containsMouse && !pressed
                        ToolTip.delay: 800
                        ToolTip.text: "Drag to move along the timeline. Mouse wheel on the timeline zooms; double-click zooms in."
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

        // ---------- Right: camera, date (opens the calendar), LIVE / PLAYBACK ----------
        ColumnLayout {
            spacing: 4
            Layout.preferredWidth: 252
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
            // Date and time of the playhead. Click to pick a day.
            AbstractButton {
                id: dateBtn
                Layout.fillWidth: true
                implicitHeight: 24
                hoverEnabled: true
                onClicked: calendar.opened ? calendar.close() : calendar.open()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "Go to a date"
                background: Rectangle {
                    radius: 4
                    color: dateBtn.down || calendar.opened ? Theme.raised : dateBtn.hovered ? Theme.panelAlt : "transparent"
                    border.color: dateBtn.hovered || calendar.opened ? Theme.borderStrong : "transparent"
                }
                contentItem: Item {
                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7
                        TileIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            kind: "calendar"; width: 12; height: 12
                            color: dateBtn.hovered || calendar.opened ? Theme.accent : Theme.textDim
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.fmtPos(root.pos)
                            color: Clock.live ? Theme.text : "#9cc8ff"
                            font.pixelSize: 13
                            font.family: Theme.mono
                        }
                    }
                }
                CalendarPopup {
                    id: calendar
                    y: -height - 6
                    x: dateBtn.width - width
                    selected: new Date(root.pos)
                    cameraId: root.cameraId
                    onPicked: (d, first) => {
                        // Show the whole day and play from its first footage.
                        var end = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime()
                        root.zoomTo(end - d.getTime(), d.getTime(), 0)
                        root.follow = true
                        Clock.seek(first > 0 ? first : d.getTime())
                    }
                }
            }
            // Playback and zoom: −30 s, play / pause, +30 s, speed, zoom out / in.
            RowLayout {
                Layout.fillWidth: true
                spacing: 3
                IconButton { text: "−30 s"; size: 22; tip: "Back 30 seconds"; enabled: Api.canPlayback; onClicked: { root.follow = true; Clock.step(-30000) } }
                IconButton {
                    iconKind: Clock.playing ? "pause" : "play"; iconSize: 11; size: 22
                    tip: Clock.playing ? "Pause (Space)" : "Play (Space)"
                    enabled: Api.canPlayback
                    onClicked: Clock.togglePlay()
                }
                IconButton { text: "+30 s"; size: 22; tip: "Forward 30 seconds"; enabled: Api.canPlayback && !Clock.live; onClicked: { root.follow = true; Clock.step(30000) } }
                IconButton {
                    text: (Clock.live ? 1 : Clock.speed) + "×"; size: 22
                    tip: "Playback speed: click for faster (1×, 2×, 4×, 8×, 16×)"
                    enabled: !Clock.live
                    active: !Clock.live && Clock.speed > 1
                    onClicked: { var v = [1, 2, 4, 8, 16]; Clock.speed = v[(v.indexOf(Clock.speed) + 1) % v.length] }
                }
                Item { Layout.fillWidth: true }
                IconButton { text: "−"; size: 22; tip: "Zoom out (or scroll the mouse wheel on the timeline)"; onClicked: root.zoomTo(root.span * 2, root.pos, 0.5) }
                IconButton { text: "+"; size: 22; tip: "Zoom in on the playhead"; onClicked: root.zoomTo(root.span / 2, root.pos, 0.5) }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                IconButton { text: "1h"; size: 20; tip: "Zoom to 1 hour"; onClicked: root.zoomTo(3600000, root.pos, 0.75) }
                IconButton { text: "1d"; size: 20; tip: "Zoom to 1 day"; onClicked: root.zoomTo(86400000, root.pos, 0.75) }
                IconButton { text: "7d"; size: 20; tip: "Zoom to 1 week"; onClicked: root.zoomTo(7 * 86400000, root.pos, 0.85) }
                IconButton {
                    text: "Day"; size: 20; tip: "Show the whole day of the playhead"
                    onClicked: {
                        var p = new Date(root.pos), a = new Date(p.getFullYear(), p.getMonth(), p.getDate())
                        root.zoomTo(new Date(p.getFullYear(), p.getMonth(), p.getDate() + 1).getTime() - a.getTime(), a.getTime(), 0)
                    }
                }
                Item { Layout.fillWidth: true }
                // Back to live (only while playing back).
                AbstractButton {
                    id: goLive
                    visible: !Clock.live
                    implicitWidth: goLiveTxt.implicitWidth + 16
                    implicitHeight: 22
                    hoverEnabled: true
                    onClicked: { root.follow = true; Clock.goLive() }
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: "Back to live video (L)"
                    background: Rectangle { radius: 4; color: goLive.hovered ? "#33ff4757" : "transparent"; border.color: Theme.live }
                    contentItem: Text {
                        id: goLiveTxt
                        text: "Go live"
                        color: Theme.live
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                // What you are watching: LIVE (red) or recorded footage (blue).
                Rectangle {
                    readonly property string label: Clock.live ? "● LIVE"
                        : Clock.reverse ? "◂◂ REWIND " + Clock.speed + "×"
                        : !Clock.playing ? "❚❚ PAUSED"
                        : "▶ PLAYBACK" + (Clock.speed > 1 ? " " + Clock.speed + "×" : "")
                    implicitWidth: Math.max(64, modeTxt.implicitWidth + 16)
                    implicitHeight: 22
                    radius: 4
                    color: Clock.live ? Theme.live : Clock.playing || Clock.reverse ? "#1f6fd1" : "#2a3f5c"
                    Text {
                        id: modeTxt
                        anchors.centerIn: parent
                        text: parent.label
                        color: "white"
                        font.pixelSize: 11
                        font.weight: Font.Bold
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: Clock.live
                        hoverEnabled: true
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 600
                        ToolTip.text: "Showing live video. Click the timeline to play back recordings."
                    }
                }
            }
        }
    }
}
