import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Export a clip of recorded video to an MP4 file (original quality, no re-encoding).
AppDialog {
    id: root
    property int cameraId: 0
    property string cameraName: ""
    property real start: 0
    property bool running: false
    property real received: 0
    property string errorText: ""
    property string savedPath: ""

    title: "Export clip"
    subtitle: cameraName
    width: 500
    closePolicy: running ? Popup.NoAutoClose : Popup.CloseOnEscape

    function openAt(camId, camName, from, to) {
        cameraId = camId; cameraName = camName; start = from
        minutes.value = Math.max(1, Math.round((to - from) / 60000))
        quality.currentIndex = 0
        errorText = ""; savedPath = ""; received = 0
        startField.text = new Date(from).toLocaleString(Qt.locale(), "yyyy-MM-dd HH:mm:ss")
        open()
    }
    function parseStart() {
        var m = startField.text.trim().match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/)
        if (!m) return NaN
        return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)).getTime()
    }
    function fileName(from) {
        var safe = cameraName.replace(/[^A-Za-z0-9._-]+/g, "_")
        return safe + "_" + new Date(from).toLocaleString(Qt.locale(), "yyyy-MM-dd_HH-mm-ss") + ".mp4"
    }
    function run() {
        errorText = ""; savedPath = ""
        var from = parseStart()
        if (isNaN(from)) { errorText = "Write the start as YYYY-MM-DD HH:MM:SS."; return }
        var to = from + minutes.value * 60000
        var path = Api.videosDir() + "/" + fileName(from)
        running = true; received = 0
        Api.download("/api/cameras/" + cameraId + "/export?from=" + from + "&to=" + to + "&stream=" + (quality.currentIndex === 1 ? "sub" : "main"),
                     path, function (err, file) {
            running = false
            if (err) errorText = err
            else savedPath = file
        })
    }
    Connections {
        target: Api
        function onDownloadProgress(got, total) { if (root.running) root.received = got }
    }

    contentItem: GridLayout {
        columns: 2
        columnSpacing: 12
        rowSpacing: 10
        enabled: !root.running
        FieldLabel { text: "Start" }
        TextField { id: startField; Layout.fillWidth: true; font.family: Theme.mono; placeholderText: "YYYY-MM-DD HH:MM:SS" }
        FieldLabel { text: "Length" }
        RowLayout {
            SpinBox { id: minutes; from: 1; to: 120; value: 1; editable: true; Layout.preferredWidth: 110 }
            Text { text: "minutes (up to 2 hours)"; color: Theme.textDim; font.pixelSize: 12 }
        }
        FieldLabel { text: "Quality" }
        ComboBox { id: quality; Layout.preferredWidth: 220; model: ["High (main stream)", "Low (substream, if recorded)"] }
        FieldLabel { text: "Save to" }
        Text {
            Layout.fillWidth: true
            text: Api.videosDir()
            color: Theme.textDim
            font.pixelSize: 12
            font.family: Theme.mono
            elide: Text.ElideMiddle
        }
        Item { implicitWidth: 1; implicitHeight: 1; visible: status.visible }
        Text {
            id: status
            Layout.fillWidth: true
            visible: text !== ""
            wrapMode: Text.WrapAnywhere
            font.pixelSize: 12
            color: root.errorText !== "" ? Theme.live : root.savedPath !== "" ? Theme.online : Theme.textDim
            text: root.errorText !== "" ? root.errorText
                : root.savedPath !== "" ? "✓ Saved " + root.savedPath
                : root.running ? "Exporting…  " + (root.received / 1048576).toFixed(1) + " MB" : ""
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
            Item { Layout.fillWidth: true }
            AppButton {
                text: root.running ? "Cancel export" : "Close"
                onClicked: root.running ? Api.cancelDownload() : root.close()
            }
            AppButton {
                visible: !root.running
                text: root.savedPath !== "" ? "Export again" : "Export"
                kind: "primary"
                onClicked: root.run()
            }
        }
    }
}
