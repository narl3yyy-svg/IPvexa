import QtQuick
import QtQuick.Window
import Ipvexa
import "LayoutEngine.js" as LE

// A layout shown full screen on another monitor (video wall). View-only: the layout
// is edited in the main window and changes appear here at once.
Window {
    id: wall
    property string layoutName: ""
    property var layout: LE.make("", 1, 1)
    property string quality: "auto"
    property int liveBufferMs: 600
    property int selectedIndex: -1
    property int maximizedIndex: -1

    title: layoutName + " — IPvexa"
    color: Theme.scene
    minimumWidth: 480
    minimumHeight: 270

    Component.onCompleted: showFullScreen()

    Item { id: wallDragLayer; anchors.fill: parent; z: 100 }

    SceneView {
        anchors.fill: parent
        layout: wall.layout
        interactive: false
        quality: wall.quality
        liveBufferMs: wall.liveBufferMs
        selectedIndex: wall.selectedIndex
        maximizedIndex: wall.maximizedIndex
        dragLayer: wallDragLayer
        onItemSelected: (i) => wall.selectedIndex = i
        onMaximizeToggled: (i) => wall.maximizedIndex = wall.maximizedIndex === i ? -1 : i
        onFullscreenRequested: (i) => wall.maximizedIndex = wall.maximizedIndex === i ? -1 : i
    }

    // Hint shown for a few seconds after opening, and whenever the mouse moves.
    Rectangle {
        id: hint
        anchors.horizontalCenter: parent.horizontalCenter
        y: 14
        z: 50
        width: hintText.implicitWidth + 32
        height: 32
        radius: 16
        color: "#c0161b1f"
        border.color: "#40ffffff"
        opacity: hintTimer.running ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        Text { id: hintText; anchors.centerIn: parent; color: "white"; font.pixelSize: 12; text: wall.layoutName + "  ·  Esc closes this screen" }
    }
    Timer { id: hintTimer; interval: 3000; running: true }
    MouseArea {
        anchors.fill: parent
        z: 60
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: hintTimer.restart()
    }

    Shortcut { sequence: "Escape"; onActivated: wall.close() }
}
