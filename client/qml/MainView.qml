import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtCore
import Ipvexa
import "LayoutEngine.js" as LE

Item {
    id: root
    property var window

    // ---- Layout state (all layouts are saved automatically) ----
    property var layouts: []          // every layout
    property var tabs: []             // names of layouts open as tabs
    property string active: ""        // name of the active tab
    property int selectedIndex: -1
    property int maximizedIndex: -1
    property bool treeVisible: true
    property bool rightVisible: true
    property bool fullscreenMode: false
    property int prevVisibility: Window.Windowed

    readonly property var cur: findLayout(active) || LE.make(active, 2, 2)
    readonly property int selectedCamera: {
        var it = cur.items[selectedIndex]
        return it ? it.cam : (cur.items.length > 0 ? cur.items[0].cam : 0)
    }

    Settings {
        id: store
        category: "layouts"
        property string all: ""
        property string tabs: ""
        property string active: ""
        property bool treeVisible: true
        property bool rightVisible: true
        // Ipvexa 0.1 keys, migrated once
        property string saved: "[]"
        property string current: ""
    }

    function findLayout(name) {
        for (var i = 0; i < layouts.length; i++) if (layouts[i].name === name) return layouts[i]
        return null
    }
    function persist() {
        store.all = JSON.stringify(layouts)
        store.tabs = JSON.stringify(tabs)
        store.active = active
    }
    // Replace the active layout with fn(active layout).
    function update(fn) {
        var next = fn(cur)
        if (!next) return
        next.name = active
        var list = layouts.slice(), found = false
        for (var i = 0; i < list.length; i++) if (list[i].name === active) { list[i] = next; found = true }
        if (!found) list.push(next)
        layouts = list
        if (selectedIndex >= next.items.length) selectedIndex = next.items.length - 1
        if (maximizedIndex >= next.items.length) maximizedIndex = -1
        persist()
    }
    function uniqueName(base) {
        var n = 1, name = base
        while (findLayout(name)) name = base + " " + (++n)
        return name
    }
    function openLayout(name) {
        if (!findLayout(name)) return
        if (tabs.indexOf(name) < 0) tabs = tabs.concat([name])
        active = name
        selectedIndex = -1
        maximizedIndex = -1
        persist()
    }
    function newLayout() {
        var name = uniqueName("Layout")
        layouts = layouts.concat([LE.make(name, 2, 2)])
        openLayout(name)
    }
    function closeTab(name) {
        if (tabs.length <= 1) return
        var i = tabs.indexOf(name)
        tabs = tabs.filter(function (t) { return t !== name })
        if (active === name) active = tabs[Math.max(0, i - 1)]
        maximizedIndex = -1
        persist()
    }
    function renameLayout(oldName, newName) {
        newName = newName.trim()
        if (newName === "" || newName === oldName || findLayout(newName)) return
        layouts = layouts.map(function (l) { if (l.name === oldName) { var c = LE.clone(l); c.name = newName; return c } return l })
        tabs = tabs.map(function (t) { return t === oldName ? newName : t })
        if (active === oldName) active = newName
        persist()
    }
    function duplicateLayout(name) {
        var l = findLayout(name)
        if (!l) return
        var c = LE.clone(l)
        c.name = uniqueName(name + " copy")
        layouts = layouts.concat([c])
        openLayout(c.name)
    }
    function deleteLayout(name) {
        if (layouts.length <= 1) return
        layouts = layouts.filter(function (l) { return l.name !== name })
        tabs = tabs.filter(function (t) { return t !== name })
        if (tabs.length === 0) tabs = [layouts[0].name]
        if (active === name || tabs.indexOf(active) < 0) active = tabs[0]
        persist()
    }

    function enterFullscreen(index) {
        if (!fullscreenMode) prevVisibility = window.visibility
        fullscreenMode = true
        maximizedIndex = index
        selectedIndex = index
        window.visibility = Window.FullScreen
    }
    function exitFullscreen() {
        if (!fullscreenMode) { maximizedIndex = -1; return }
        fullscreenMode = false
        maximizedIndex = -1
        window.visibility = prevVisibility === Window.FullScreen ? Window.Windowed : prevVisibility
    }

    Component.onCompleted: {
        treeVisible = store.treeVisible
        rightVisible = store.rightVisible
        var all = []
        try { all = JSON.parse(store.all || "[]") } catch (e) { all = [] }
        if (all.length === 0) {
            // Migrate layouts from Ipvexa 0.1, if any.
            try { JSON.parse(store.saved || "[]").forEach(function (l) { all.push(LE.migrate(l)) }) } catch (e) {}
            try {
                var c = JSON.parse(store.current || "")
                if (c && c.preset) {
                    var m = LE.migrate(c)
                    all = all.filter(function (l) { return l.name !== m.name })
                    all.unshift(m)
                }
            } catch (e) {}
        }
        all = all.map(function (l) { return LE.migrate(l) })
        var t = []
        try { t = JSON.parse(store.tabs || "[]") } catch (e) { t = [] }
        if (all.length === 0) {
            all = [LE.make("Layout 1", 2, 2)]
            filler.start()
        }
        layouts = all
        tabs = t.filter(function (n) { return all.some(function (l) { return l.name === n }) })
        if (tabs.length === 0) tabs = [all[0].name]
        active = tabs.indexOf(store.active) >= 0 ? store.active : tabs[0]
        persist()
    }
    // First run: fill the first layout with the cameras once they've loaded.
    Timer {
        id: filler
        interval: 300; repeat: true
        onTriggered: if (Api.cameras.length > 0) {
            stop()
            if (root.cur.items.length === 0)
                root.update(function (l) { return LE.autoLayout(l.name, Api.cameras.map(function (c) { return c.id })) })
        }
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

    Item { id: dragLayer; anchors.fill: parent; z: 100 }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------- Title bar: logo + layout tabs ----------
        Rectangle {
            visible: !root.fullscreenMode
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: "#13181b"
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 0

                Rectangle {
                    width: 22; height: 22; radius: 6
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#46b8ec" }
                        GradientStop { position: 1; color: "#1d74b8" }
                    }
                    Rectangle { anchors.centerIn: parent; width: 10; height: 10; radius: 5; color: "transparent"; border.color: "white"; border.width: 2 }
                }
                Text { text: "Ipvexa"; color: Theme.text; font.pixelSize: 14; font.weight: Font.Bold; Layout.leftMargin: 8; Layout.rightMargin: 16 }

                // Tabs
                Repeater {
                    model: root.tabs
                    Rectangle {
                        id: tabItem
                        required property string modelData
                        readonly property bool isActive: modelData === root.active
                        Layout.preferredHeight: 40
                        Layout.preferredWidth: Math.min(200, tabRow.implicitWidth + 28)
                        color: isActive ? Theme.scene : tabMa.containsMouse ? "#1b2226" : "transparent"
                        Rectangle { visible: tabItem.isActive; anchors.top: parent.top; width: parent.width; height: 2; color: Theme.accent }
                        Rectangle { anchors.right: parent.right; height: parent.height; width: 1; color: Theme.border }
                        MouseArea {
                            id: tabMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                            onClicked: (m) => {
                                if (m.button === Qt.MiddleButton) root.closeTab(tabItem.modelData)
                                else if (m.button === Qt.RightButton) tabMenu.popup()
                                else root.openLayout(tabItem.modelData)
                            }
                            onDoubleClicked: { renameDialog.target = tabItem.modelData; renameDialog.open() }
                        }
                        Row {
                            id: tabRow
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            TileIcon { kind: "layout"; width: 12; height: 12; color: tabItem.isActive ? Theme.accent : Theme.textFaint; anchors.verticalCenter: parent.verticalCenter }
                            Text {
                                text: tabItem.modelData
                                color: tabItem.isActive ? Theme.text : Theme.textDim
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                width: Math.min(implicitWidth, 130)
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Rectangle {
                                visible: root.tabs.length > 1 && (tabMa.containsMouse || tabItem.isActive || closeMa.containsMouse)
                                width: 16; height: 16; radius: 3
                                anchors.verticalCenter: parent.verticalCenter
                                color: closeMa.containsMouse ? "#40ffffff" : "transparent"
                                TileIcon { anchors.centerIn: parent; kind: "close"; width: 8; height: 8; color: Theme.textDim; lineWidth: 1.4 }
                                MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.closeTab(tabItem.modelData) }
                            }
                        }
                        Menu {
                            id: tabMenu
                            MenuItem { text: "Rename…"; onTriggered: { renameDialog.target = tabItem.modelData; renameDialog.open() } }
                            MenuItem { text: "Duplicate"; onTriggered: root.duplicateLayout(tabItem.modelData) }
                            MenuItem { text: "Close tab"; enabled: root.tabs.length > 1; onTriggered: root.closeTab(tabItem.modelData) }
                        }
                    }
                }
                Rectangle {
                    Layout.preferredWidth: 34
                    Layout.preferredHeight: 40
                    color: newMa.containsMouse ? "#1b2226" : "transparent"
                    TileIcon { anchors.centerIn: parent; kind: "plus"; width: 12; height: 12; color: Theme.textDim }
                    MouseArea {
                        id: newMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.newLayout()
                        ToolTip.visible: containsMouse; ToolTip.text: "New layout tab"; ToolTip.delay: 500
                    }
                }

                Item { Layout.fillWidth: true }

                ToolText {
                    property var d: Api.system.disk
                    visible: !!d && d.total > 0
                    text: d ? (100 - d.free * 100 / d.total).toFixed(0) + "% storage used" : ""
                    Layout.rightMargin: 14
                }
                ToolText { text: Api.username; color: Theme.text; Layout.rightMargin: 4 }
                IconButton { glyph: "⏻"; size: 28; tip: "Sign out"; onClicked: Api.logout() }
            }
        }

        // ---------- Body ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ResourceTree {
                id: tree
                visible: root.treeVisible && !root.fullscreenMode
                Layout.preferredWidth: 260
                Layout.fillHeight: true
                dragLayer: dragLayer
                layouts: root.layouts
                currentLayout: root.active
                onCameraActivated: (id) => root.update(function (l) { return LE.addCamera(l, id) })
                onEditCamera: (id) => { cameraDialog.load(Theme.findCamera(Api.cameras, id)); cameraDialog.open() }
                onAddCamera: { cameraDialog.load(null); cameraDialog.open() }
                onLayoutActivated: (name) => root.openLayout(name)
                onDeleteLayout: (name) => root.deleteLayout(name)
                onRenameLayout: (name) => { renameDialog.target = name; renameDialog.open() }
                onDuplicateLayout: (name) => root.duplicateLayout(name)
                onNewLayout: root.newLayout()
            }
            Rectangle { visible: tree.visible; Layout.fillHeight: true; width: 1; color: Theme.border }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Scene toolbar
                Rectangle {
                    visible: !root.fullscreenMode
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34
                    color: "#161c1f"
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 2
                        IconButton { glyph: "☰"; size: 26; tip: "Show/hide resource tree"; active: root.treeVisible
                            onClicked: { root.treeVisible = !root.treeVisible; store.treeVisible = root.treeVisible } }
                        Rectangle { width: 1; height: 18; color: Theme.border; Layout.leftMargin: 4; Layout.rightMargin: 4 }
                        ToolText { text: "Arrange"; color: Theme.textFaint; Layout.rightMargin: 4 }
                        Repeater {
                            model: LE.PRESETS
                            IconButton { text: modelData; size: 24; tip: "Arrange cameras as " + modelData
                                onClicked: { root.maximizedIndex = -1; root.update(function (l) { return LE.applyPreset(l, modelData) }) } }
                        }
                        Rectangle { width: 1; height: 18; color: Theme.border; Layout.leftMargin: 4; Layout.rightMargin: 4 }
                        ToolText { text: "Grid " + root.cur.cols + "×" + root.cur.rows; color: Theme.textDim; Layout.rightMargin: 4 }
                        IconButton { text: "−col"; size: 24; tip: "Remove a column"; onClicked: root.update(function (l) { return LE.setGrid(l, l.cols - 1, l.rows) }) }
                        IconButton { text: "+col"; size: 24; tip: "Add a column"; onClicked: root.update(function (l) { return LE.setGrid(l, l.cols + 1, l.rows) }) }
                        IconButton { text: "−row"; size: 24; tip: "Remove a row"; onClicked: root.update(function (l) { return LE.setGrid(l, l.cols, l.rows - 1) }) }
                        IconButton { text: "+row"; size: 24; tip: "Add a row"; onClicked: root.update(function (l) { return LE.setGrid(l, l.cols, l.rows + 1) }) }
                        Rectangle { width: 1; height: 18; color: Theme.border; Layout.leftMargin: 4; Layout.rightMargin: 4 }
                        Repeater {
                            model: ["16:9", "4:3", "Fill"]
                            IconButton { text: modelData; size: 24; active: root.cur.aspect === modelData; tip: "Tile shape"
                                onClicked: root.update(function (l) { var c = LE.clone(l); c.aspect = modelData; return c }) }
                        }
                        Item { Layout.fillWidth: true }
                        IconButton {
                            size: 26; tip: "Full screen (F11)"
                            onClicked: window.visibility = window.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
                            TileIcon { anchors.centerIn: parent; kind: "fullscreen"; width: 13; height: 13; color: Theme.text }
                        }
                        IconButton {
                            size: 26; tip: "Show/hide notifications & health"; active: root.rightVisible
                            onClicked: { root.rightVisible = !root.rightVisible; store.rightVisible = root.rightVisible }
                            TileIcon { anchors.centerIn: parent; kind: "panel"; width: 13; height: 13; color: parent.active ? Theme.accent : Theme.text }
                        }
                    }
                }

                SceneView {
                    id: scene
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    layout: root.cur
                    selectedIndex: root.selectedIndex
                    maximizedIndex: root.maximizedIndex
                    dragLayer: dragLayer
                    onItemSelected: (i) => root.selectedIndex = i
                    onMaximizeToggled: (i) => {
                        if (root.fullscreenMode) { root.exitFullscreen(); return }
                        root.maximizedIndex = (root.maximizedIndex === i ? -1 : i)
                    }
                    onFullscreenRequested: (i) => {
                        if (root.fullscreenMode && root.maximizedIndex === i) root.exitFullscreen()
                        else root.enterFullscreen(i)
                    }
                    onRemoveRequested: (i) => {
                        if (root.maximizedIndex === i) root.exitFullscreen()
                        root.update(function (l) { return LE.removeItem(l, i) })
                    }
                    onCameraSettingsRequested: (id) => { cameraDialog.load(Theme.findCamera(Api.cameras, id)); cameraDialog.open() }
                    onCameraDropped: (cam, x, y) => root.update(function (l) { return LE.addCamera(l, cam, x, y) })
                    onItemMoved: (i, x, y) => root.update(function (l) { return LE.moveItem(l, i, x, y) })
                    onItemResized: (i, w, h) => root.update(function (l) { return LE.resizeItem(l, i, w, h) })
                    onBackgroundMenuRequested: sceneMenu.popup()
                }
            }

            Rectangle { visible: right.visible; Layout.fillHeight: true; width: 1; color: Theme.border }
            RightPanel {
                id: right
                visible: root.rightVisible && !root.fullscreenMode
                Layout.preferredWidth: 290
                Layout.fillHeight: true
                onCameraFocusRequested: (cam, t) => {
                    root.update(function (l) { return LE.addCamera(l, cam) })
                    for (var i = 0; i < root.cur.items.length; i++) if (root.cur.items[i].cam === cam) root.selectedIndex = i
                    Clock.seek(t - 10000)
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        Timeline {
            Layout.fillWidth: true
            Layout.preferredHeight: 92
            cameraId: root.selectedCamera
            cameraName: (Theme.findCamera(Api.cameras, root.selectedCamera) || {}).name || ""
        }
    }

    Menu {
        id: sceneMenu
        Menu {
            title: "Arrange as"
            Repeater {
                model: LE.PRESETS
                MenuItem { text: modelData; onTriggered: root.update(function (l) { return LE.applyPreset(l, modelData) }) }
            }
        }
        MenuItem { text: "Add column"; onTriggered: root.update(function (l) { return LE.setGrid(l, l.cols + 1, l.rows) }) }
        MenuItem { text: "Add row"; onTriggered: root.update(function (l) { return LE.setGrid(l, l.cols, l.rows + 1) }) }
        MenuItem { text: "Shrink grid to fit cameras"
            onTriggered: root.update(function (l) { var m = LE.minGrid(l); return LE.setGrid(l, m.cols, m.rows) }) }
        MenuSeparator {}
        MenuItem { text: "Clear layout"; onTriggered: root.update(function (l) { var c = LE.clone(l); c.items = []; return c }) }
        MenuItem { text: "New layout tab"; onTriggered: root.newLayout() }
    }

    Shortcut { sequence: "Space"; onActivated: Clock.togglePlay() }
    Shortcut { sequence: "Escape"; onActivated: root.exitFullscreen() }
    Shortcut { sequence: "Left"; onActivated: Clock.step(-10000) }
    Shortcut { sequence: "Right"; onActivated: Clock.step(10000) }
    Shortcut { sequence: "L"; onActivated: Clock.goLive() }
    Shortcut {
        sequences: [StandardKey.Delete]
        onActivated: if (root.selectedIndex >= 0) {
            var i = root.selectedIndex
            root.selectedIndex = -1
            root.update(function (l) { return LE.removeItem(l, i) })
        }
    }
    Shortcut { sequences: [StandardKey.AddTab]; onActivated: root.newLayout() }

    CameraDialog { id: cameraDialog }

    AppDialog {
        id: renameDialog
        property string target: ""
        title: "Rename layout"
        standardButtons: Dialog.Save | Dialog.Cancel
        onOpened: { renameField.text = target; renameField.selectAll(); renameField.forceActiveFocus() }
        onAccepted: root.renameLayout(target, renameField.text)
        TextField { id: renameField; width: 280; onAccepted: renameDialog.accept() }
    }
}
