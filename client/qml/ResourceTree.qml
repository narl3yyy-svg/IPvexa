import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Left panel, Nx-style resource tree: Server → cameras, and Layouts.
// Drag a camera onto the scene, or double-click it to add it to the current layout.
Rectangle {
    id: root
    color: Theme.panel
    property Item dragLayer
    property var layouts: []          // [{name, cols, rows, items}]
    property string currentLayout: ""
    property string filter: ""
    property var ids: []
    property bool serverOpen: true
    property bool layoutsOpen: true

    signal cameraActivated(int id)
    signal editCamera(int id)
    signal addCamera()
    signal layoutActivated(string name)
    signal deleteLayout(string name)
    signal renameLayout(string name)
    signal duplicateLayout(string name)
    signal newLayout()

    function updateIds() {
        var next = Api.cameras.filter(function (c) { return root.filter === "" || c.name.toLowerCase().indexOf(root.filter) >= 0 })
                              .map(function (c) { return c.id })
        if (JSON.stringify(next) !== JSON.stringify(ids)) ids = next
    }
    onFilterChanged: updateIds()
    Component.onCompleted: updateIds()
    Connections { target: Api; function onCamerasChanged() { root.updateIds() } }

    component SectionHeader: Rectangle {
        id: sh
        property string label
        property string icon
        property bool open: true
        property string count: ""
        signal toggled()
        width: parent ? parent.width : 0
        height: 28
        color: shMa.containsMouse ? Theme.panelAlt : "transparent"
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            TileIcon { kind: "chevron"; width: 10; height: 10; color: Theme.textDim; rotation: sh.open ? 90 : 0; anchors.verticalCenter: parent.verticalCenter
                       Behavior on rotation { NumberAnimation { duration: 120 } } }
            TileIcon { kind: sh.icon; width: 14; height: 14; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
            Text { text: sh.label; color: Theme.text; font.pixelSize: 12; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            Text { text: sh.count; color: Theme.textFaint; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: shMa; anchors.fill: parent; hoverEnabled: true; onClicked: sh.toggled() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- Search ----
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            TextField {
                anchors.fill: parent
                anchors.margins: 8
                placeholderText: "Search"
                leftPadding: 28
                onTextChanged: root.filter = text.toLowerCase()
                background: Rectangle { color: "#12171a"; radius: 4; border.color: parent.activeFocus ? Theme.accent : Theme.border }
                Canvas {
                    x: 9; y: (parent.height - 12) / 2; width: 12; height: 12
                    onPaint: { var c = getContext("2d"); c.reset(); c.strokeStyle = Theme.textFaint; c.lineWidth = 1.5
                               c.beginPath(); c.arc(5, 5, 4, 0, Math.PI * 2); c.moveTo(8, 8); c.lineTo(11.5, 11.5); c.stroke() }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: treeCol.implicitHeight + 10
            ScrollBar.vertical: ScrollBar {}

            Column {
                id: treeCol
                width: flick.width
                topPadding: 4

                // ======== Server ========
                SectionHeader {
                    label: Api.serverUrl.replace(/^https?:\/\//, "")
                    icon: "server"
                    open: root.serverOpen
                    count: "· " + Api.cameras.length
                    onToggled: root.serverOpen = !root.serverOpen
                }
                Repeater {
                    model: root.serverOpen ? root.ids : []
                    delegate: Item {
                        id: del
                        required property int modelData
                        readonly property var cam: Theme.findCamera(Api.cameras, modelData) || ({})
                        readonly property var st: cam.status && cam.status.main ? cam.status.main : null
                        readonly property string state: !cam.enabled ? "disabled" : (st ? st.state : "offline")
                        width: treeCol.width
                        height: 28

                        Rectangle { anchors.fill: parent; color: ma.containsMouse ? Theme.panelAlt : "transparent" }
                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 28
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 7
                            Item {
                                width: 16; height: 16
                                anchors.verticalCenter: parent.verticalCenter
                                TileIcon { anchors.fill: parent; kind: "camera"; color: del.state === "online" ? "#cfd8dd" : Theme.textFaint }
                                Rectangle {
                                    width: 6; height: 6; radius: 3
                                    anchors.right: parent.right; anchors.bottom: parent.bottom
                                    color: Theme.stateColor(del.state)
                                    border.color: Theme.panel; border.width: 1
                                }
                            }
                            Text {
                                width: del.width - 28 - 16 - 7 - 70
                                text: del.cam.name || ""
                                color: del.state === "online" ? Theme.text : Theme.textDim
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 5
                            Text {
                                text: del.st && del.st.height ? del.st.height + "p" : (del.state === "disabled" ? "off" : "")
                                color: Theme.textFaint
                                font.pixelSize: 10
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Rectangle {
                                visible: !!(del.st && del.st.recording)
                                width: 6; height: 6; radius: 3; color: Theme.live
                                anchors.verticalCenter: parent.verticalCenter
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
                            onReleased: if (drag.active) proxy.Drag.drop()
                            ToolTip.visible: containsMouse && !pressed && del.st && del.st.width
                            ToolTip.delay: 700
                            ToolTip.text: del.st ? (del.st.codec || "").toUpperCase() + " " + del.st.width + "×" + del.st.height
                                                   + " · " + ((del.st.bitrate_bps || 0) / 1e6).toFixed(1) + " Mb/s"
                                                   + (del.st.recording ? " · recording" : "") : ""
                        }
                        Menu {
                            id: menu
                            MenuItem { text: "Add to layout"; onTriggered: root.cameraActivated(del.modelData) }
                            MenuItem { text: "Camera settings…"; enabled: Api.isAdmin; onTriggered: root.editCamera(del.modelData) }
                        }
                        Rectangle {
                            id: proxy
                            property int cameraId: del.modelData
                            width: 190; height: 32; radius: 4
                            color: "#e01a2024"
                            border.color: Theme.accent
                            visible: ma.drag.active
                            Drag.active: ma.drag.active
                            Drag.keys: ["camera"]
                            Drag.hotSpot.x: 20
                            Drag.hotSpot.y: 16
                            Row {
                                anchors.centerIn: parent
                                spacing: 6
                                TileIcon { kind: "camera"; width: 14; height: 14; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: del.cam.name || ""; color: Theme.text; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                            }
                            states: State {
                                when: ma.drag.active
                                ParentChange { target: proxy; parent: root.dragLayer }
                            }
                            onVisibleChanged: if (!visible) { x = 0; y = 0 }
                        }
                    }
                }
                Text {
                    visible: root.serverOpen && root.ids.length === 0
                    leftPadding: 30; topPadding: 6; bottomPadding: 6
                    text: Api.cameras.length === 0 ? "No cameras yet" : "No match"
                    color: Theme.textFaint
                    font.pixelSize: 11
                }

                Item { width: 1; height: 8 }

                // ======== Layouts ========
                SectionHeader {
                    label: "Layouts"
                    icon: "layout"
                    open: root.layoutsOpen
                    count: "· " + root.layouts.length
                    onToggled: root.layoutsOpen = !root.layoutsOpen
                }
                Repeater {
                    model: root.layoutsOpen ? root.layouts : []
                    delegate: Rectangle {
                        required property var modelData
                        width: treeCol.width
                        height: 28
                        color: modelData.name === root.currentLayout ? Theme.accentSoft : lma.containsMouse ? Theme.panelAlt : "transparent"
                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 28
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 7
                            TileIcon { kind: "layout"; width: 14; height: 14; color: Theme.textDim; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: modelData.name; color: Theme.text; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                        }
                        Text {
                            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                            text: modelData.cols + "×" + modelData.rows + " · " + (modelData.items ? modelData.items.length : 0)
                            color: Theme.textFaint; font.pixelSize: 10
                        }
                        MouseArea {
                            id: lma
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: (mouse) => mouse.button === Qt.RightButton ? lmenu.popup() : root.layoutActivated(modelData.name)
                        }
                        Menu {
                            id: lmenu
                            MenuItem { text: "Open"; onTriggered: root.layoutActivated(modelData.name) }
                            MenuItem { text: "Rename…"; onTriggered: root.renameLayout(modelData.name) }
                            MenuItem { text: "Duplicate"; onTriggered: root.duplicateLayout(modelData.name) }
                            MenuSeparator {}
                            MenuItem { text: "Delete layout"; enabled: root.layouts.length > 1; onTriggered: root.deleteLayout(modelData.name) }
                        }
                    }
                }
                Rectangle {
                    visible: root.layoutsOpen
                    width: treeCol.width
                    height: 28
                    color: nma.containsMouse ? Theme.panelAlt : "transparent"
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 28; anchors.verticalCenter: parent.verticalCenter
                        spacing: 7
                        TileIcon { kind: "plus"; width: 12; height: 12; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: "New layout"; color: Theme.accent; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                    }
                    MouseArea { id: nma; anchors.fill: parent; hoverEnabled: true; onClicked: root.newLayout() }
                }
            }
        }

        // ---- Add camera ----
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border; visible: Api.isAdmin }
        Rectangle {
            visible: Api.isAdmin
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: addMa.containsMouse ? Theme.panelAlt : "transparent"
            Row {
                anchors.centerIn: parent
                spacing: 8
                TileIcon { kind: "plus"; width: 12; height: 12; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
                Text { text: "Add camera"; color: Theme.accent; font.pixelSize: 12; font.weight: Font.DemiBold; anchors.verticalCenter: parent.verticalCenter }
            }
            MouseArea { id: addMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.addCamera() }
        }
    }
}
