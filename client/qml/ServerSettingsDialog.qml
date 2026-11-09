import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Server-wide settings: where recordings go, how long they are kept, storage
// limits and housekeeping.
AppDialog {
    id: root
    title: "Server settings"
    subtitle: "Recording and storage for this server"
    width: 620
    property var info: null
    property string status: ""
    property bool statusError: false
    property bool saving: false

    function fmtBytes(b) {
        if (!b) return "0 B"
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0
        while (b >= 1024 && i < u.length - 1) { b /= 1024; i++ }
        return b.toFixed(b >= 100 || i === 0 ? 0 : 1) + " " + u[i]
    }
    function load(d) {
        info = d
        folder.text = d.record_path || ""
        retention.value = d.retention_days || 30
        applyAll.checked = false
        pad.value = d.motion_pad_sec || 10
        minFree.value = Math.round(d.min_free_pct)
        capOn.checked = d.max_storage_gb > 0
        cap.value = d.max_storage_gb > 0 ? Math.round(d.max_storage_gb) : Math.max(1, Math.round((d.disk.total || 0) / 1073741824 * 0.8))
        eventDays.value = d.event_days
    }
    onOpened: {
        status = ""
        Api.call("GET", "/api/settings", null, function (err, d) {
            if (err) { status = err; statusError = true; return }
            load(d)
        })
    }
    function save() {
        saving = true
        status = folder.text.trim() !== (info.record_path || "") ? "Moving new recordings… cameras restart for a moment." : ""
        statusError = false
        Api.call("PUT", "/api/settings", {
            record_path: folder.text.trim(),
            retention_days: retention.value,
            apply_retention_to_all: applyAll.checked,
            motion_pad_sec: pad.value,
            min_free_pct: minFree.value,
            max_storage_gb: capOn.checked ? cap.value : 0,
            event_days: eventDays.value
        }, function (err, d) {
            saving = false
            statusError = !!err
            status = err ? err : "✓ Saved. Storage limits apply within 5 minutes."
            if (!err) { load(d); Api.refreshCameras() }
        })
    }

    contentItem: ColumnLayout {
        spacing: 14

        // ---------------- Recording ----------------
        Text { text: "RECORDING"; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1 }
        GridLayout {
            columns: 2
            columnSpacing: 12
            rowSpacing: 10
            Layout.fillWidth: true

            FieldLabel { text: "Folder" }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: folder
                    Layout.fillWidth: true
                    placeholderText: root.info ? root.info.default_recordings_dir + "  (default)" : ""
                    font.family: Theme.mono
                    selectByMouse: true
                }
                AppButton {
                    text: "Default"
                    enabled: folder.text !== ""
                    onClicked: folder.text = ""
                }
            }
            Item { implicitWidth: 1; implicitHeight: 1 }
            Text {
                Layout.fillWidth: true
                Layout.preferredWidth: 100
                text: "New recordings go here; footage already recorded stays where it is and still plays. For a second disk, use a folder under /mnt, /media, /srv or /data that belongs to the ipvexa user, e.g.  sudo mkdir -p /mnt/disk2/ipvexa && sudo chown ipvexa:ipvexa /mnt/disk2/ipvexa"
                color: Theme.textFaint; font.pixelSize: 11; wrapMode: Text.Wrap
            }

            FieldLabel { text: "Keep footage" }
            RowLayout {
                spacing: 8
                SpinBox { id: retention; from: 1; to: 3650; value: 30; editable: true; Layout.preferredWidth: 110 }
                Text { text: "days for new cameras"; color: Theme.textDim; font.pixelSize: 12 }
                CheckBox { id: applyAll; text: "Apply to all cameras now" }
            }
            Item { implicitWidth: 1; implicitHeight: 1 }
            Text {
                Layout.fillWidth: true
                Layout.preferredWidth: 100
                text: "Each camera can also keep its own number of days (camera settings › Recording)."
                color: Theme.textFaint; font.pixelSize: 11; wrapMode: Text.Wrap
            }

            FieldLabel { text: "Motion buffer" }
            RowLayout {
                spacing: 8
                SpinBox { id: pad; from: 0; to: 300; value: 10; editable: true; Layout.preferredWidth: 110 }
                Text {
                    Layout.fillWidth: true
                    text: "seconds kept before and after each motion event (cameras recording only on motion)"
                    color: Theme.textDim; font.pixelSize: 12; wrapMode: Text.Wrap
                }
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

        // ---------------- Storage ----------------
        Text { text: "STORAGE"; color: Theme.textFaint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1 }
        GridLayout {
            columns: 2
            columnSpacing: 12
            rowSpacing: 10
            Layout.fillWidth: true

            FieldLabel { text: "Disk" }
            Text {
                Layout.fillWidth: true
                text: root.info && root.info.disk && root.info.disk.total
                      ? root.fmtBytes(root.info.disk.total - root.info.disk.free) + " used of " + root.fmtBytes(root.info.disk.total)
                        + "  ·  footage " + root.fmtBytes(root.info.footage_bytes) : "…"
                color: Theme.textDim; font.pixelSize: 12
            }
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
        }
        Text {
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
            AppButton { text: root.saving ? "Saving…" : "Save"; kind: "primary"; enabled: !!root.info && !root.saving; onClicked: root.save() }
        }
    }
}
