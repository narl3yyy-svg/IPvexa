import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Month calendar for jumping to a day. With a camera set, it marks the days that
// have recordings (blue bar; red when there was motion) and only those can be
// picked. Emits picked(day at local midnight, start of its first footage or 0).
Popup {
    id: root
    property date selected: new Date()
    property int month: selected.getMonth()
    property int year: selected.getFullYear()
    property int cameraId: 0
    // Per day of the shown month (index = day - 1): {rec_ms, first, motion}.
    property var days: []
    property bool loaded: false
    signal picked(date day, real firstFootage)

    width: 268
    padding: 12
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onAboutToShow: { month = selected.getMonth(); year = selected.getFullYear(); load() }
    onMonthChanged: if (opened) load()
    onYearChanged: if (opened) load()

    background: Rectangle { color: Theme.panel; radius: 8; border.color: Theme.borderStrong }

    function shift(n) {
        var m = month + n
        year += Math.floor(m / 12)
        month = ((m % 12) + 12) % 12
    }

    // Ask the server which days of the month have footage (local midnights as bounds).
    property int gen: 0
    function load() {
        var g = ++gen
        days = []
        loaded = false
        if (cameraId <= 0 || !Api.canPlayback) return
        var n = new Date(year, month + 1, 0).getDate()
        var b = []
        for (var d = 1; d <= n + 1; d++) b.push(new Date(year, month, d).getTime())
        Api.call("GET", "/api/cameras/" + cameraId + "/days?bounds=" + b.join(","), null, function (err, res) {
            if (g !== root.gen) return
            if (!err && res && res.days) { root.days = res.days; root.loaded = true }
        })
    }
    function info(date) {
        if (!loaded || date.getMonth() !== month || date.getFullYear() !== year) return null
        return days[date.getDate() - 1] || null
    }
    function fmtHours(ms) {
        var m = Math.round(ms / 60000)
        return m < 60 ? m + " min" : (m / 60).toFixed(m < 600 ? 1 : 0) + " h"
    }

    contentItem: ColumnLayout {
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            IconButton { text: "‹"; size: 26; tip: "Previous month"; onClicked: root.shift(-1) }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: new Date(root.year, root.month, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy")
                color: Theme.text
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
            IconButton {
                text: "›"; size: 26; tip: "Next month"
                enabled: new Date(root.year, root.month + 1, 1) <= new Date()
                onClicked: root.shift(1)
            }
        }
        DayOfWeekRow {
            Layout.fillWidth: true
            locale: Qt.locale()
            delegate: Text {
                required property string shortName
                text: shortName
                color: Theme.textFaint
                font.pixelSize: 10
                horizontalAlignment: Text.AlignHCenter
            }
        }
        MonthGrid {
            id: grid
            Layout.fillWidth: true
            month: root.month
            year: root.year
            locale: Qt.locale()
            delegate: Rectangle {
                id: cell
                required property var model
                readonly property bool inMonth: model.month === grid.month
                readonly property bool future: model.date > new Date()
                readonly property var day: root.info(model.date)
                // Without the server's answer (no camera), every past day can be picked.
                readonly property bool hasRec: root.loaded ? !!(day && day.rec_ms > 0) : (inMonth && !future)
                readonly property bool isSel: model.date.toDateString() === root.selected.toDateString()
                implicitWidth: 32
                implicitHeight: 28
                radius: 5
                color: isSel ? Theme.accent : dayMa.containsMouse && hasRec ? Theme.raised
                     : root.loaded && hasRec ? Theme.panelAlt : "transparent"
                border.color: model.today && !isSel ? Theme.accent : "transparent"
                Text {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: root.loaded && cell.hasRec ? -2 : 0
                    text: cell.model.day
                    font.pixelSize: 12
                    font.weight: root.loaded && cell.hasRec ? Font.DemiBold : Font.Normal
                    color: cell.isSel ? "white" : cell.hasRec ? Theme.text : Theme.textFaint
                    opacity: cell.inMonth ? 1 : 0.4
                }
                // Recorded (blue) or recorded with motion (red).
                Rectangle {
                    visible: root.loaded && cell.hasRec
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 3
                    width: 14; height: 3; radius: 1.5
                    color: cell.isSel ? "white" : cell.day && cell.day.motion > 0 ? "#e5484d" : Theme.accent
                }
                MouseArea {
                    id: dayMa
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: cell.hasRec
                    cursorShape: Qt.PointingHandCursor
                    ToolTip.visible: containsMouse && !!cell.day
                    ToolTip.delay: 300
                    ToolTip.text: cell.day ? cell.model.date.toLocaleDateString(Qt.locale(), "ddd d MMM") + "  ·  "
                                             + root.fmtHours(cell.day.rec_ms) + " recorded"
                                             + (cell.day.motion > 0 ? "  ·  " + cell.day.motion + " motion" : "") : ""
                    onClicked: {
                        var d = new Date(cell.model.year, cell.model.month, cell.model.day)
                        root.selected = d
                        root.picked(d, cell.day ? cell.day.first : 0)
                        root.close()
                    }
                }
            }
        }
        Text {
            Layout.fillWidth: true
            visible: root.loaded
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.days.some(function (d) { return d.rec_ms > 0 }) ? "Days with recordings are marked. Red: motion was detected."
                                                                     : "No recordings this month."
            color: Theme.textFaint
            font.pixelSize: 10
        }
        AppButton {
            Layout.fillWidth: true
            text: "Today"
            onClicked: {
                var n = new Date()
                var d = new Date(n.getFullYear(), n.getMonth(), n.getDate())
                root.selected = d
                var i = root.info(d)
                root.picked(d, i ? i.first : 0)
                root.close()
            }
        }
    }
}
