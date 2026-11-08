import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Playback controls + zoomable timeline showing recorded footage for the selected camera.
// Wheel = zoom around the cursor, drag = pan, click = jump to that moment.
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
    readonly property real span: viewEnd - viewStart
    readonly property real pos: Clock.position

    function fetch() {
        if (cameraId <= 0) { chunks = []; canvas.requestPaint(); return }
        var pad = span * 0.5
        var cam = cameraId
        Api.fetchTimeline(cam, Math.floor(viewStart - pad), Math.ceil(viewEnd + pad), function (err, data) {
            if (!err && data && cam === root.cameraId) {
                root.chunks = data.chunks || []
                canvas.requestPaint()
            }
        })
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
                IconButton { glyph: "⏪"; tip: "Back 10 s (←)"; onClicked: Clock.step(-10000) }
                IconButton {
                    glyph: Clock.playing ? "⏸" : "▶"
                    size: 36
                    tip: "Play / pause (Space)"
                    onClicked: Clock.togglePlay()
                }
                IconButton { glyph: "⏩"; tip: "Forward 10 s (→)"; enabled: !Clock.live; onClicked: Clock.step(10000) }
            }
            RowLayout {
                spacing: 2
                Repeater {
                    model: [1, 2, 4, 8, 16]
                    IconButton {
                        text: modelData + "×"
                        size: 20
                        enabled: !Clock.live
                        active: !Clock.live && Clock.speed === modelData
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

                    onPressed: (m) => { pressX = m.x; pressStart = root.viewStart; moved = false }
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
                        text: canvas.hoverX >= 0 ? new Date(canvas.timeAt(canvas.hoverX)).toLocaleString(Qt.locale(), "ddd d MMM HH:mm:ss") : ""
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
            Text {
                Layout.fillWidth: true
                text: root.cameraName.length > 0 ? root.cameraName : "No camera selected"
                color: Theme.textDim
                font.pixelSize: 11
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
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
                Rectangle {
                    width: liveTxt.implicitWidth + 20
                    height: 22
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
