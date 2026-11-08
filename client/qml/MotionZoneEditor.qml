import QtQuick
import QtQuick.Controls
import Ipvexa
import "Cells.js" as Cells

// Paint the parts of the picture where motion is ignored (trees, a busy road,
// the camera's own clock). Click or drag over the grid; the first cell decides
// whether the drag adds or removes.
Item {
    id: root
    property int cameraId: 0
    property string mask: ""          // hex, see Cells.js
    property var cells: Cells.decode(mask)
    property bool painting: false
    property bool paintValue: true
    property int imageRev: 0

    implicitWidth: 480
    implicitHeight: implicitWidth * 9 / 16

    onMaskChanged: if (Cells.encode(cells) !== mask) cells = Cells.decode(mask)
    function commit() { mask = Cells.encode(cells) }
    function clearAll() { cells = Cells.empty(); commit() }
    function reload() { imageRev++ }

    Rectangle { anchors.fill: parent; color: "#000"; radius: 4 }
    Image {
        id: img
        anchors.fill: parent
        fillMode: Image.Stretch
        cache: false
        asynchronous: true
        source: root.cameraId > 0 ? Api.snapshotUrl(root.cameraId) + "&r=" + root.imageRev : ""
    }
    Text {
        anchors.centerIn: parent
        visible: img.status !== Image.Ready
        text: root.cameraId <= 0 ? "Save the camera first to draw motion zones"
            : img.status === Image.Loading ? "Loading picture…" : "No picture (is the camera online?)"
        color: Theme.textDim
        font.pixelSize: 12
    }

    // Grid
    Repeater {
        model: Cells.N
        Rectangle {
            required property int index
            readonly property int cx: index % Cells.COLS
            readonly property int cy: Math.floor(index / Cells.COLS)
            x: cx * root.width / Cells.COLS
            y: cy * root.height / Cells.ROWS
            width: root.width / Cells.COLS
            height: root.height / Cells.ROWS
            color: root.cells[index] ? "#80e5484d" : "transparent"
            border.color: "#30ffffff"
            border.width: 0.5
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.cameraId > 0
        cursorShape: Qt.CrossCursor
        function cellAt(m) {
            var cx = Math.floor(m.x / width * Cells.COLS), cy = Math.floor(m.y / height * Cells.ROWS)
            if (cx < 0 || cy < 0 || cx >= Cells.COLS || cy >= Cells.ROWS) return -1
            return cy * Cells.COLS + cx
        }
        function paint(m) {
            var i = cellAt(m)
            if (i < 0 || root.cells[i] === root.paintValue) return
            var c = root.cells.slice()
            c[i] = root.paintValue
            root.cells = c
        }
        onPressed: (m) => {
            var i = cellAt(m)
            if (i < 0) return
            root.paintValue = !root.cells[i]
            root.painting = true
            paint(m)
        }
        onPositionChanged: (m) => { if (pressed) paint(m) }
        onReleased: { root.painting = false; root.commit() }
    }
}
