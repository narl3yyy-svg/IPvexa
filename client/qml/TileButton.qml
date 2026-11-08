import QtQuick
import QtQuick.Controls
import Ipvexa

// Square icon button for the tile toolbar.
Rectangle {
    id: root
    property string icon: "close"
    property string tip: ""
    property bool active: false
    property color hoverColor: "#40ffffff"
    signal clicked()

    width: 22; height: 22; radius: 4
    color: ma.pressed ? Theme.accent : active ? "#a02fa8e0" : ma.containsMouse ? hoverColor : "#90000000"
    TileIcon { anchors.centerIn: parent; kind: root.icon; color: "white"; width: 12; height: 12 }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
        ToolTip.visible: containsMouse && root.tip !== ""
        ToolTip.text: root.tip
        ToolTip.delay: 450
    }
}
