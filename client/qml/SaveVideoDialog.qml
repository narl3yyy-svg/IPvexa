import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Save the selected part of the timeline: just one camera, every synced camera as
// separate files (both copied as recorded, quick), or every synced camera in one
// grid video (re-encoded on the server, takes about as long as the clip).
AppDialog {
    id: root
    property int cameraId: 0
    property string cameraName: ""
    property var cameras: []         // [{id, name}] of the layout (synced cameras)
    property real from: 0
    property real to: 0
    property string mode: "one"      // one | each | grid
    property bool running: false
    property bool cancelled: false
    property real received: 0
    property int doneCount: 0
    property string errorText: ""
    property string savedPath: ""    // a file, or the folder for "each"
    readonly property real length: to - from
    readonly property bool tooLong: length > 2 * 3600000

    title: "Save video"
    subtitle: new Date(from).toLocaleString(Qt.locale(), "ddd d MMM yyyy  HH:mm:ss") + " – "
              + new Date(to).toLocaleTimeString(Qt.locale(), "HH:mm:ss") + "  ·  " + fmtLength(length)
    width: 520
    closePolicy: running ? Popup.NoAutoClose : Popup.CloseOnEscape

    function fmtLength(ms) {
        var s = Math.round(ms / 1000), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
        s = s % 60
        return h > 0 ? h + " h " + m + " min" : m > 0 ? m + " min" + (s > 0 ? " " + s + " s" : "") : s + " s"
    }
    function openFor(camId, camName, cams, a, b, all) {
        cameraId = camId; cameraName = camName; from = a; to = b
        cameras = cams
        mode = all && cams.length > 1 ? "each" : "one"
        errorText = ""; savedPath = ""; received = 0; doneCount = 0
        open()
    }
    function safe(s) { return s.replace(/[^A-Za-z0-9._-]+/g, "_") }
    function stamp() { return new Date(from).toLocaleString(Qt.locale(), "yyyy-MM-dd_HH-mm-ss") }
    function stream() { return quality.currentIndex === 1 ? "sub" : "main" }
    function exportPath(id) { return "/api/cameras/" + id + "/export?from=" + Math.round(from) + "&to=" + Math.round(to) + "&stream=" + stream() }

    function run() {
        errorText = ""; savedPath = ""; received = 0; doneCount = 0; cancelled = false
        if (tooLong) { errorText = "Select 2 hours or less."; return }
        running = true
        if (mode === "one") {
            Api.download(exportPath(cameraId), Api.videosDir() + "/" + safe(cameraName) + "_" + stamp() + ".mp4", function (err, file) {
                running = false
                if (err) errorText = err; else savedPath = file
            })
        } else if (mode === "grid") {
            var ids = cameras.map(function (c) { return c.id }).join(",")
            Api.download("/api/export/grid?cameras=" + ids + "&from=" + Math.round(from) + "&to=" + Math.round(to) + "&stream=" + stream(),
                         Api.videosDir() + "/IPvexa_" + cameras.length + "_cameras_" + stamp() + ".mp4", function (err, file) {
                running = false
                if (err) errorText = err; else savedPath = file
            })
        } else {
            // One file per camera, one after another, into a folder of their own.
            var dir = Api.videosDir() + "/IPvexa_" + stamp()
            var failed = []
            var next = function (i) {
                if (root.cancelled || i >= root.cameras.length) {
                    root.running = false
                    if (root.cancelled) root.errorText = "Cancelled"
                    else if (failed.length === root.cameras.length) root.errorText = "Nothing saved: " + failed.join("; ")
                    else {
                        root.savedPath = dir
                        if (failed.length > 0) root.errorText = "Skipped " + failed.join("; ")
                    }
                    return
                }
                var c = root.cameras[i]
                root.received = 0
                Api.download(root.exportPath(c.id), dir + "/" + root.safe(c.name) + "_" + root.stamp() + ".mp4", function (err) {
                    if (err && !root.cancelled) failed.push(c.name + " (" + err + ")")
                    root.doneCount = i + 1
                    next(i + 1)
                })
            }
            next(0)
        }
    }
    function cancel() { cancelled = true; Api.cancelDownload() }
    Connections {
        target: Api
        function onDownloadProgress(got, total) { if (root.running) root.received = got }
    }

    component Choice: Rectangle {
        id: ch
        property string value
        property string label
        property string detail
        readonly property bool on: root.mode === value
        Layout.fillWidth: true
        implicitHeight: col.implicitHeight + 16
        radius: 6
        color: on ? "#17283a" : ma.containsMouse ? Theme.panelAlt : "transparent"
        border.color: on ? "#2f6aa0" : Theme.border
        Rectangle {
            id: dot
            x: 10; y: 11
            width: 14; height: 14; radius: 7
            color: "transparent"
            border.width: 2
            border.color: ch.on ? Theme.accent : Theme.textFaint
            Rectangle { anchors.centerIn: parent; width: 6; height: 6; radius: 3; color: Theme.accent; visible: ch.on }
        }
        Column {
            id: col
            anchors.left: dot.right; anchors.leftMargin: 10
            anchors.right: parent.right; anchors.rightMargin: 10
            y: 8
            spacing: 2
            Text { width: parent.width; text: ch.label; color: Theme.text; font.pixelSize: 13; elide: Text.ElideRight }
            Text { width: parent.width; text: ch.detail; color: Theme.textDim; font.pixelSize: 11; wrapMode: Text.Wrap }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.mode = ch.value }
    }

    contentItem: ColumnLayout {
        spacing: 8
        enabled: !root.running
        Choice {
            value: "one"
            label: "Just " + root.cameraName
            detail: "One MP4 file in the original quality. Ready in seconds."
        }
        Choice {
            visible: root.cameras.length > 1
            value: "each"
            label: "All " + root.cameras.length + " synced cameras, separate files"
            detail: "A folder with one MP4 per camera, in the original quality. Ready in seconds."
        }
        Choice {
            visible: root.cameras.length > 1
            value: "grid"
            label: "All " + root.cameras.length + " synced cameras in one video"
            detail: "A grid with each camera's name and the date and time. Made on the server, so it takes about as long as the clip ("
                    + root.fmtLength(root.length) + ")."
        }
        GridLayout {
            Layout.topMargin: 4
            columns: 2
            columnSpacing: 12
            rowSpacing: 8
            FieldLabel { text: "Quality" }
            ComboBox { id: quality; Layout.preferredWidth: 240; model: ["High (main stream)", "Low (substream, if recorded)"] }
            FieldLabel { text: "Save to" }
            Text {
                Layout.fillWidth: true
                text: Api.videosDir()
                color: Theme.textDim
                font.pixelSize: 12
                font.family: Theme.mono
                elide: Text.ElideMiddle
            }
        }
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            wrapMode: Text.WrapAnywhere
            font.pixelSize: 12
            color: root.errorText !== "" && root.savedPath === "" ? Theme.live : root.savedPath !== "" ? Theme.online : Theme.textDim
            text: root.tooLong && !root.running ? "Select 2 hours or less to save it."
                : root.running ? (root.mode === "each" ? "Saving camera " + Math.min(root.doneCount + 1, root.cameras.length) + " of " + root.cameras.length + "…  "
                                  : root.mode === "grid" ? "Making the grid video…  " : "Saving…  ")
                                 + (root.received / 1048576).toFixed(1) + " MB"
                : root.savedPath !== "" ? "✓ Saved " + root.savedPath + (root.errorText !== "" ? "\n" + root.errorText : "")
                : root.errorText
        }
    }

    footer: Item {
        implicitHeight: 64
        Rectangle { width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 8
            AppButton {
                visible: root.savedPath !== "" && !root.running
                text: "Open folder"
                onClicked: {
                    var dir = root.mode === "each" ? root.savedPath : root.savedPath.substring(0, root.savedPath.lastIndexOf("/"))
                    Qt.openUrlExternally("file://" + (dir.charAt(0) === "/" ? "" : "/") + dir)
                }
            }
            Item { Layout.fillWidth: true }
            AppButton {
                text: root.running ? "Cancel" : "Close"
                onClicked: root.running ? root.cancel() : root.close()
            }
            AppButton {
                visible: !root.running
                enabled: !root.tooLong
                text: root.savedPath !== "" ? "Save again" : "Save"
                kind: "primary"
                onClicked: root.run()
            }
        }
    }
}
