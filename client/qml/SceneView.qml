import QtQuick
import QtQuick.Controls
import Ipvexa
import "LayoutEngine.js" as LE

// The video wall. Lays out a free-form layout (cols x rows cells, items spanning
// cells) and turns drags, drops and resizes into layout changes. Columns and rows
// can have different sizes: drag the borders between tiles.
Rectangle {
    id: root
    color: Theme.scene
    property var layout: LE.make("", 2, 2)
    property int selectedIndex: -1
    property int maximizedIndex: -1
    property Item dragLayer
    property string quality: "auto"
    property int liveBufferMs: 600
    property int searchIndex: -1       // tile showing the smart-search area
    property string searchCells: ""
    property bool syncPlayback: true   // false: only the selected tile follows the timeline

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
    signal sizesCommitted(var cw, var rh)   // new column widths / row heights (undefined = equal)
    signal fitPicked(string fit)            // maximize frames: fit | fill | stretch
    property real selectedFps: 0
    property bool interactive: true   // false on video-wall windows: no editing
    signal backgroundMenuRequested()

    readonly property var items: layout && layout.items ? layout.items : []
    readonly property int cols: layout ? layout.cols : 1
    readonly property int rows: layout ? layout.rows : 1
    readonly property real ratio: !layout || layout.aspect === "16:9" ? 16 / 9 : layout.aspect === "4:3" ? 4 / 3 : 0
    readonly property string fit: layout && layout.fit ? layout.fit : "fit"
    readonly property real pad: 8
    readonly property real availW: width - pad * 2
    readonly property real availH: height - pad * 2
    readonly property real cellW: ratio > 0 ? Math.min(availW / cols, availH / rows * ratio) : availW / cols
    readonly property real cellH: ratio > 0 ? cellW / ratio : availH / rows
    readonly property real gridW: cellW * cols
    readonly property real gridH: cellH * rows
    readonly property real originX: pad + (availW - gridW) / 2
    readonly property real originY: pad + (availH - gridH) / 2
    readonly property real gap: 3

    // While a border is dragged, the layout with the new sizes (shown live, saved on release).
    property var sizing: null
    readonly property var geo: sizing || layout || LE.make("", 1, 1)
    readonly property var colEdges: LE.edges(geo, "cols")
    readonly property var rowEdges: LE.edges(geo, "rows")
    function px(x) { return originX + gridW * colEdges[Math.max(0, Math.min(cols, x))] }
    function py(y) { return originY + gridH * rowEdges[Math.max(0, Math.min(rows, y))] }

    // Cell under a point given in window coordinates.
    function cellAt(p) {
        var q = root.mapFromItem(null, p.x, p.y)
        function find(e, f) {
            if (f < 0) return -1
            for (var i = 0; i < e.length - 1; i++) if (f < e[i + 1]) return i
            return e.length - 1
        }
        return { x: find(colEdges, (q.x - originX) / gridW), y: find(rowEdges, (q.y - originY) / gridH), px: q.x, py: q.y }
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
            x: root.px(modelData.x) + root.gap / 2
            y: root.py(modelData.y) + root.gap / 2
            width: root.px(modelData.x + 1) - root.px(modelData.x) - root.gap
            height: root.py(modelData.y + 1) - root.py(modelData.y) - root.gap
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
            liveBufferMs: root.liveBufferMs
            qualityOverride: it.q || ""
            searchCells: root.searchIndex === index ? root.searchCells : ""
            fitMode: root.fit
            followsTimeline: root.syncPlayback || selected
            zoomState: it.z
            editable: root.interactive
            visible: root.maximizedIndex < 0 || isMax
            z: isMax ? 2 : selected ? 1 : 0
            x: isMax ? root.pad : root.px(it.x) + root.gap / 2
            y: isMax ? root.pad : root.py(it.y) + root.gap / 2
            width: isMax ? root.availW : root.px(it.x + it.w) - root.px(it.x) - root.gap
            height: isMax ? root.availH : root.py(it.y + it.h) - root.py(it.y) - root.gap

            onClicked: root.itemSelected(index)
            onMaximizeToggled: root.maximizeToggled(index)
            onFullscreenRequested: root.fullscreenRequested(index)
            onCloseRequested: root.removeRequested(index)
            onSettingsRequested: root.cameraSettingsRequested(it.cam)
            onQualityPicked: (q) => root.itemQualityPicked(index, q)
            onAreaChosen: (cells) => root.itemAreaChosen(index, cells)
            onZoomCommitted: (z) => root.itemZoomCommitted(index, z)
            onZoomTileRequested: root.itemDuplicateRequested(index)
            onFitPicked: (f) => root.fitPicked(f)
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

            Behavior on x { enabled: !tile.dragging && !root.sizing; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: !tile.dragging && !root.sizing; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on width { enabled: !root.sizing; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on height { enabled: !root.sizing; NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        }
    }

    // ---- Borders between tiles: drag to widen or shrink columns and rows ----
    Repeater {
        model: root.interactive && root.maximizedIndex < 0 && root.items.length > 0
               ? LE.borderSegments(root.layout, "cols").map(function (s) { s.axis = "cols"; return s })
                   .concat(LE.borderSegments(root.layout, "rows").map(function (s) { s.axis = "rows"; return s }))
               : []
        Item {
            id: border
            required property var modelData
            readonly property bool vertical: modelData.axis === "cols"
            readonly property real grab: 8
            z: 8
            x: vertical ? root.px(modelData.i) - grab / 2 : root.px(modelData.from)
            y: vertical ? root.py(modelData.from) : root.py(modelData.i) - grab / 2
            width: vertical ? grab : root.px(modelData.to) - root.px(modelData.from)
            height: vertical ? root.py(modelData.to) - root.py(modelData.from) : grab
            Rectangle {
                anchors.centerIn: parent
                width: border.vertical ? 2 : parent.width - 8
                height: border.vertical ? parent.height - 8 : 2
                radius: 1
                color: Theme.accent
                opacity: borderMa.pressed ? 1 : borderMa.containsMouse ? 0.7 : 0
                Behavior on opacity { NumberAnimation { duration: 120 } }
            }
            MouseArea {
                id: borderMa
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: border.vertical ? Qt.SplitHCursor : Qt.SplitVCursor
                onPositionChanged: (m) => {
                    if (!pressed) return
                    var q = mapToItem(root, m.x, m.y)
                    var pos = border.vertical ? (q.x - root.originX) / root.gridW : (q.y - root.originY) / root.gridH
                    root.sizing = LE.moveBorder(root.sizing || root.layout, border.modelData.axis, border.modelData.i, pos)
                }
                onReleased: {
                    if (root.sizing) root.sizesCommitted(root.sizing.cw, root.sizing.rh)
                    root.sizing = null
                }
                onCanceled: root.sizing = null
                // Double-click: make this direction's columns (or rows) equal again.
                onDoubleClicked: {
                    root.sizing = null
                    if (border.vertical) root.sizesCommitted(undefined, root.layout.rh)
                    else root.sizesCommitted(root.layout.cw, undefined)
                }
                ToolTip.visible: containsMouse && !pressed
                ToolTip.delay: 900
                ToolTip.text: "Drag to resize · double-click to make them equal"
            }
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
            x = root.px(it.x)
            y = root.py(it.y)
            width = root.px(it.x + w) - x
            height = root.py(it.y + h) - y
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
