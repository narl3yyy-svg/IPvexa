import QtQuick

// IPvexa mark: a lens in a rounded square, with a "recording" dot.
Rectangle {
    id: root
    property real size: 22
    width: size; height: size
    radius: size * 0.24
    gradient: Gradient {
        GradientStop { position: 0; color: "#46b8ec" }
        GradientStop { position: 1; color: "#1d74b8" }
    }
    Rectangle {
        anchors.centerIn: parent
        width: root.size * 0.56; height: width; radius: width / 2
        color: "transparent"
        border.color: "white"
        border.width: Math.max(1.5, root.size * 0.07)
        Rectangle { anchors.centerIn: parent; width: root.size * 0.22; height: width; radius: width / 2; color: "white" }
    }
    Rectangle {
        x: root.size * 0.68; y: root.size * 0.14
        width: root.size * 0.16; height: width; radius: width / 2
        color: "#ff4757"
    }
}
