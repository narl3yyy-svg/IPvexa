import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtCore
import Ipvexa
import "LayoutEngine.js" as LE

Item {
    id: root
    // The window this view lives in (for full screen).
    readonly property var win: Window.window
    property string quality: "auto"   // layout-wide stream quality: auto | high | low
    property int liveBufferMs: 600    // live smoothing: 150 fast, 600 smooth, 2500 smoothest
    // Smart search (motion inside an area of one camera)
    property int searchCam: 0
    property string searchCells: ""
    // Layout tour: cycle through the open tabs.
    property bool touring: false
    property int tourSeconds: 10
    // Playback: all cameras on the layout follow the timeline (sync), or only the selected one.
    property bool syncPlayback: true

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
        property string quality: "auto"
        property int liveBufferMs: 600
        property int tourSeconds: 10
        property bool syncPlayback: true
        // 0.1 keys, migrated once
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

    // Camera full screen: the window goes full screen showing only that camera.
    function enterFullscreen(index) {
        if (!win) return
        if (!fullscreenMode) prevVisibility = win.visibility
        fullscreenMode = true
        maximizedIndex = index
        selectedIndex = index
        win.showFullScreen()
    }
    Timer {
        interval: root.tourSeconds * 1000
        repeat: true
        running: root.touring && root.tabs.length > 1
        onTriggered: root.openLayout(root.tabs[(root.tabs.indexOf(root.active) + 1) % root.tabs.length])
    }
    onTabsChanged: if (tabs.length < 2) touring = false

    // Video walls: layouts shown full screen on other monitors.
    Component { id: wallComponent; VideoWall {} }
    function openWall(name, screenIndex) {
        var w = wallComponent.createObject(null, {
            layoutName: name,
            screen: Qt.application.screens[screenIndex],
            quality: root.quality,
            liveBufferMs: root.liveBufferMs
        })
        if (!w) return
        w.layout = Qt.binding(function () { return root.findLayout(name) || LE.make(name, 1, 1) })
        // Destroy after the close event has finished, not inside it.
        w.closing.connect(function () { Qt.callLater(function () { w.destroy() }) })
    }

    function exitFullscreen() {
        touring = false
        if (!fullscreenMode) {
            maximizedIndex = -1
            if (win && win.visibility === Window.FullScreen) win.showNormal()
            return
        }
        fullscreenMode = false
        maximizedIndex = -1
        if (!win) return
        if (prevVisibility === Window.Maximized) win.showMaximized()
        else if (prevVisibility === Window.FullScreen) win.showFullScreen()
        else win.showNormal()
    }
    // Whole-window full screen (F11), keeping the panels.
    function toggleWindowFullscreen() {
        if (!win) return
        if (fullscreenMode) { exitFullscreen(); return }
        if (win.visibility === Window.FullScreen) {
            if (prevVisibility === Window.Maximized) win.showMaximized(); else win.showNormal()
        } else {
            prevVisibility = win.visibility
            win.showFullScreen()
        }
    }

    Component.onCompleted: {
        treeVisible = store.treeVisible
        rightVisible = store.rightVisible
        quality = ["auto", "high", "low"].indexOf(store.quality) >= 0 ? store.quality : "auto"
        tourSeconds = Math.max(3, Math.min(600, store.tourSeconds))
        syncPlayback = store.syncPlayback
        liveBufferMs = [150, 600, 2500].indexOf(store.liveBufferMs) >= 0 ? store.liveBufferMs : 600
        var all = []
        try { all = JSON.parse(store.all || "[]") } catch (e) { all = [] }
        if (all.length === 0) {
            // Migrate layouts from version 0.1, if any.
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
    // --open <what>[,<what>…]: open dialogs or views on start (testing / support).
    // what = users | password | signout | addcamera | fullscreen:<tile> | maximize:<tile>
    //        | add:<camera> | arrange | fit:<fit|fill|stretch> | sync:<on|off> | seek:<minutes ago>
    Timer {
        interval: 2500; running: Qt.application.arguments.indexOf("--open") >= 0
        onTriggered: {
            var a = Qt.application.arguments
            String(a[a.indexOf("--open") + 1] || "").split(",").forEach(function (what) { root.openForTesting(what.split(":")) })
        }
    }
    function openForTesting(w) {
        switch (w[0]) {
        case "add": root.update(function (l) { // another tile of a camera (even if it is already shown)
            var i = LE.indexOfCam(l, parseInt(w[1]))
            return i >= 0 ? LE.duplicateItem(l, i) : LE.addCamera(l, parseInt(w[1]))
        }); break
        case "arrange": root.update(function (l) { return LE.fillScreen(l) }); break
        case "fit": root.update(function (l) { return LE.setFit(l, w[1]) }); break
        case "sync": root.syncPlayback = w[1] !== "off"; break
        case "select": root.selectedIndex = parseInt(w[1] || "0"); break
        case "seek": Clock.seek(Date.now() - parseInt(w[1] || "5") * 60000); break
        case "users": usersDialog.open(); break
        case "password": passwordDialog.open(); break
        case "signout": logoutConfirm.open(); break
        case "addcamera": cameraDialog.load(null); cameraDialog.open(); break
        case "notifications": notificationsDialog.startPage = parseInt(w[1] || "0"); notificationsDialog.open(); break
        case "audit": auditDialog.open(); break
        case "settings": serverSettingsDialog.open(); break
        case "tour": root.touring = true; break
        case "wall": root.openWall(root.active, parseInt(w[1] || "0")); break
        case "export": exportDialog.openAt(root.selectedCamera, "Camera", Date.now() - 300000, Date.now() - 240000); if (w[1] === "run") exportDialog.run(); break
        case "camera": {
            var c = Theme.findCamera(Api.cameras, parseInt(w[1]))
            if (c) { cameraDialog.load(c); cameraDialog.open(); cameraDialog.page = parseInt(w[2] || "0") }
            break
        }
        case "events": root.rightVisible = true; right.tab = 1; break
        case "fullscreen": root.enterFullscreen(parseInt(w[1] || "0")); break
        case "maximize": root.maximizedIndex = parseInt(w[1] || "0"); break
        }
    }

    Item { id: dragLayer; anchors.fill: parent; z: 100 }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------- Title bar: logo + layout tabs + user ----------
        Rectangle {
            visible: !root.fullscreenMode
            Layout.fillWidth: true
            Layout.preferredHeight: 42
            color: "#12171a"
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 8
                spacing: 0

                Logo { size: 22; Layout.alignment: Qt.AlignVCenter }
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: 9
                    Layout.rightMargin: 18
                    text: "IPvexa"
                    color: Theme.text
                    font.pixelSize: 15
                    font.weight: Font.Bold
                    font.letterSpacing: 0.3
                }

                // Tabs
                Repeater {
                    model: root.tabs
                    Rectangle {
                        id: tabItem
                        required property string modelData
                        readonly property bool isActive: modelData === root.active
                        readonly property bool showClose: root.tabs.length > 1 && (tabMa.containsMouse || isActive || closeMa.containsMouse)
                        Layout.fillHeight: true
                        Layout.preferredWidth: Math.min(220, tabLabel.implicitWidth + 82)
                        color: isActive ? Theme.scene : tabMa.containsMouse ? "#192024" : "transparent"
                        Rectangle { visible: tabItem.isActive; anchors.top: parent.top; width: parent.width; height: 2; color: Theme.accent }
                        Rectangle { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; height: parent.height - 16; width: 1; color: Theme.border; visible: !tabItem.isActive }
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
                        TileIcon {
                            id: tabIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            kind: "layout"; width: 12; height: 12
                            color: tabItem.isActive ? Theme.accent : Theme.textFaint
                        }
                        Text {
                            id: tabLabel
                            anchors.left: tabIcon.right
                            anchors.leftMargin: 8
                            anchors.right: tabClose.left
                            anchors.rightMargin: 6
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            verticalAlignment: Text.AlignVCenter
                            text: tabItem.modelData
                            color: tabItem.isActive ? Theme.text : Theme.textDim
                            font.pixelSize: 12
                            font.weight: tabItem.isActive ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            id: tabClose
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18; radius: 4
                            opacity: tabItem.showClose ? 1 : 0
                            color: closeMa.containsMouse ? "#33ffffff" : "transparent"
                            TileIcon { anchors.centerIn: parent; kind: "close"; width: 8; height: 8; color: closeMa.containsMouse ? Theme.text : Theme.textDim; lineWidth: 1.4 }
                            MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; enabled: tabItem.showClose; onClicked: root.closeTab(tabItem.modelData) }
                        }
                        Menu {
                            id: tabMenu
                            MenuItem { text: "Rename…"; onTriggered: { renameDialog.target = tabItem.modelData; renameDialog.open() } }
                            MenuItem { text: "Duplicate"; onTriggered: root.duplicateLayout(tabItem.modelData) }
                            MenuItem { text: "Close tab"; enabled: root.tabs.length > 1; onTriggered: root.closeTab(tabItem.modelData) }
                            MenuSeparator {}
                            Menu {
                                title: "Show full screen on"
                                Repeater {
                                    model: Qt.application.screens
                                    MenuItem {
                                        required property var modelData
                                        required property int index
                                        text: "Screen " + (index + 1) + "  ·  " + modelData.width + "×" + modelData.height + (modelData.name ? "  (" + modelData.name + ")" : "")
                                        onTriggered: root.openWall(tabItem.modelData, index)
                                    }
                                }
                            }
                        }
                    }
                }
                IconButton {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: 4
                    iconKind: "plus"; iconSize: 12; size: 28
                    tip: "New layout tab (Ctrl+T)"
                    onClicked: root.newLayout()
                }

                Item { Layout.fillWidth: true }

                // Storage gauge
                Row {
                    property var d: Api.system.disk
                    readonly property real used: d && d.total > 0 ? 1 - d.free / d.total : 0
                    visible: !!d && d.total > 0
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 16
                    spacing: 8
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Storage"; color: Theme.textFaint; font.pixelSize: 11 }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 70; height: 5; radius: 2.5
                        color: Theme.raised
                        Rectangle {
                            width: parent.width * parent.parent.used; height: parent.height; radius: 2.5
                            color: parent.parent.used > 0.9 ? Theme.live : parent.parent.used > 0.75 ? Theme.warn : Theme.accent
                        }
                    }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: (parent.used * 100).toFixed(0) + "%"; color: Theme.textDim; font.pixelSize: 11 }
                }

                // User button + menu
                AbstractButton {
                    id: userBtn
                    Layout.alignment: Qt.AlignVCenter
                    implicitHeight: 32
                    implicitWidth: userRow.implicitWidth + 16
                    hoverEnabled: true
                    onClicked: userMenu.popup(userBtn, userBtn.width - userMenu.width, userBtn.height + 4)
                    background: Rectangle { radius: 6; color: userBtn.down || userMenu.visible ? Theme.raised : userBtn.hovered ? Theme.panelAlt : "transparent" }
                    contentItem: Item {
                        Row {
                            id: userRow
                            anchors.centerIn: parent
                            spacing: 8
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 24; height: 24; radius: 12
                                color: Api.isAdmin ? "#1f5f86" : "#2b4a3c"
                                Text {
                                    anchors.centerIn: parent
                                    text: (Api.fullName || Api.username).charAt(0).toUpperCase()
                                    color: "white"; font.pixelSize: 11; font.weight: Font.Bold
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Api.fullName || Api.username
                                color: Theme.text
                                font.pixelSize: 12
                            }
                            TileIcon { anchors.verticalCenter: parent.verticalCenter; kind: "down"; width: 10; height: 10; color: Theme.textDim }
                        }
                    }
                    Menu {
                        id: userMenu
                        width: 230
                        MenuItem {
                            enabled: false
                            text: (Api.fullName ? Api.fullName + " (" + Api.username + ")" : Api.username) + " · " + (Api.isAdmin ? "Administrator" : Api.role === "operator" ? "Operator" : "Viewer")
                        }
                        MenuSeparator {}
                        MenuItem { text: "Change password…"; onTriggered: passwordDialog.open() }
                        MenuItem { visible: Api.isAdmin; height: visible ? implicitHeight : 0; text: "User management…"; onTriggered: usersDialog.open() }
                        MenuItem { visible: Api.isAdmin; height: visible ? implicitHeight : 0; text: "Phone notifications…"; onTriggered: notificationsDialog.open() }
                        MenuItem { visible: Api.isAdmin; height: visible ? implicitHeight : 0; text: "Audit log…"; onTriggered: auditDialog.open() }
                        MenuItem { visible: Api.isAdmin; height: visible ? implicitHeight : 0; text: "Server settings…"; onTriggered: serverSettingsDialog.open() }
                        MenuItem { text: root.win && root.win.visibility === Window.FullScreen ? "Exit full screen" : "Full screen"; onTriggered: root.toggleWindowFullscreen() }
                        MenuSeparator {}
                        MenuItem { text: "Sign out…"; onTriggered: logoutConfirm.open() }
                    }
                }
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
            Rectangle { visible: tree.visible; Layout.fillHeight: true; implicitWidth: 1; color: Theme.border }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Scene toolbar
                Rectangle {
                    visible: !root.fullscreenMode
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    color: "#151b1e"
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 4
                        IconButton {
                            iconKind: "tree"; tip: "Show / hide the camera tree"; active: root.treeVisible
                            onClicked: { root.treeVisible = !root.treeVisible; store.treeVisible = root.treeVisible }
                        }
                        ToolSep {}
                        // Grid size
                        ToolText { text: "Grid"; color: Theme.textFaint; font.pixelSize: 11 }
                        Stepper {
                            value: root.cur.cols; suffix: "cols"
                            onDecrement: root.update(function (l) { return LE.setGrid(l, l.cols - 1, l.rows) })
                            onIncrement: root.update(function (l) { return LE.setGrid(l, l.cols + 1, l.rows) })
                        }
                        Stepper {
                            value: root.cur.rows; suffix: "rows"
                            onDecrement: root.update(function (l) { return LE.setGrid(l, l.cols, l.rows - 1) })
                            onIncrement: root.update(function (l) { return LE.setGrid(l, l.cols, l.rows + 1) })
                        }
                        IconButton {
                            text: "Auto-arrange"
                            enabled: root.cur.items.length > 0
                            tip: "Arrange these cameras to fill the screen with no empty tiles (for example 5 cameras: 2 on top, 3 below). Drag the borders between tiles to resize them."
                            onClicked: root.update(function (l) { return LE.fillScreen(l) })
                        }
                        ToolSep {}
                        ToolText { text: "Tiles"; color: Theme.textFaint; font.pixelSize: 11 }
                        Segmented {
                            value: root.cur.aspect
                            options: [{ value: "16:9", label: "16:9", tip: "Widescreen tiles" },
                                      { value: "4:3", label: "4:3", tip: "Classic 4:3 tiles" },
                                      { value: "Fill", label: "Fill", tip: "Stretch tiles to fill the screen" }]
                            onPicked: (v) => root.update(function (l) { var c = LE.clone(l); c.aspect = v; return c })
                        }
                        ToolSep {}
                        ToolText { text: "Quality"; color: Theme.textFaint; font.pixelSize: 11 }
                        Segmented {
                            value: root.quality
                            options: [{ value: "auto", label: "Auto", tip: "High quality for large tiles, low quality for small ones" },
                                      { value: "high", label: "High", tip: "High quality (main stream) for every tile" },
                                      { value: "low", label: "Low", tip: "Low quality (substream) for every tile: lightest on network and CPU" }]
                            onPicked: (v) => { root.quality = v; store.quality = v }
                        }
                        ToolSep {}
                        ToolText { text: "Live"; color: Theme.textFaint; font.pixelSize: 11 }
                        Segmented {
                            value: String(root.liveBufferMs)
                            options: [{ value: "150", label: "Fast", tip: "Lowest delay. Wi-Fi cameras may stutter." },
                                      { value: "600", label: "Smooth", tip: "About half a second of delay to even out uneven delivery (recommended)" },
                                      { value: "2500", label: "Smoothest", tip: "About 2.5 s of delay: hides the longer pauses of weak Wi-Fi cameras" }]
                            onPicked: (v) => { root.liveBufferMs = parseInt(v); store.liveBufferMs = root.liveBufferMs }
                        }
                        Item { Layout.fillWidth: true }
                        IconButton {
                            text: root.touring ? "Touring · " + root.tourSeconds + " s" : "Tour"
                            active: root.touring
                            enabled: root.tabs.length > 1
                            tip: root.tabs.length > 1 ? "Cycle through the open layout tabs (right-click for the interval; Esc stops)"
                                                      : "Open two or more layout tabs to tour them"
                            onClicked: root.touring = !root.touring
                            TapHandler {
                                acceptedButtons: Qt.RightButton
                                onTapped: tourMenu.popup()
                            }
                            Menu {
                                id: tourMenu
                                Repeater {
                                    model: [5, 10, 20, 30, 60]
                                    MenuItem {
                                        required property int modelData
                                        text: "Every " + modelData + " seconds"
                                        checkable: true
                                        checked: root.tourSeconds === modelData
                                        onTriggered: { root.tourSeconds = modelData; store.tourSeconds = modelData }
                                    }
                                }
                            }
                        }
                        IconButton {
                            iconKind: root.win && root.win.visibility === Window.FullScreen ? "exitfull" : "fullscreen"
                            tip: root.win && root.win.visibility === Window.FullScreen ? "Exit full screen (F11)" : "Full screen (F11)"
                            onClicked: root.toggleWindowFullscreen()
                        }
                        IconButton {
                            iconKind: "panel"; tip: "Show / hide notifications and health"; active: root.rightVisible
                            onClicked: { root.rightVisible = !root.rightVisible; store.rightVisible = root.rightVisible }
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
                    quality: root.quality
                    liveBufferMs: root.liveBufferMs
                    syncPlayback: root.syncPlayback
                    searchCells: root.searchCells
                    searchIndex: {
                        for (var i = 0; i < root.cur.items.length; i++) if (root.cur.items[i].cam === root.searchCam) return i
                        return -1
                    }
                    onItemAreaChosen: (i, cells) => {
                        root.selectedIndex = i
                        root.searchCam = cells !== "" ? root.cur.items[i].cam : 0
                        root.searchCells = cells
                        if (cells !== "") timeline.zoomTo(86400000, Date.now(), 0.9)
                    }
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
                    onItemQualityPicked: (i, q) => root.update(function (l) { return LE.setQuality(l, i, q) })
                    onItemZoomCommitted: (i, z) => root.update(function (l) { return LE.setZoom(l, i, z) })
                    onItemDuplicateRequested: (i) => root.update(function (l) { return LE.duplicateItem(l, i) })
                    onSizesCommitted: (cw, rh) => root.update(function (l) {
                        var c = LE.clone(l)
                        if (cw) c.cw = cw; else delete c.cw
                        if (rh) c.rh = rh; else delete c.rh
                        return c
                    })
                    onFitPicked: (f) => root.update(function (l) { return LE.setFit(l, f) })
                    onBackgroundMenuRequested: sceneMenu.popup()
                }
            }

            Rectangle { visible: right.visible; Layout.fillHeight: true; implicitWidth: 1; color: Theme.border }
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

        Rectangle { visible: timeline.visible; Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

        Timeline {
            id: timeline
            visible: Api.canPlayback
            Layout.fillWidth: true
            Layout.preferredHeight: 92
            cameraId: root.selectedCamera
            cameraName: (Theme.findCamera(Api.cameras, root.selectedCamera) || {}).name || ""
            searchCells: root.searchCam === root.selectedCamera ? root.searchCells : ""
            fps: scene.selectedFps
            sync: root.syncPlayback
            cameraIds: root.cur.items.map(function (it) { return it.cam })
            onSyncToggled: { root.syncPlayback = !root.syncPlayback; store.syncPlayback = root.syncPlayback }
            onSearchCleared: { root.searchCam = 0; root.searchCells = "" }
            onBookmarkRequested: (t) => bookmarkDialog.openAt(cameraId, cameraName, t)
            onExportRequested: (from, to) => exportDialog.openAt(cameraId, cameraName, from, to)
        }
    }

    Menu {
        id: sceneMenu
        MenuItem {
            text: "Fill the screen with these cameras"
            enabled: root.cur.items.length > 0
            onTriggered: root.update(function (l) { return LE.fillScreen(l) })
        }
        MenuItem {
            text: "Make columns and rows equal"
            enabled: LE.hasCustomSizes(root.cur)
            onTriggered: root.update(function (l) { return LE.evenSizes(l) })
        }
        MenuItem {
            text: "Maximize frames"
            checkable: true
            checked: root.cur.fit === "fill"
            onTriggered: root.update(function (l) { return LE.setFit(l, l.fit === "fill" ? "fit" : "fill") })
        }
        MenuSeparator {}
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
    Shortcut { sequence: "F11"; onActivated: root.toggleWindowFullscreen() }
    Shortcut { sequence: ","; onActivated: timeline.stepFrame(-1) }
    Shortcut { sequence: "."; onActivated: timeline.stepFrame(1) }

    // "Exit full screen" pill, shown at the top while a camera is full screen and the
    // mouse is near the top edge.
    MouseArea {
        id: topEdge
        visible: root.fullscreenMode
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 70
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        z: 50
    }
    Rectangle {
        z: 51
        visible: opacity > 0
        opacity: root.fullscreenMode && (topEdge.containsMouse || exitMa.containsMouse || pillTimer.running) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        anchors.horizontalCenter: parent.horizontalCenter
        y: 14
        width: exitText.implicitWidth + 32
        height: 34
        radius: 17
        color: exitMa.containsMouse ? "#e0263038" : "#c0161b1f"
        border.color: "#40ffffff"
        Text { id: exitText; anchors.centerIn: parent; text: "Exit full screen  ·  Esc"; color: "white"; font.pixelSize: 12 }
        MouseArea { id: exitMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.exitFullscreen() }
    }
    Timer { id: pillTimer; interval: 2500 }
    onFullscreenModeChanged: if (fullscreenMode) pillTimer.restart()

    ConfirmDialog {
        id: logoutConfirm
        title: "Sign out?"
        message: "You'll need your username and password to sign in again. Recording on the server continues."
        confirmText: "Sign out"
        onConfirmed: Api.logout()
    }
    PasswordDialog { id: passwordDialog }
    BookmarkDialog { id: bookmarkDialog; onAdded: timeline.fetch() }
    ExportDialog { id: exportDialog }
    NotificationsDialog { id: notificationsDialog }
    AuditDialog { id: auditDialog }
    ServerSettingsDialog { id: serverSettingsDialog }
    UsersDialog { id: usersDialog }

    CameraDialog { id: cameraDialog }

    AppDialog {
        id: renameDialog
        property string target: ""
        title: "Rename layout"
        standardButtons: Dialog.Save | Dialog.Cancel
        onOpened: { renameField.text = target; renameField.selectAll(); renameField.forceActiveFocus() }
        onAccepted: root.renameLayout(target, renameField.text)
        TextField { id: renameField; implicitWidth: 300; onAccepted: renameDialog.accept() }
    }
}
