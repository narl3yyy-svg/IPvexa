import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Add a bookmark (a marked moment with a note) to a camera's recording.
AppDialog {
    id: root
    property int cameraId: 0
    property string cameraName: ""
    property real time: 0
    property string errorText: ""
    signal added()

    title: "Add bookmark"
    subtitle: cameraName + "  ·  " + new Date(time).toLocaleString(Qt.locale(), "ddd d MMM yyyy  HH:mm:ss")
    width: 460

    function openAt(camId, camName, t) {
        cameraId = camId; cameraName = camName; time = t
        note.text = ""; errorText = ""; dur.value = 30
        open()
        note.forceActiveFocus()
    }
    function save() {
        Api.call("POST", "/api/cameras/" + cameraId + "/bookmarks",
                 { start: Math.round(time), end: Math.round(time + dur.value * 1000), note: note.text }, function (err) {
            if (err) { root.errorText = err; return }
            root.added()
            root.close()
        })
    }

    contentItem: GridLayout {
        columns: 2
        columnSpacing: 12
        rowSpacing: 10
        FieldLabel { text: "Note" }
        TextField { id: note; Layout.fillWidth: true; placeholderText: "e.g. Package delivered"; onAccepted: root.save() }
        FieldLabel { text: "Length" }
        RowLayout {
            SpinBox { id: dur; from: 1; to: 3600; value: 30; editable: true; Layout.preferredWidth: 110 }
            Text { text: "seconds"; color: Theme.textDim; font.pixelSize: 12 }
        }
        Text {
            Layout.columnSpan: 2
            visible: root.errorText !== ""
            text: root.errorText
            color: Theme.live
            font.pixelSize: 12
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
            AppButton { text: "Cancel"; onClicked: root.close() }
            AppButton { text: "Add bookmark"; kind: "primary"; onClicked: root.save() }
        }
    }
}
