import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Left panel: server, cameras (drag onto the scene), saved layouts.
Rectangle {
    id: root
    color: Theme.panel
    property Item dragLayer
    property var layouts: []
    property string currentLayout: ""
    property string filter: ""
    property var ids: []

    function updateIds() {
        var next = Api.cameras.filter(function (c) { return root.filter === "" || c.name.toLowerCase().indexOf(root.filter) >= 0 })
                              .map(function (c) { return c.id })
        if (JSON.stringify(next) !== JSON.stringify(ids)) ids = next
    }
    onFilterChanged: updateIds()
    Component.onCompleted: updateIds()
    Connections { target: Api; function onCamerasChanged() { root.updateIds() } }

    signal cameraActivated(int id)
    signal editCamera(int id)
    signal addCamera()
    signal layoutActivated(var layout)
    signal deleteLayout(string name)
    signal newLayout()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        TextField {
            Layout.fillWidth: true
            placeholderText: "Search cameras…"
            onTextChanged: root.filter = text.toLowerCase()
        }

        // ---- Server header ----
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 6
            Text { text: "▣"; color: Theme.accent; font.pixelSize: 13 }
            Text {
                Layout.fillWidth: true
                text: Api.serverUrl.replace(/^https?:\/\//, "")
                color: Theme.text
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            IconButton { glyph: "+"; size: 24; tip: "Add camera"; visible: Api.role === "admin"; onClicked: root.addCamera() }
        }

        // ---- Cameras ----
        ListView {
            id: camList
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 120
            clip: true
            spacing: 2
            // Model is a list of IDs that only changes when cameras are added/removed/filtered,
            // so status updates don't recreate delegates (which would cancel a drag).
            model: root.ids
            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
                id: del
                required property int modelData
                readonly property var cam: Theme.findCamera(Api.cameras, modelData) || ({})
                width: camList.width
                height: 44
                readonly property var st: cam.status && cam.status.main ? cam.status.main : null
                readonly property string state: !cam.enabled ? "disabled" : (st ? st.state : "offline")

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radius
                    color: ma.containsMouse ? Theme.panelAlt : "transparent"
                }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 8
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: Theme.stateColor(del.state)
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            Layout.fillWidth: true
                            text: del.cam.name
                            color: Theme.text
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: del.st && del.st.width ? (del.st.codec || "").toUpperCase() + " · " + del.st.width + "×" + del.st.height
                                    + (del.st.recording ? " · ● REC" : "")
                                  : del.state
                            color: del.st && del.st.recording ? Theme.textDim : Theme.textFaint
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    drag.target: proxy
                    drag.threshold: 6
                    onDoubleClicked: root.cameraActivated(del.modelData)
                    onClicked: (mouse) => { if (mouse.button === Qt.RightButton) menu.popup() }
                    onReleased: if (drag.active) { proxy.Drag.drop(); }
                }
                Menu {
                    id: menu
                    MenuItem { text: "Show in layout"; onTriggered: root.cameraActivated(del.modelData) }
                    MenuItem { text: "Camera settings…"; enabled: Api.role === "admin"; onTriggered: root.editCamera(del.modelData) }
                }

                // Drag proxy: floats above everything while dragging.
                Rectangle {
                    id: proxy
                    property int cameraId: del.modelData
                    property int fromSlot: -1
                    width: 180; height: 34; radius: Theme.radius
                    color: Theme.raised
                    border.color: Theme.accent
                    visible: ma.drag.active
                    Drag.active: ma.drag.active
                    Drag.keys: ["camera"]
                    Drag.hotSpot.x: 20
                    Drag.hotSpot.y: 17
                    Text { anchors.centerIn: parent; text: "◉  " + del.cam.name; color: Theme.text; font.pixelSize: 12 }
                    states: State {
                        when: ma.drag.active
                        ParentChange { target: proxy; parent: root.dragLayer }
                    }
                    onVisibleChanged: if (!visible) { x = 0; y = 0 }
                }
            }

            Text {
                anchors.centerIn: parent
                width: parent.width - 20
                visible: camList.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: Api.cameras.length === 0 ? "No cameras yet.\nClick + to add one." : "No match"
                color: Theme.textFaint
                font.pixelSize: 12
            }
        }

        // ---- Layouts ----
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 6
            Text { text: "LAYOUTS"; color: Theme.textFaint; font.pixelSize: 11; font.weight: Font.Bold; font.letterSpacing: 1; Layout.fillWidth: true }
            IconButton { glyph: "+"; size: 22; tip: "New empty layout"; onClicked: root.newLayout() }
        }
        ListView {
            id: layoutList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 180)
            clip: true
            model: root.layouts
            delegate: Rectangle {
                required property var modelData
                width: layoutList.width
                height: 30
                radius: Theme.radius
                color: modelData.name === root.currentLayout ? Theme.accentSoft : lma.containsMouse ? Theme.panelAlt : "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 4
                    Text { text: "▦"; color: Theme.textDim; font.pixelSize: 12 }
                    Text { Layout.fillWidth: true; text: modelData.name; color: Theme.text; font.pixelSize: 12; elide: Text.ElideRight }
                    Text { text: modelData.preset; color: Theme.textFaint; font.pixelSize: 11 }
                }
                MouseArea {
                    id: lma
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (mouse) => mouse.button === Qt.RightButton ? lmenu.popup() : root.layoutActivated(modelData)
                }
                Menu {
                    id: lmenu
                    MenuItem { text: "Open"; onTriggered: root.layoutActivated(modelData) }
                    MenuItem { text: "Delete layout"; onTriggered: root.deleteLayout(modelData.name) }
                }
            }
            Text {
                visible: layoutList.count === 0
                text: "Save a layout with 💾 in the top bar"
                color: Theme.textFaint
                font.pixelSize: 11
            }
        }
    }
}
