import QtQuick
import QtQuick.Controls
import Ipvexa
import "LayoutEngine.js" as LE

// The video wall. Lays out a free-form layout (cols x rows cells, items spanning
// cells) and turns drags, drops and resizes into layout changes.
Rectangle {
    id: root
    color: Theme.scene
    property var layout: LE.make("", 2, 2)
    property int selectedIndex: -1
    property int maximizedIndex: -1
    property Item dragLayer
    property string quality: "auto"
    property int searchIndex: -1       // tile showing the smart-search area
    property string searchCells: ""

    signal itemSelected(int index)
    signal maximizeToggled(int index)
    signal fullscreenRequested(int index)
    signal removeRequested(int index)
    signal cameraSettingsRequested(int cameraId)
    signal cameraDropped(int cameraId, int x, int y)
    signal itemMoved(int index, int x, int y)
    signal itemResized(int index, int w, int h)
    signal itemQualityPicked(int index, string q)
    signal itemAreaChosen(int index, string cells)
    signal itemZoomCommitted(int index, var z)
    signal itemDuplicateRequested(int index)
    property real selectedFps: 0
    property bool interactive: true   // false on video-wall windows: no editing
    signal backgroundMenuRequested()

    readonly property var items: layout && layout.items ? layout.items : []
    readonly property int cols: layout ? layout.cols : 1
    readonly property int rows: layout ? layout.rows : 1
    readonly property real ratio: !layout || layout.aspect === "16:9" ? 16 / 9 : layout.aspect === "4:3" ? 4 / 3 : 0
    readonly property real pad: 8
    readonly property real availW: width - pad * 2
    readonly property real availH: height - pad * 2
    readonly property real cellW: ratio > 0 ? Math.min(availW / cols, availH / rows * ratio) : availW / cols
    readonly property real cellH: ratio > 0 ? cellW / ratio : availH / rows
    readonly property real originX: pad + (availW - cellW * cols) / 2
    readonly property real originY: pad + (availH - cellH * rows) / 2
    readonly property real gap: 3

    // Cell under a point given in window coordinates.
    function cellAt(p) {
        var q = root.mapFromItem(null, p.x, p.y)
        return { x: Math.floor((q.x - originX) / cellW), y: Math.floor((q.y - originY) / cellH), px: q.x, py: q.y }
    }

    // Right-click on empty scene area → layout menu.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: root.backgroundMenuRequested()
    }

    // ---- Empty cells: drop targets ----
    Repeater {
        model: root.maximizedIndex >= 0 ? [] : LE.freeCells(root.layout)
        Rectangle {
            required property var modelData
            x: root.originX + modelData.x * root.cellW + root.gap / 2
            y: root.originY + modelData.y * root.cellH + root.gap / 2
            width: root.cellW - root.gap
            height: root.cellH - root.gap
            color: cellDrop.containsDrag ? "#162a36" : "#0d1114"
            border.color: cellDrop.containsDrag ? Theme.accent : "#1c2428"
            border.width: 1
            Column {
                visible: root.interactive
                anchors.centerIn: parent
                spacing: 4
                opacity: cellDrop.containsDrag ? 1 : cellHover.hovered ? 0.8 : 0.35
                TileIcon { anchors.horizontalCenter: parent.horizontalCenter; kind: "plus"; width: Math.min(26, parent.parent.height / 5); height: width; color: Theme.textDim }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: parent.parent.height > 110
                    text: "Drop a camera here"
                    color: Theme.textDim
                    font.pixelSize: 11
                }
            }
            HoverHandler { id: cellHover }
            DropArea {
                id: cellDrop
                enabled: root.interactive
                anchors.fill: parent
                keys: ["camera", "tile"]
                onDropped: (ev) => {
                    if (!ev.source) return
                    if (ev.keys.indexOf("tile") >= 0 && ev.source.itemIndex !== undefined)
                        root.itemMoved(ev.source.itemIndex, modelData.x, modelData.y)
                    else if (ev.source.cameraId > 0)
                        root.cameraDropped(ev.source.cameraId, modelData.x, modelData.y)
                }
            }
        }
    }

    // ---- Tiles ----
    // The model is just the item count, so delegates (and their video players) survive
    // moves, swaps and resizes; only their geometry bindings change.
    Repeater {
        model: root.items.length
        CameraTile {
            id: tile
            required property int index
            readonly property var it: root.items[index] || { cam: 0, x: 0, y: 0, w: 1, h: 1 }
            readonly property bool isMax: root.maximizedIndex === index

            itemIndex: index
            cameraId: it.cam
            selected: root.selectedIndex === index
            maximized: isMax
            dragLayer: root.dragLayer
            sceneQuality: root.quality
            qualityOverride: it.q || ""
            searchCells: root.searchIndex === index ? root.searchCells : ""
            zoomState: it.z
            editable: root.interactive
            visible: root.maximizedIndex < 0 || isMax
            z: isMax ? 2 : selected ? 1 : 0
            x: isMax ? root.pad : root.originX + it.x * root.cellW + root.gap / 2
            y: isMax ? root.pad : root.originY + it.y * root.cellH + root.gap / 2
            width: isMax ? root.availW : it.w * root.cellW - root.gap
            height: isMax ? root.availH : it.h * root.cellH - root.gap

            onClicked: root.itemSelected(index)
            onMaximizeToggled: root.maximizeToggled(index)
            onFullscreenRequested: root.fullscreenRequested(index)
            onCloseRequested: root.removeRequested(index)
            onSettingsRequested: root.cameraSettingsRequested(it.cam)
            onQualityPicked: (q) => root.itemQualityPicked(index, q)
            onAreaChosen: (cells) => root.itemAreaChosen(index, cells)
            onZoomCommitted: (z) => root.itemZoomCommitted(index, z)
            onZoomTileRequested: root.itemDuplicateRequested(index)
            Binding { target: root; property: "selectedFps"; value: tile.fps; when: tile.selected }
            onCameraDropped: (camId) => root.cameraDropped(camId, it.x, it.y)
            onTileDropped: (from) => root.itemMoved(from, it.x, it.y)
            onResizeMoved: (p) => {
                var c = root.cellAt(p)
                resizePreview.show(it, Math.max(1, c.x - it.x + 1), Math.max(1, c.y - it.y + 1))
            }
            onResizeFinished: (p) => {
                var c = root.cellAt(p)
                resizePreview.visible = false
                root.itemResized(index, Math.max(1, c.x - it.x + 1), Math.max(1, c.y - it.y + 1))
            }

            Behavior on x { enabled: !tile.dragging; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: !tile.dragging; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        }
    }

    // Outline showing the new size while dragging a resize handle.
    Rectangle {
        id: resizePreview
        visible: false
        z: 10
        color: "#202fa8e0"
        border.color: Theme.accent
        border.width: 2
        function show(it, w, h) {
            w = Math.min(w, root.cols - it.x); h = Math.min(h, root.rows - it.y)
            x = root.originX + it.x * root.cellW
            y = root.originY + it.y * root.cellH
            width = w * root.cellW
            height = h * root.cellH
            visible = true
        }
    }

    // Empty layout hint
    Column {
        visible: root.items.length === 0 && root.interactive
        anchors.centerIn: parent
        spacing: 8
        z: 3
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "This layout is empty"; color: Theme.textDim; font.pixelSize: 16; font.weight: Font.DemiBold }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Drag cameras from the left panel, or double-click one"; color: Theme.textFaint; font.pixelSize: 12 }
    }
}
