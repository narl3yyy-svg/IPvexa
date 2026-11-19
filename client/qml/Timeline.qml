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
    signal saveRequested(real from, real to)
    // Selected part of the timeline (Shift+drag, or right-click "Start / End selection here").
    property real selStart: 0
    property real selEnd: 0
    readonly property bool hasSel: selEnd > selStart
    onSelStartChanged: canvas.requestPaint()
    onSelEndChanged: canvas.requestPaint()
    function clearSelection() { selStart = 0; selEnd = 0 }
    function setSelection(a, b) {
        if (b < a) { var t = a; a = b; b = t }
        selStart = Math.round(a); selEnd = Math.round(b)
    }
    function fmtLength(ms) {
        var s = Math.round(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
        s = s % 60
        return h > 0 ? h + " h " + m + " min" : m > 0 ? m + " min" + (s > 0 ? " " + s + " s" : "") : s + " s"
    }
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

                    // Selection: a blue band with edges and grips.
                    if (root.hasSel) {
                        var sa = xAt(root.selStart), sb = xAt(root.selEnd)
                        if (sb >= 0 && sa <= w) {
                            ctx.fillStyle = "#334aa3ff"
                            ctx.fillRect(Math.max(0, sa), rowH, Math.min(w, sb) - Math.max(0, sa), h - rowH)
                            ctx.fillStyle = "#4aa3ff"
                            if (sa >= 0) { ctx.fillRect(Math.round(sa) - 1, rowH, 2, h - rowH); ctx.fillRect(Math.round(sa) - 3, laneTop + laneH / 2 - 7, 6, 14) }
                            if (sb <= w) { ctx.fillRect(Math.round(sb) - 1, rowH, 2, h - rowH); ctx.fillRect(Math.round(sb) - 3, laneTop + laneH / 2 - 7, 6, 14) }
                        }
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
                    // "" (pan / click) | "new" (Shift+drag) | "start" / "end" (moving an edge)
                    property string selMode: ""
                    property real selAnchor: 0
                    function edgeAt(x) {
                        if (!root.hasSel) return ""
                        if (Math.abs(x - canvas.xAt(root.selStart)) <= 5) return "start"
                        if (Math.abs(x - canvas.xAt(root.selEnd)) <= 5) return "end"
                        return ""
                    }
                    property string hoverEdge: ""
                    cursorShape: selMode !== "" || hoverEdge !== "" ? Qt.SizeHorCursor
                               : pressed && moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: (m) => {
                        if (m.button === Qt.RightButton) {
                            timeMenu.time = canvas.timeAt(m.x)
                            timeMenu.popup()
                            return
                        }
                        pressX = m.x; pressStart = root.viewStart; moved = false
                        var edge = edgeAt(m.x)
                        if (edge !== "") selMode = edge
                        else if (m.modifiers & Qt.ShiftModifier) { selMode = "new"; selAnchor = canvas.timeAt(m.x); root.setSelection(selAnchor, selAnchor) }
                        else selMode = ""
                    }
                    onPositionChanged: (m) => {
                        canvas.hoverX = m.x
                        if (!pressed) hoverEdge = edgeAt(m.x)
                        if (pressed && selMode !== "") {
                            moved = moved || Math.abs(m.x - pressX) > 2
                            var t = canvas.timeAt(Math.max(0, Math.min(width, m.x)))
                            if (selMode === "new") root.setSelection(selAnchor, t)
                            else if (selMode === "start") {
                                if (t < root.selEnd) root.selStart = Math.round(t)
                                else { root.selStart = root.selEnd; root.selEnd = Math.round(t); selMode = "end" }
                            } else {
                                if (t > root.selStart) root.selEnd = Math.round(t)
                                else { root.selEnd = root.selStart; root.selStart = Math.round(t); selMode = "start" }
                            }
                        } else if (pressed) {
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
                        if (selMode !== "") {
                            selMode = ""
                            if (root.selEnd - root.selStart < 1000) root.clearSelection()   // a Shift+click, not a drag
                            return
                        }
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
                        ToolTip.text: "Drag to move along the timeline. Mouse wheel on the timeline zooms; double-click zooms in; Shift+drag selects a part to save."
                    }
                }

                Menu {
                    id: timeMenu
                    property real time: 0
                    MenuItem { text: "Play from here"; onTriggered: { root.follow = true; Clock.seek(Math.round(timeMenu.time)) } }
                    MenuItem { text: "Add bookmark here…"; enabled: root.cameraId > 0; onTriggered: root.bookmarkRequested(timeMenu.time) }
                    MenuSeparator {}
                    MenuItem {
                        text: "Start selection here"
                        onTriggered: root.setSelection(timeMenu.time, root.hasSel && root.selEnd > timeMenu.time ? root.selEnd : timeMenu.time + 60000)
                    }
                    MenuItem {
                        text: "End selection here"
                        onTriggered: root.setSelection(root.hasSel && root.selStart < timeMenu.time ? root.selStart : timeMenu.time - 60000, timeMenu.time)
                    }
                    MenuItem {
                        visible: root.hasSel; height: visible ? implicitHeight : 0
                        text: "Save selection (" + root.fmtLength(root.selEnd - root.selStart) + ")…"
                        enabled: Api.canExport
                        onTriggered: root.saveRequested(root.selStart, root.selEnd)
                    }
                    MenuItem {
                        visible: root.hasSel; height: visible ? implicitHeight : 0
                        text: "Play selection"
                        onTriggered: { root.follow = true; Clock.seek(root.selStart) }
                    }
                    MenuItem {
                        visible: root.hasSel; height: visible ? implicitHeight : 0
                        text: "Zoom to selection"
                        onTriggered: { var l = root.selEnd - root.selStart; root.zoomTo(l * 1.2, root.selStart - l * 0.1, 0) }
                    }
                    MenuItem {
                        visible: root.hasSel; height: visible ? implicitHeight : 0
                        text: "Clear selection"
                        onTriggered: root.clearSelection()
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: "Export clip from here…"
                        enabled: root.cameraId > 0 && Api.canExport
                        onTriggered: root.exportRequested(timeMenu.time, timeMenu.time + 60000)
                    }
                }

                // What is selected, with Save and clear (top right, over the day row).
                Rectangle {
                    id: selBar
                    visible: root.hasSel
                    z: 15
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    y: 0
                    height: 15
                    width: selRow.implicitWidth + 12
                    radius: 3
                    color: "#1f3a52"
                    border.color: "#2f6aa0"
                    Row {
                        id: selRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.fmtLength(root.selEnd - root.selStart) + " selected"
                            color: "#cfe6ff"; font.pixelSize: 10
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: Api.canExport
                            text: "Save…"
                            color: saveMa.containsMouse ? "white" : "#7cc4ff"
                            font.pixelSize: 10; font.weight: Font.DemiBold
                            MouseArea { id: saveMa; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveRequested(root.selStart, root.selEnd) }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "✕"
                            color: clrMa.containsMouse ? "white" : "#8b95a1"
                            font.pixelSize: 10
                            MouseArea { id: clrMa; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.clearSelection() }
                        }
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

        // ---------- Right: time and date, player buttons, speed / sync / zoom / live ----------
        ColumnLayout {
            spacing: 3
            Layout.preferredWidth: 300
            Layout.fillWidth: false // nested layouts with fill-width children are greedy by default
            Layout.alignment: Qt.AlignVCenter
            // What you are watching, and which camera.
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Text {
                    text: Clock.live ? "Live"
                        : Clock.reverse ? "Rewind " + Clock.speed + "×"
                        : !Clock.playing ? "Paused"
                        : "Playback" + (Clock.speed > 1 ? " " + Clock.speed + "×" : "")
                    color: Clock.live ? Theme.live : "#9cc8ff"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    visible: root.searchCells !== ""
                    implicitWidth: srch.implicitWidth + 12
                    implicitHeight: 16
                    radius: 8
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
                    Layout.maximumWidth: 140
                    text: root.cameraName.length > 0 ? root.cameraName : "No camera selected"
                    color: Theme.textDim
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }
            // Time of the playhead, large, and the date. Click either to pick a day.
            AbstractButton {
                id: dateBtn
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: dateRow.implicitWidth + 14
                implicitHeight: 28
                hoverEnabled: true
                onClicked: calendar.opened ? calendar.close() : calendar.open()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "Go to a date"
                background: Rectangle {
                    radius: 5
                    color: dateBtn.down || calendar.opened ? Theme.raised : dateBtn.hovered ? Theme.panelAlt : "transparent"
                    border.color: dateBtn.hovered || calendar.opened ? Theme.borderStrong : "transparent"
                }
                contentItem: Item {
                    Row {
                        id: dateRow
                        anchors.centerIn: parent
                        spacing: 9
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: new Date(root.pos).toLocaleTimeString(Qt.locale(), "HH:mm:ss")
                            color: Clock.live ? Theme.text : "#9cc8ff"
                            font.pixelSize: 19
                            font.family: Theme.mono
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: dateInner.implicitWidth + 12
                            height: 20
                            radius: 4
                            color: "transparent"
                            border.color: Theme.borderStrong
                            Row {
                                id: dateInner
                                anchors.centerIn: parent
                                spacing: 5
                                TileIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    kind: "calendar"; width: 11; height: 11
                                    color: dateBtn.hovered || calendar.opened ? Theme.accent : Theme.textDim
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: new Date(root.pos).toLocaleDateString(Qt.locale(), "ddd d MMM yyyy")
                                    color: Theme.text
                                    font.pixelSize: 11
                                }
                            }
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
            // Player: previous event, −30 s, previous frame, play / pause, next frame, +30 s, next event.
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 2
                IconButton { iconKind: "prev"; iconSize: 11; size: 26; tip: "Previous motion or bookmark"; enabled: Api.canPlayback; onClicked: root.jumpEvent(-1) }
                IconButton { text: "−30"; size: 26; tip: "Back 30 seconds (← for 10 s)"; enabled: Api.canPlayback; onClicked: { root.follow = true; Clock.step(-30000) } }
                IconButton { text: "‹|"; size: 26; tip: "Previous frame (,)"; enabled: Api.canPlayback; onClicked: root.stepFrame(-1) }
                AbstractButton {
                    id: playBtn
                    implicitWidth: 34
                    implicitHeight: 34
                    enabled: Api.canPlayback
                    hoverEnabled: true
                    focusPolicy: Qt.NoFocus
                    onClicked: Clock.togglePlay()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: Clock.playing ? "Pause (Space)" : "Play (Space)"
                    background: Rectangle {
                        radius: width / 2
                        color: !playBtn.enabled ? Theme.raised : playBtn.down ? Qt.darker(Theme.accent, 1.2)
                             : playBtn.hovered ? Qt.lighter(Theme.accent, 1.15) : Theme.accent
                    }
                    contentItem: Item {
                        TileIcon {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: Clock.playing ? 0 : 1
                            kind: Clock.playing ? "pause" : "play"
                            width: 14; height: 14
                            color: "white"
                        }
                    }
                }
                IconButton { text: "|›"; size: 26; tip: "Next frame (.)"; enabled: Api.canPlayback && !Clock.live; onClicked: root.stepFrame(1) }
                IconButton { text: "+30"; size: 26; tip: "Forward 30 seconds (→ for 10 s)"; enabled: Api.canPlayback && !Clock.live; onClicked: { root.follow = true; Clock.step(30000) } }
                IconButton { iconKind: "next"; iconSize: 11; size: 26; tip: "Next motion or bookmark"; enabled: !Clock.live && Api.canPlayback; onClicked: root.jumpEvent(1) }
            }
            // Speed, rewind, sync · zoom out, view length, zoom in · live.
            RowLayout {
                Layout.fillWidth: true
                spacing: 2
                IconButton {
                    text: (Clock.live ? 1 : Clock.speed) + "×"; size: 22
                    tip: "Playback speed: click for faster (1×, 2×, 4×, 8×, 16×)"
                    enabled: !Clock.live
                    active: !Clock.live && Clock.speed > 1
                    onClicked: { var v = [1, 2, 4, 8, 16]; Clock.speed = v[(v.indexOf(Clock.speed) + 1) % v.length] }
                }
                IconButton {
                    text: "◂◂"; size: 22
                    tip: "Play backwards at the chosen speed"
                    enabled: Api.canPlayback
                    active: Clock.reverse
                    onClicked: { root.follow = true; Clock.reverse = !Clock.reverse }
                }
                IconButton {
                    text: "Sync"; size: 22
                    active: root.sync
                    tip: root.sync ? "Sync is on: every camera on the layout plays the same moment. Click to play back only the selected camera."
                                   : "Sync is off: only the selected camera plays back, the others stay live. Click to sync all cameras."
                    onClicked: root.syncToggled()
                }
                Item { Layout.fillWidth: true }
                IconButton { text: "−"; size: 22; tip: "Zoom out (or scroll the mouse wheel on the timeline)"; onClicked: root.zoomTo(root.span * 2, root.pos, 0.5) }
                IconButton {
                    id: spanBtn
                    size: 22
                    text: {
                        var m = root.span / 60000
                        return (m < 60 ? Math.round(m) + "m" : m < 1440 ? Math.round(m / 60) + "h" : Math.round(m / 1440) + "d") + " ▾"
                    }
                    tip: "Show 1 hour, 1 day, 1 week, or the whole day"
                    onClicked: spanMenu.opened ? spanMenu.close() : spanMenu.popup(spanBtn, 0, -spanMenu.implicitHeight - 4)
                    Menu {
                        id: spanMenu
                        MenuItem { text: "1 hour"; onTriggered: root.zoomTo(3600000, root.pos, 0.75) }
                        MenuItem { text: "1 day"; onTriggered: root.zoomTo(86400000, root.pos, 0.75) }
                        MenuItem { text: "1 week"; onTriggered: root.zoomTo(7 * 86400000, root.pos, 0.85) }
                        MenuItem {
                            text: "Whole day"
                            onTriggered: {
                                var p = new Date(root.pos), a = new Date(p.getFullYear(), p.getMonth(), p.getDate())
                                root.zoomTo(new Date(p.getFullYear(), p.getMonth(), p.getDate() + 1).getTime() - a.getTime(), a.getTime(), 0)
                            }
                        }
                    }
                }
                IconButton { text: "+"; size: 22; tip: "Zoom in on the playhead"; onClicked: root.zoomTo(root.span / 2, root.pos, 0.5) }
                Item { implicitWidth: 4 }
                // Live: a red badge while live; a button back to live while playing back.
                AbstractButton {
                    id: goLive
                    implicitWidth: liveTxt.implicitWidth + 16
                    implicitHeight: 22
                    hoverEnabled: true
                    onClicked: { root.follow = true; Clock.goLive() }
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: Clock.live ? "Showing live video. Click the timeline to play back recordings." : "Back to live video (L)"
                    background: Rectangle {
                        radius: 4
                        color: Clock.live ? Theme.live : goLive.hovered ? "#33ff4757" : "transparent"
                        border.color: Theme.live
                    }
                    contentItem: Text {
                        id: liveTxt
                        text: Clock.live ? "● LIVE" : "Go live"
                        color: Clock.live ? "white" : Theme.live
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
