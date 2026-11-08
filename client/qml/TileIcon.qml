import QtQuick
import Ipvexa

// Small vector icons for tile toolbars and panels, drawn with Canvas so they look the
// same on every system (no dependency on symbol fonts).
Canvas {
    id: root
    property string kind: "close"
    property color color: "#e6e8ec"
    property real lineWidth: 1.6
    implicitWidth: 14
    implicitHeight: 14
    onKindChanged: requestPaint()
    onColorChanged: requestPaint()

    onPaint: {
        var c = getContext("2d")
        c.reset()
        var w = width, h = height, m = 1.5
        c.strokeStyle = root.color
        c.fillStyle = root.color
        c.lineWidth = root.lineWidth
        c.lineCap = "round"
        c.lineJoin = "round"
        c.beginPath()
        switch (kind) {
        case "close":
            c.moveTo(m + 1, m + 1); c.lineTo(w - m - 1, h - m - 1)
            c.moveTo(w - m - 1, m + 1); c.lineTo(m + 1, h - m - 1)
            break
        case "maximize":
            c.rect(m, m, w - 2 * m, h - 2 * m)
            break
        case "restore":
            c.rect(m, m + 3, w - 2 * m - 3, h - 2 * m - 3)
            c.moveTo(m + 3, m + 3); c.lineTo(m + 3, m); c.lineTo(w - m, m); c.lineTo(w - m, h - m - 3); c.lineTo(w - m - 3, h - m - 3)
            break
        case "fullscreen":
            var k = w * 0.32
            c.moveTo(m, m + k); c.lineTo(m, m); c.lineTo(m + k, m)
            c.moveTo(w - m - k, m); c.lineTo(w - m, m); c.lineTo(w - m, m + k)
            c.moveTo(w - m, h - m - k); c.lineTo(w - m, h - m); c.lineTo(w - m - k, h - m)
            c.moveTo(m + k, h - m); c.lineTo(m, h - m); c.lineTo(m, h - m - k)
            break
        case "ptz":
            var cx = w / 2, cy = h / 2, a = 3
            c.moveTo(cx, m); c.lineTo(cx, h - m); c.moveTo(m, cy); c.lineTo(w - m, cy)
            c.moveTo(cx - a, m + a); c.lineTo(cx, m); c.lineTo(cx + a, m + a)
            c.moveTo(cx - a, h - m - a); c.lineTo(cx, h - m); c.lineTo(cx + a, h - m - a)
            c.moveTo(m + a, cy - a); c.lineTo(m, cy); c.lineTo(m + a, cy + a)
            c.moveTo(w - m - a, cy - a); c.lineTo(w - m, cy); c.lineTo(w - m - a, cy + a)
            break
        case "info":
            c.arc(w / 2, h / 2, w / 2 - m, 0, Math.PI * 2)
            c.moveTo(w / 2, h * 0.45); c.lineTo(w / 2, h * 0.72)
            c.stroke(); c.beginPath()
            c.arc(w / 2, h * 0.3, 0.9, 0, Math.PI * 2); c.fill()
            return
        case "settings":
            var r1 = w / 2 - m, r2 = r1 * 0.45
            for (var i = 0; i < 8; i++) {
                var t = i * Math.PI / 4
                c.moveTo(w / 2 + Math.cos(t) * (r1 - 2.5), h / 2 + Math.sin(t) * (r1 - 2.5))
                c.lineTo(w / 2 + Math.cos(t) * r1, h / 2 + Math.sin(t) * r1)
            }
            c.moveTo(w / 2 + r1 - 2.5, h / 2)
            c.arc(w / 2, h / 2, r1 - 2.5, 0, Math.PI * 2)
            c.moveTo(w / 2 + r2, h / 2)
            c.arc(w / 2, h / 2, r2, 0, Math.PI * 2)
            break
        case "camera":
            c.rect(m, h * 0.3, w * 0.62, h * 0.45)
            c.moveTo(m + w * 0.62, h * 0.45); c.lineTo(w - m, h * 0.3); c.lineTo(w - m, h * 0.75); c.lineTo(m + w * 0.62, h * 0.6)
            break
        case "layout":
            c.rect(m, m, w - 2 * m, h - 2 * m)
            c.moveTo(w / 2, m); c.lineTo(w / 2, h - m); c.moveTo(m, h / 2); c.lineTo(w - m, h / 2)
            break
        case "server":
            c.rect(m, m + 1, w - 2 * m, h / 2 - m - 1.5)
            c.rect(m, h / 2 + 0.5, w - 2 * m, h / 2 - m - 1.5)
            break
        case "plus":
            c.moveTo(w / 2, m + 1); c.lineTo(w / 2, h - m - 1); c.moveTo(m + 1, h / 2); c.lineTo(w - m - 1, h / 2)
            break
        case "chevron":
            c.moveTo(w * 0.35, h * 0.25); c.lineTo(w * 0.65, h / 2); c.lineTo(w * 0.35, h * 0.75)
            break
        case "bell":
            c.moveTo(w * 0.2, h * 0.72); c.lineTo(w * 0.8, h * 0.72)
            c.moveTo(w * 0.27, h * 0.72); c.lineTo(w * 0.27, h * 0.45)
            c.arc(w / 2, h * 0.45, w * 0.23, Math.PI, 0)
            c.lineTo(w * 0.73, h * 0.72)
            c.moveTo(w * 0.42, h * 0.84); c.lineTo(w * 0.58, h * 0.84)
            break
        case "pulse":
            c.moveTo(m, h / 2); c.lineTo(w * 0.3, h / 2); c.lineTo(w * 0.42, h * 0.2); c.lineTo(w * 0.58, h * 0.8); c.lineTo(w * 0.7, h / 2); c.lineTo(w - m, h / 2)
            break
        case "panel":
            c.rect(m, m, w - 2 * m, h - 2 * m)
            c.moveTo(w * 0.65, m); c.lineTo(w * 0.65, h - m)
            break
        case "tree":
            c.rect(m, m, w - 2 * m, h - 2 * m)
            c.moveTo(w * 0.35, m); c.lineTo(w * 0.35, h - m)
            break
        case "minus":
            c.moveTo(m + 1, h / 2); c.lineTo(w - m - 1, h / 2)
            break
        case "down":
            c.moveTo(w * 0.25, h * 0.38); c.lineTo(w / 2, h * 0.64); c.lineTo(w * 0.75, h * 0.38)
            break
        case "check":
            c.moveTo(w * 0.2, h * 0.52); c.lineTo(w * 0.42, h * 0.74); c.lineTo(w * 0.82, h * 0.28)
            break
        case "user":
            c.arc(w / 2, h * 0.33, w * 0.2, 0, Math.PI * 2)
            c.moveTo(w * 0.14 + w * 0.72, h - m)
            c.arc(w / 2, h - m, w * 0.36, 0, Math.PI, true)
            break
        case "users":
            c.arc(w * 0.38, h * 0.36, w * 0.17, 0, Math.PI * 2)
            c.moveTo(w * 0.68, h - m)
            c.arc(w * 0.38, h - m, w * 0.3, 0, Math.PI, true)
            c.moveTo(w * 0.62, h * 0.2)
            c.arc(w * 0.7, h * 0.36, w * 0.14, -Math.PI * 0.7, Math.PI * 0.6)
            c.moveTo(w * 0.8, h * 0.62); c.quadraticCurveTo(w - m, h * 0.68, w - m, h - m)
            break
        case "logout":
            c.moveTo(w * 0.55, m); c.lineTo(m, m); c.lineTo(m, h - m); c.lineTo(w * 0.55, h - m)
            c.moveTo(w * 0.4, h / 2); c.lineTo(w - m, h / 2)
            c.moveTo(w - m - 3, h / 2 - 3); c.lineTo(w - m, h / 2); c.lineTo(w - m - 3, h / 2 + 3)
            break
        case "key":
            c.arc(w * 0.3, h * 0.65, w * 0.2, 0, Math.PI * 2)
            c.moveTo(w * 0.44, h * 0.51); c.lineTo(w - m, m + 1)
            c.moveTo(w * 0.72, h * 0.22); c.lineTo(w * 0.85, h * 0.35)
            break
        case "play":
            c.moveTo(w * 0.28, h * 0.18); c.lineTo(w * 0.82, h / 2); c.lineTo(w * 0.28, h * 0.82); c.closePath()
            c.fill(); return
        case "pause":
            c.fillRect(w * 0.24, h * 0.18, w * 0.17, h * 0.64)
            c.fillRect(w * 0.59, h * 0.18, w * 0.17, h * 0.64)
            return
        case "back":
            c.moveTo(w * 0.5, h * 0.2); c.lineTo(w * 0.12, h / 2); c.lineTo(w * 0.5, h * 0.8); c.closePath()
            c.moveTo(w * 0.9, h * 0.2); c.lineTo(w * 0.52, h / 2); c.lineTo(w * 0.9, h * 0.8); c.closePath()
            c.fill(); return
        case "forward":
            c.moveTo(w * 0.1, h * 0.2); c.lineTo(w * 0.48, h / 2); c.lineTo(w * 0.1, h * 0.8); c.closePath()
            c.moveTo(w * 0.5, h * 0.2); c.lineTo(w * 0.88, h / 2); c.lineTo(w * 0.5, h * 0.8); c.closePath()
            c.fill(); return
        case "prev":
            c.fillRect(w * 0.14, h * 0.2, w * 0.13, h * 0.6)
            c.moveTo(w * 0.86, h * 0.2); c.lineTo(w * 0.34, h / 2); c.lineTo(w * 0.86, h * 0.8); c.closePath()
            c.fill(); return
        case "next":
            c.fillRect(w * 0.73, h * 0.2, w * 0.13, h * 0.6)
            c.moveTo(w * 0.14, h * 0.2); c.lineTo(w * 0.66, h / 2); c.lineTo(w * 0.14, h * 0.8); c.closePath()
            c.fill(); return
        case "calendar":
            c.rect(m, m + 2, w - 2 * m, h - 2 * m - 2)
            c.moveTo(m, h * 0.4); c.lineTo(w - m, h * 0.4)
            c.moveTo(w * 0.32, m); c.lineTo(w * 0.32, m + 3.5)
            c.moveTo(w * 0.68, m); c.lineTo(w * 0.68, m + 3.5)
            break
        case "bookmark":
            c.moveTo(w * 0.25, m); c.lineTo(w * 0.75, m); c.lineTo(w * 0.75, h - m); c.lineTo(w / 2, h * 0.7); c.lineTo(w * 0.25, h - m); c.closePath()
            break
        case "download":
            c.moveTo(w / 2, m); c.lineTo(w / 2, h * 0.68)
            c.moveTo(w * 0.24, h * 0.44); c.lineTo(w / 2, h * 0.7); c.lineTo(w * 0.76, h * 0.44)
            c.moveTo(m, h - m); c.lineTo(w - m, h - m)
            break
        case "motion":
            c.arc(w * 0.62, h * 0.18, w * 0.11, 0, Math.PI * 2)
            c.moveTo(w * 0.55, h * 0.34); c.lineTo(w * 0.45, h * 0.62); c.lineTo(w * 0.62, h * 0.78); c.lineTo(w * 0.62, h - m)
            c.moveTo(w * 0.45, h * 0.62); c.lineTo(w * 0.3, h - m)
            c.moveTo(w * 0.52, h * 0.42); c.lineTo(w * 0.78, h * 0.52)
            c.moveTo(w * 0.52, h * 0.42); c.lineTo(w * 0.3, h * 0.48)
            c.moveTo(m, h * 0.3); c.lineTo(w * 0.22, h * 0.3)
            c.moveTo(m + 1, h * 0.45); c.lineTo(w * 0.2, h * 0.45)
            break
        case "search":
            c.arc(w * 0.42, h * 0.42, w * 0.28, 0, Math.PI * 2)
            c.moveTo(w * 0.63, h * 0.63); c.lineTo(w - m, h - m)
            break
        case "exitfull":
            var e = w * 0.3
            c.moveTo(m + e, m); c.lineTo(m + e, m + e); c.lineTo(m, m + e)
            c.moveTo(w - m - e, m); c.lineTo(w - m - e, m + e); c.lineTo(w - m, m + e)
            c.moveTo(w - m, h - m - e); c.lineTo(w - m - e, h - m - e); c.lineTo(w - m - e, h - m)
            c.moveTo(m, h - m - e); c.lineTo(m + e, h - m - e); c.lineTo(m + e, h - m)
            break
        }
        c.stroke()
    }
}
