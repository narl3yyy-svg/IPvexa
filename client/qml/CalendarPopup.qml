import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Month calendar for jumping to a day. Emits picked(date at local midnight).
Popup {
    id: root
    property date selected: new Date()
    property int month: selected.getMonth()
    property int year: selected.getFullYear()
    signal picked(date day)

    width: 268
    padding: 12
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onAboutToShow: { month = selected.getMonth(); year = selected.getFullYear() }

    background: Rectangle { color: Theme.panel; radius: 8; border.color: Theme.borderStrong }

    function shift(n) {
        var m = month + n
        year += Math.floor(m / 12)
        month = ((m % 12) + 12) % 12
    }

    contentItem: ColumnLayout {
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            IconButton { text: "‹"; size: 26; onClicked: root.shift(-1) }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: new Date(root.year, root.month, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy")
                color: Theme.text
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
            IconButton {
                text: "›"; size: 26
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
                required property var model
                readonly property bool inMonth: model.month === grid.month
                readonly property bool future: model.date > new Date()
                readonly property bool isSel: model.date.toDateString() === root.selected.toDateString()
                implicitWidth: 32
                implicitHeight: 28
                radius: 5
                color: isSel ? Theme.accent : dayMa.containsMouse && !future ? Theme.panelAlt : "transparent"
                border.color: model.today && !isSel ? Theme.accent : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: model.day
                    font.pixelSize: 12
                    color: parent.isSel ? "white" : parent.future ? Theme.textFaint : parent.inMonth ? Theme.text : Theme.textFaint
                    opacity: parent.inMonth ? 1 : 0.5
                }
                MouseArea {
                    id: dayMa
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !parent.future
                    onClicked: {
                        var d = new Date(model.year, model.month, model.day)
                        root.selected = d
                        root.picked(d)
                        root.close()
                    }
                }
            }
        }
        AppButton {
            Layout.fillWidth: true
            text: "Today"
            onClicked: {
                var n = new Date()
                var d = new Date(n.getFullYear(), n.getMonth(), n.getDate())
                root.selected = d
                root.picked(d)
                root.close()
            }
        }
    }
}
