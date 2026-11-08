import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Ipvexa

Item {
    id: root
    property var window

    // ---- Layout state ----
    // A layout = grid preset + tile aspect + the camera in each slot (0 = empty).
    property string preset: "2x2"
    property string aspect: "16:9"
    property var slotCams: []
    property int selectedSlot: 0
    property int maximizedSlot: -1
    property string layoutName: "Default"
    property bool treeVisible: true

    readonly property var presets: ["1", "2x2", "3x3", "4x4", "5x5", "1+5", "1+7", "1+12"]
    readonly property var slots: computeSlots(preset)
    readonly property int selectedCamera: slotCams[selectedSlot] || firstCamera()

    Settings {
        id: store
        category: "layouts"
        property string saved: "[]"
        property string current: ""
        property bool treeVisible: true
    }

    function computeSlots(p) {
        // Returns [{x, y, w, h}] in grid cells, plus cols/rows on the array.
        var out = []
        var cols, rows, big = 0
        switch (p) {
        case "1": cols = rows = 1; break
        case "2x2": cols = rows = 2; break
        case "3x3": cols = rows = 3; break
        case "4x4": cols = rows = 4; break
        case "5x5": cols = rows = 5; break
        case "1+5": cols = rows = 3; big = 2; break
        case "1+7": cols = rows = 4; big = 3; break
        case "1+12": cols = rows = 4; big = 2; break
        default: cols = rows = 2
        }
        if (big > 0)
            out.push({ x: 0, y: 0, w: big, h: big })
        for (var y = 0; y < rows; y++)
            for (var x = 0; x < cols; x++)
                if (!(x < big && y < big))
                    out.push({ x: x, y: y, w: 1, h: 1 })
        out.cols = cols
        out.rows = rows
        return out
    }

    function firstCamera() {
        return Api.cameras.length > 0 ? Api.cameras[0].id : 0
    }

    function setSlotCam(slot, camId) {
        var a = slotCams.slice()
        while (a.length <= slot) a.push(0)
        // Dragging a camera that is already shown moves it instead of duplicating it.
        var existing = a.indexOf(camId)
        if (camId > 0 && existing >= 0 && existing !== slot)
            a[existing] = a[slot] || 0
        a[slot] = camId
        slotCams = a
        selectedSlot = slot
        persistCurrent()
    }

    function placeCamera(camId) {
        var a = slotCams
        for (var i = 0; i < slots.length; i++)
            if (!(a[i] > 0)) { setSlotCam(i, camId); return }
        setSlotCam(selectedSlot, camId)
    }

    function setPreset(p) {
        preset = p
        maximizedSlot = -1
        if (selectedSlot >= computeSlots(p).length) selectedSlot = 0
        persistCurrent()
    }

    function autoFill() {
        var ids = Api.cameras.map(function (c) { return c.id })
        var n = ids.length
        preset = n <= 1 ? "1" : n <= 4 ? "2x2" : n <= 6 ? "1+5" : n <= 9 ? "3x3" : n <= 13 ? "1+12" : n <= 16 ? "4x4" : "5x5"
        slotCams = ids.slice(0, computeSlots(preset).length)
    }

    function savedLayouts() {
        try { return JSON.parse(store.saved) } catch (e) { return [] }
    }

    function persistCurrent() {
        store.current = JSON.stringify({ name: layoutName, preset: preset, aspect: aspect, cams: slotCams })
    }

    function saveLayout(name) {
        var list = savedLayouts().filter(function (l) { return l.name !== name })
        list.push({ name: name, preset: preset, aspect: aspect, cams: slotCams })
        store.saved = JSON.stringify(list)
        layoutName = name
        persistCurrent()
        tree.refreshLayouts()
    }

    function deleteLayout(name) {
        store.saved = JSON.stringify(savedLayouts().filter(function (l) { return l.name !== name }))
        tree.refreshLayouts()
    }

    function loadLayout(l) {
        layoutName = l.name
        preset = l.preset
        aspect = l.aspect || "16:9"
        slotCams = l.cams || []
        selectedSlot = 0
        maximizedSlot = -1
        persistCurrent()
    }

    Component.onCompleted: {
        treeVisible = store.treeVisible
        try {
            var c = JSON.parse(store.current)
            if (c && c.preset) { loadLayout(c); return }
        } catch (e) {}
        filler.start()
    }
    // --camera-settings <id>: open that camera's settings on start (testing / support).
    Timer {
        interval: 1500; running: Qt.application.arguments.indexOf("--camera-settings") >= 0
        onTriggered: {
            var a = Qt.application.arguments
            var cam = Theme.findCamera(Api.cameras, parseInt(a[a.indexOf("--camera-settings") + 1]))
            if (cam) { cameraDialog.load(cam); cameraDialog.open() }
        }
    }
    // First run: wait for the camera list, then fill a layout automatically.
    Timer {
        id: filler
        interval: 300; repeat: true
        onTriggered: if (Api.cameras.length > 0) { stop(); autoFill(); persistCurrent() }
    }

    Item { id: dragLayer; anchors.fill: parent; z: 100 }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------- Top bar ----------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.panel
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 6

                IconButton { glyph: "☰"; tip: "Show/hide resource tree"; active: root.treeVisible
                    onClicked: { root.treeVisible = !root.treeVisible; store.treeVisible = root.treeVisible } }
                Rectangle {
                    width: 24; height: 24; radius: 6
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#3b9bff" }
                        GradientStop { position: 1; color: "#1f5fd1" }
                    }
                    Text { anchors.centerIn: parent; text: "◉"; color: "white"; font.pixelSize: 14 }
                }
                Text { text: "Ipvexa"; color: Theme.text; font.pixelSize: 15; font.weight: Font.Bold }
                Rectangle { width: 1; height: 22; color: Theme.border; Layout.leftMargin: 8; Layout.rightMargin: 8 }
                ToolText { text: root.layoutName; color: Theme.text; font.weight: Font.DemiBold }
                Item { width: 10 }

                Repeater {
                    model: root.presets
                    IconButton {
                        text: modelData
                        size: 26
                        active: root.preset === modelData
                        tip: "Layout " + modelData
                        onClicked: root.setPreset(modelData)
                    }
                }
                Rectangle { width: 1; height: 22; color: Theme.border; Layout.leftMargin: 6; Layout.rightMargin: 6 }
                Repeater {
                    model: ["16:9", "4:3", "Fill"]
                    IconButton {
                        text: modelData
                        size: 26
                        active: root.aspect === modelData
                        tip: "Tile aspect ratio"
                        onClicked: { root.aspect = modelData; root.persistCurrent() }
                    }
                }
                IconButton { glyph: "💾"; tip: "Save layout as…"; onClicked: saveDialog.open() }

                Item { Layout.fillWidth: true }

                ToolText {
                    property var d: Api.system.disk
                    visible: !!d && d.total > 0
                    text: d ? "Storage " + (100 - d.free * 100 / d.total).toFixed(0) + "% used · "
                              + (d.free / 1e9).toFixed(0) + " GB free" : ""
                }
                Rectangle { width: 1; height: 22; color: Theme.border; Layout.leftMargin: 6; Layout.rightMargin: 6 }
                ToolText { text: Api.username + " · " + Api.role }
                IconButton { glyph: "⏻"; tip: "Sign out"; onClicked: Api.logout() }
            }
        }

        // ---------- Body ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ResourceTree {
                id: tree
                visible: root.treeVisible
                Layout.preferredWidth: 270
                Layout.fillHeight: true
                dragLayer: dragLayer
                layouts: root.savedLayouts()
                currentLayout: root.layoutName
                onCameraActivated: (id) => root.placeCamera(id)
                onEditCamera: (id) => { cameraDialog.load(Api.camera(id)); cameraDialog.open() }
                onAddCamera: { cameraDialog.load(null); cameraDialog.open() }
                onLayoutActivated: (l) => root.loadLayout(l)
                onDeleteLayout: (name) => root.deleteLayout(name)
                onNewLayout: { root.layoutName = "New layout"; root.slotCams = []; root.persistCurrent() }
                function refreshLayouts() { layouts = root.savedLayouts() }
            }
            Rectangle { visible: root.treeVisible; Layout.fillHeight: true; width: 1; color: Theme.border }

            SceneView {
                id: scene
                Layout.fillWidth: true
                Layout.fillHeight: true
                slots: root.slots
                slotCams: root.slotCams
                aspect: root.aspect
                selectedSlot: root.selectedSlot
                maximizedSlot: root.maximizedSlot
                dragLayer: dragLayer
                onSlotSelected: (i) => root.selectedSlot = i
                onSlotMaximizeToggled: (i) => root.maximizedSlot = (root.maximizedSlot === i ? -1 : i)
                onCameraDropped: (slot, camId) => root.setSlotCam(slot, camId)
                onSlotCleared: (i) => root.setSlotCam(i, 0)
                onCameraSettingsRequested: (id) => { cameraDialog.load(Theme.findCamera(Api.cameras, id)); cameraDialog.open() }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        // ---------- Timeline ----------
        Timeline {
            Layout.fillWidth: true
            Layout.preferredHeight: 92
            cameraId: root.selectedCamera
            cameraName: (Theme.findCamera(Api.cameras, root.selectedCamera) || {}).name || ""
        }
    }

    Shortcut { sequence: "Space"; onActivated: Clock.togglePlay() }
    Shortcut { sequence: "Escape"; onActivated: root.maximizedSlot = -1 }
    Shortcut { sequence: "Left"; onActivated: Clock.step(-10000) }
    Shortcut { sequence: "Right"; onActivated: Clock.step(10000) }
    Shortcut { sequence: "L"; onActivated: Clock.goLive() }
    Shortcut { sequences: [StandardKey.Delete]; onActivated: root.setSlotCam(root.selectedSlot, 0) }

    CameraDialog { id: cameraDialog; anchors.centerIn: parent }

    AppDialog {
        id: saveDialog
        title: "Save layout"
        modal: true
        standardButtons: Dialog.Save | Dialog.Cancel
        onOpened: { nameField.text = root.layoutName; nameField.selectAll(); nameField.forceActiveFocus() }
        onAccepted: if (nameField.text.trim().length > 0) root.saveLayout(nameField.text.trim())
        TextField { id: nameField; width: 280; onAccepted: saveDialog.accept() }
    }
}
