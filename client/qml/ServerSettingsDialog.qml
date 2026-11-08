import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Server-wide settings: storage limits and how long events are kept.
AppDialog {
    id: root
    title: "Server settings"
    subtitle: "Storage and housekeeping for this server"
    width: 560
    property var info: null
    property string status: ""
    property bool statusError: false

    function fmtBytes(b) {
        if (!b) return "0 B"
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0
        while (b >= 1024 && i < u.length - 1) { b /= 1024; i++ }
        return b.toFixed(b >= 100 || i === 0 ? 0 : 1) + " " + u[i]
    }
    onOpened: {
        status = ""
        Api.call("GET", "/api/settings", null, function (err, d) {
            if (err) { status = err; statusError = true; return }
            info = d
            minFree.value = Math.round(d.min_free_pct)
            capOn.checked = d.max_storage_gb > 0
            cap.value = d.max_storage_gb > 0 ? Math.round(d.max_storage_gb) : Math.max(1, Math.round((d.disk.total || 0) / 1073741824 * 0.8))
            eventDays.value = d.event_days
        })
    }
    function save() {
        Api.call("PUT", "/api/settings", { min_free_pct: minFree.value, max_storage_gb: capOn.checked ? cap.value : 0, event_days: eventDays.value },
                 function (err, d) {
            statusError = !!err
            status = err ? err : "✓ Saved. Limits apply within 5 minutes."
            if (!err) info = d
        })
    }

    contentItem: GridLayout {
        columns: 2
        columnSpacing: 12
        rowSpacing: 12

        FieldLabel { text: "Recordings" }
        Text {
            Layout.fillWidth: true
            text: root.info ? root.info.recordings_dir : "…"
            color: Theme.text; font.family: Theme.mono; font.pixelSize: 12
            elide: Text.ElideMiddle
        }
        FieldLabel { text: "Disk" }
        Text {
            Layout.fillWidth: true
            text: root.info && root.info.disk && root.info.disk.total
                  ? root.fmtBytes(root.info.disk.total - root.info.disk.free) + " used of " + root.fmtBytes(root.info.disk.total)
                    + "  ·  footage " + root.fmtBytes(root.info.footage_bytes) : "…"
            color: Theme.textDim; font.pixelSize: 12
        }

        Rectangle { Layout.columnSpan: 2; Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

        FieldLabel { text: "Keep free" }
        RowLayout {
            SpinBox { id: minFree; from: 1; to: 50; value: 10; editable: true; Layout.preferredWidth: 110 }
            Text { text: "% of the disk. The oldest footage is deleted to keep this much free."; color: Theme.textDim; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap }
        }
        FieldLabel { text: "Storage limit" }
        RowLayout {
            Switch { id: capOn; text: checked ? "" : "No limit" }
            SpinBox { id: cap; visible: capOn.checked; from: 1; to: 1000000; value: 500; editable: true; Layout.preferredWidth: 130 }
            Text { visible: capOn.checked; text: "GB for all cameras together"; color: Theme.textDim; font.pixelSize: 12 }
        }
        FieldLabel { text: "Motion events" }
        RowLayout {
            SpinBox { id: eventDays; from: 1; to: 3650; value: 90; editable: true; Layout.preferredWidth: 110 }
            Text { text: "days (bookmarks are kept until deleted)"; color: Theme.textDim; font.pixelSize: 12 }
        }
        Text {
            Layout.columnSpan: 2
            Layout.fillWidth: true
            visible: root.status !== ""
            text: root.status
            color: root.statusError ? Theme.live : Theme.online
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
    }
    footer: Item {
        implicitHeight: 64
        Rectangle { width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 8
            Text { text: root.info ? "Server " + root.info.version : ""; color: Theme.textFaint; font.pixelSize: 11 }
            Item { Layout.fillWidth: true }
            AppButton { text: "Close"; onClicked: root.close() }
            AppButton { text: "Save"; kind: "primary"; enabled: !!root.info; onClicked: root.save() }
        }
    }
}
