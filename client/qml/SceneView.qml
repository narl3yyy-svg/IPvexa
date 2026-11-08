import QtQuick
import Ipvexa

// The video wall: lays out tiles on a grid while keeping each tile's aspect ratio.
Rectangle {
    id: root
    color: Theme.scene
    property var slots: []
    property var slotCams: []
    property string aspect: "16:9"
    property int selectedSlot: 0
    property int maximizedSlot: -1
    property Item dragLayer

    signal slotSelected(int index)
    signal slotMaximizeToggled(int index)
    signal cameraDropped(int slot, int cameraId)
    signal slotCleared(int index)

    readonly property real ratio: aspect === "4:3" ? 4 / 3 : aspect === "16:9" ? 16 / 9 : 0
    readonly property int cols: slots.cols || 1
    readonly property int rows: slots.rows || 1
    readonly property real pad: 6
    readonly property real availW: width - pad * 2
    readonly property real availH: height - pad * 2
    // Cell size: fill the space, constrained by the aspect ratio unless "Fill".
    readonly property real cellW: ratio > 0 ? Math.min(availW / cols, availH / rows * ratio) : availW / cols
    readonly property real cellH: ratio > 0 ? cellW / ratio : availH / rows
    readonly property real originX: pad + (availW - cellW * cols) / 2
    readonly property real originY: pad + (availH - cellH * rows) / 2

    Repeater {
        model: root.slots.length
        CameraTile {
            id: tile
            required property int index
            readonly property var cell: root.slots[index]
            readonly property bool maximized: root.maximizedSlot === index
            readonly property bool hidden: root.maximizedSlot >= 0 && !maximized

            slotIndex: index
            cameraId: root.slotCams[index] || 0
            selected: root.selectedSlot === index
            dragLayer: root.dragLayer
            visible: !hidden
            x: maximized ? root.pad : root.originX + cell.x * root.cellW + Theme.gap / 2
            y: maximized ? root.pad : root.originY + cell.y * root.cellH + Theme.gap / 2
            width: maximized ? root.availW : cell.w * root.cellW - Theme.gap
            height: maximized ? root.availH : cell.h * root.cellH - Theme.gap

            onClicked: root.slotSelected(index)
            onDoubleClicked: root.slotMaximizeToggled(index)
            onDropped: (camId) => root.cameraDropped(index, camId)
            onCloseRequested: root.slotCleared(index)

            Behavior on x { enabled: !tile.dragging; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: !tile.dragging; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
    }
}
