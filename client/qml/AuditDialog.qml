import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Who did what, and when: sign-ins, camera and user changes, exports.
AppDialog {
    id: root
    title: "Audit log"
    subtitle: "The last 500 actions on this server (kept for a year)"
    width: Math.min(760, parent ? parent.width - 40 : 760)
    height: Math.min(560, parent ? parent.height - 40 : 560)
    property var entries: []
    property string errorText: ""
    property string filter: ""

    readonly property var labels: ({
        "login": "Signed in", "camera.create": "Added camera", "camera.update": "Changed camera", "camera.delete": "Deleted camera",
        "user.create": "Added user", "user.update": "Changed user", "user.delete": "Deleted user",
        "password.change": "Changed own password", "export": "Exported video", "notifications.update": "Changed notifications"
    })

    onOpened: reload()
    function reload() {
        Api.call("GET", "/api/audit?limit=500", null, function (err, list) {
            errorText = err || ""
            entries = list || []
        })
    }
    readonly property var shown: entries.filter(function (e) {
        if (filter === "") return true
        var f = filter.toLowerCase()
        return (e.username + " " + e.action + " " + e.detail + " " + (labels[e.action] || "")).toLowerCase().indexOf(f) >= 0
    })

    contentItem: ColumnLayout {
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            TextField { id: search; Layout.fillWidth: true; placeholderText: "Filter by user, action or detail"; onTextChanged: root.filter = text.trim() }
            AppButton { text: "Refresh"; onClicked: root.reload() }
        }
        Text { visible: root.errorText !== ""; text: root.errorText; color: Theme.live; font.pixelSize: 12 }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#0e1215"
            radius: 6
            border.color: Theme.border
            ListView {
                id: list
                anchors.fill: parent
                anchors.margins: 1
                clip: true
                model: root.shown
                ScrollBar.vertical: ScrollBar {}
                header: Rectangle {
                    width: list.width; height: 30; color: Theme.panelAlt
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 12
                        Text { text: "TIME"; Layout.preferredWidth: 150; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold }
                        Text { text: "USER"; Layout.preferredWidth: 110; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold }
                        Text { text: "ACTION"; Layout.preferredWidth: 150; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold }
                        Text { text: "DETAIL"; Layout.fillWidth: true; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold }
                    }
                }
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: list.width; height: 28
                    color: index % 2 ? "#12171a" : "transparent"
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 12
                        Text { text: new Date(modelData.at).toLocaleString(Qt.locale(), "yyyy-MM-dd HH:mm:ss"); Layout.preferredWidth: 150; color: Theme.textDim; font.pixelSize: 11; font.family: Theme.mono }
                        Text { text: modelData.username || "—"; Layout.preferredWidth: 110; color: Theme.text; font.pixelSize: 12; elide: Text.ElideRight }
                        Text { text: root.labels[modelData.action] || modelData.action; Layout.preferredWidth: 150; color: Theme.text; font.pixelSize: 12; elide: Text.ElideRight }
                        Text { text: modelData.detail; Layout.fillWidth: true; color: Theme.textDim; font.pixelSize: 12; elide: Text.ElideRight }
                    }
                }
                Text {
                    anchors.centerIn: parent
                    visible: list.count === 0
                    text: "Nothing logged yet"
                    color: Theme.textFaint
                }
            }
        }
    }
    footer: Item {
        implicitHeight: 64
        Rectangle { width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20
            Item { Layout.fillWidth: true }
            AppButton { text: "Close"; onClicked: root.close() }
        }
    }
}
