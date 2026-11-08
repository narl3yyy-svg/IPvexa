import QtQuick
import QtQuick.Controls
import Ipvexa

// Compact [−] value [+] control for the toolbar.
Rectangle {
    id: root
    property int value: 0
    property string suffix: ""
    signal decrement()
    signal increment()

    implicitHeight: 24
    implicitWidth: minus.width + label.implicitWidth + 16 + plus.width
    radius: 5
    color: "#0e1215"
    border.color: Theme.border

    component StepBtn: Rectangle {
        property string kind
        signal clicked()
        width: 22; height: root.height - 4
        anchors.verticalCenter: parent.verticalCenter
        radius: 4
        color: sma.pressed ? Theme.raised : sma.containsMouse ? Theme.panelAlt : "transparent"
        TileIcon { anchors.centerIn: parent; kind: parent.kind; width: 9; height: 9; color: sma.containsMouse ? Theme.text : Theme.textDim; lineWidth: 1.5 }
        MouseArea { id: sma; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked() }
    }

    StepBtn { id: minus; kind: "minus"; x: 2; onClicked: root.decrement() }
    Text {
        id: label
        anchors.centerIn: parent
        text: root.value + " " + root.suffix
        color: Theme.text
        font.pixelSize: 11
        font.weight: Font.DemiBold
    }
    StepBtn { id: plus; kind: "plus"; x: root.width - width - 2; onClicked: root.increment() }
}
