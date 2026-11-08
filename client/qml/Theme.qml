pragma Singleton
import QtQuick

QtObject {
    // Surfaces (darkest to lightest)
    readonly property color bg: "#0d0f13"
    readonly property color scene: "#08090c"
    readonly property color panel: "#14171c"
    readonly property color panelAlt: "#1a1e25"
    readonly property color raised: "#222833"
    readonly property color border: "#262c36"
    readonly property color borderStrong: "#363e4b"

    // Text
    readonly property color text: "#e6e8ec"
    readonly property color textDim: "#9aa3b2"
    readonly property color textFaint: "#5f6876"

    // Accents
    readonly property color accent: "#2f8cff"
    readonly property color accentSoft: "#1d3d66"
    readonly property color online: "#2fbf71"
    readonly property color recorded: "#2a9d63"
    readonly property color recordedHi: "#38c27d"
    readonly property color live: "#ff4757"
    readonly property color warn: "#f5a524"
    readonly property color offline: "#8a93a3"

    readonly property int radius: 6
    readonly property int gap: 2
    readonly property string mono: "monospace"

    // Look up a camera in a camera list. Taking the list as an argument makes bindings
    // re-evaluate whenever Api.cameras changes.
    function findCamera(list, id) {
        if (!list || id <= 0) return null
        for (var i = 0; i < list.length; i++)
            if (list[i].id === id) return list[i]
        return null
    }

    function stateColor(state) {
        switch (state) {
        case "online": return online
        case "starting": return warn
        case "offline": return live
        default: return offline
        }
    }
}
