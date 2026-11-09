pragma Singleton
import QtQuick

QtObject {
    // Surfaces (darkest to lightest)
    // Slate tones in the spirit of Nx Witness.
    readonly property color bg: "#101417"
    readonly property color scene: "#0a0d0f"
    readonly property color panel: "#192024"
    readonly property color panelAlt: "#212a2f"
    readonly property color raised: "#2a343a"
    readonly property color border: "#263036"
    readonly property color borderStrong: "#36434a"

    // Text
    readonly property color text: "#e3e8eb"
    readonly property color textDim: "#98a6ae"
    readonly property color textFaint: "#5e6c74"

    // Accents
    readonly property color accent: "#2fa8e0"
    readonly property color accentSoft: "#153a4d"
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

    // A camera's state: its main stream's, except that an idle on-demand main stream
    // (high quality not being watched) means "look at the substream".
    function cameraState(cam) {
        if (!cam) return "offline"
        if (!cam.enabled) return "disabled"
        var m = cam.status && cam.status.main ? cam.status.main : null
        var s = cam.status && cam.status.sub ? cam.status.sub : null
        if (m && m.state === "idle") return s ? s.state : "online"
        return m ? m.state : "offline"
    }

    function stateColor(state) {
        switch (state) {
        case "online": return online
        case "idle": return online   // on-demand high-quality stream, not watched right now
        case "starting": return warn
        case "offline": return live
        default: return offline
        }
    }
}
