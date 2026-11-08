import QtQuick
import Ipvexa
import "LayoutEngine.js" as LE

// Miniature picture of a layout preset ("2x2", "1+5", …).
Canvas {
    id: root
    property string preset: "2x2"
    property color color: Theme.textDim
    implicitWidth: 16
    implicitHeight: 12
    onColorChanged: requestPaint()
    onPresetChanged: requestPaint()

    onPaint: {
        var c = getContext("2d")
        c.reset()
        var ps = LE.presetSlots(preset)
        var cw = (width - 1) / ps.cols, ch = (height - 1) / ps.rows
        c.strokeStyle = root.color
        c.lineWidth = 1
        for (var i = 0; i < ps.slots.length; i++) {
            var s = ps.slots[i]
            c.strokeRect(Math.round(s.x * cw) + 0.5, Math.round(s.y * ch) + 0.5,
                         Math.round(s.w * cw) - 1, Math.round(s.h * ch) - 1)
        }
    }
}
