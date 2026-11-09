import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Phone notifications: how to connect the ntfy app, and the rules that send alerts.
AppDialog {
    id: root
    title: "Phone notifications"
    subtitle: "Alerts go to the ntfy app on your phone over your network or VPN. No cloud service is involved."
    width: Math.min(820, parent ? parent.width - 40 : 820)
    height: Math.min(640, parent ? parent.height - 40 : 640)

    property int page: 0
    property string topic: ""
    property var rules: []
    property string status: ""
    property bool statusError: false
    property bool dirty: false

    readonly property var triggers: [
        { key: "motion", name: "Motion detected" },
        { key: "offline", name: "Camera goes offline" },
        { key: "online", name: "Camera comes back online" },
        { key: "disk_low", name: "Recording disk almost full" }
    ]
    readonly property var dayNames: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    readonly property string serverAddr: Api.serverUrl
    readonly property bool localOnly: /\/\/(localhost|127\.)/.test(Api.serverUrl)

    property int startPage: 0
    onOpened: { page = startPage; startPage = 0; load() }
    function load() {
        status = ""; dirty = false
        Api.call("GET", "/api/notify", null, function (err, d) {
            if (err) { setStatus(err, true); return }
            topic = d.topic
            topicField.text = d.topic
            rules = d.rules || []
        })
    }
    function setStatus(text, isError) { status = text; statusError = !!isError }
    function triggerIndex(k) { for (var i = 0; i < triggers.length; i++) if (triggers[i].key === k) return i; return 0 }
    function changeRule(i, patch) {
        var list = rules.slice()
        list[i] = Object.assign({}, list[i], patch)
        rules = list
        dirty = true
    }
    function addRule() {
        rules = rules.concat([{ id: "", name: "Motion alert", enabled: true, trigger: "motion", cameras: [], days: [],
                                from: "", to: "", cooldown: 120, priority: 3, notify: true, webhook: "", bookmark: false }])
        dirty = true
    }
    function removeRule(i) { var l = rules.slice(); l.splice(i, 1); rules = l; dirty = true }
    function save() {
        Api.call("PUT", "/api/notify", { topic: topicField.text.trim(), rules: rules }, function (err, d) {
            if (err) { setStatus(err, true); return }
            topic = d.topic; rules = d.rules || []; dirty = false
            setStatus("✓ Saved.")
        })
    }
    function camerasText(ids) {
        if (!ids || ids.length === 0) return "All cameras"
        return ids.map(function (id) { var c = Theme.findCamera(Api.cameras, id); return c ? c.name : "#" + id }).join(", ")
    }

    contentItem: ColumnLayout {
        spacing: 14
        TabStrip {
            Layout.fillWidth: true
            tabs: ["Phone setup", "Alert rules"]
            current: root.page
            onSelected: index => root.page = index
        }

        // ---------------- Phone setup ----------------
        Flickable {
            visible: root.page === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: setupCol.implicitHeight
            ScrollBar.vertical: ScrollBar {}
            ColumnLayout {
                id: setupCol
                width: parent.width
                spacing: 14

                Repeater {
                    model: [
                        { n: "1", t: "Install the ntfy app", d: "Android: ntfy from F-Droid or Google Play. It's free and open source." },
                        { n: "2", t: "Make the phone reach this server", d: "On your home Wi-Fi, or through your VPN (WireGuard, Tailscale…) when you're away." },
                        { n: "3", t: "Add your IPvexa login in ntfy", d: "ntfy → Settings → Manage users → Add user. Server: the address below. Username and password: an IPvexa account that can see all cameras." },
                        { n: "4", t: "Subscribe to the feed", d: "Tap +, enter the feed name below, tick \"Use another server\" and enter the server address. Then send a test." }
                    ]
                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 12
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            implicitWidth: 24; implicitHeight: 24; radius: 12
                            color: Theme.accentSoft
                            border.color: Theme.accent
                            Text { anchors.centerIn: parent; text: modelData.n; color: Theme.accent; font.pixelSize: 12; font.weight: Font.Bold }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text { text: modelData.t; color: Theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                            Text { Layout.fillWidth: true; text: modelData.d; color: Theme.textDim; font.pixelSize: 12; wrapMode: Text.Wrap }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

                GridLayout {
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 10
                    Layout.fillWidth: true
                    FieldLabel { text: "Server address" }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        TextField { Layout.fillWidth: true; readOnly: true; text: root.serverAddr; font.family: Theme.mono; selectByMouse: true }
                        Text {
                            visible: root.localOnly
                            Layout.fillWidth: true
                            text: "This app is connected through localhost. On the phone, use this computer's network or VPN address instead, with port 7480."
                            color: Theme.warn; font.pixelSize: 11; wrapMode: Text.Wrap
                        }
                    }
                    FieldLabel { text: "Feed name" }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField {
                            id: topicField
                            Layout.fillWidth: true
                            font.family: Theme.mono
                            onTextEdited: root.dirty = true
                        }
                        AppButton {
                            text: "Send test"
                            onClicked: Api.call("POST", "/api/notify/test", null, function (err) {
                                root.setStatus(err ? err : "✓ Test sent. It should appear on subscribed phones within seconds.", !!err)
                            })
                        }
                    }
                }
            }
        }

        // ---------------- Rules ----------------
        ColumnLayout {
            visible: root.page === 1
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: root.rules.length === 0 ? "No rules yet. Add one to start getting alerts." : root.rules.length + " rule" + (root.rules.length === 1 ? "" : "s")
                    color: Theme.textDim; font.pixelSize: 12
                }
                AppButton { text: "+  Add rule"; kind: "primary"; onClicked: root.addRule() }
            }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 8
                model: root.rules
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    width: ListView.view.width - 12
                    height: cardCol.implicitHeight + 20
                    radius: 8
                    color: "#151b1e"
                    border.color: modelData.enabled ? Theme.borderStrong : Theme.border
                    opacity: modelData.enabled ? 1 : 0.7
                    ColumnLayout {
                        id: cardCol
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Switch { checked: card.modelData.enabled; onToggled: root.changeRule(card.index, { enabled: checked }) }
                            TextField {
                                Layout.fillWidth: true
                                text: card.modelData.name
                                placeholderText: "Rule name"
                                onEditingFinished: if (text !== card.modelData.name) root.changeRule(card.index, { name: text })
                            }
                            ComboBox {
                                Layout.preferredWidth: 220
                                model: root.triggers.map(function (t) { return t.name })
                                currentIndex: root.triggerIndex(card.modelData.trigger)
                                onActivated: root.changeRule(card.index, { trigger: root.triggers[currentIndex].key })
                            }
                            IconButton { iconKind: "close"; iconSize: 10; tip: "Delete rule"; onClicked: root.removeRule(card.index) }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            visible: card.modelData.trigger !== "disk_low"
                            Text { text: "Cameras"; color: Theme.textDim; font.pixelSize: 12; Layout.preferredWidth: 70 }
                            AppButton {
                                kind: "ghost"
                                implicitHeight: 28
                                text: root.camerasText(card.modelData.cameras) + "  ▾"
                                onClicked: camMenu.popup()
                                Menu {
                                    id: camMenu
                                    MenuItem {
                                        text: "All cameras"; checkable: true
                                        checked: !card.modelData.cameras || card.modelData.cameras.length === 0
                                        onTriggered: root.changeRule(card.index, { cameras: [] })
                                    }
                                    MenuSeparator {}
                                    Repeater {
                                        model: Api.cameras
                                        MenuItem {
                                            required property var modelData
                                            text: modelData.name
                                            checkable: true
                                            checked: (card.modelData.cameras || []).indexOf(modelData.id) >= 0
                                            onTriggered: {
                                                var ids = (card.modelData.cameras || []).slice()
                                                var at = ids.indexOf(modelData.id)
                                                if (at >= 0) ids.splice(at, 1); else ids.push(modelData.id)
                                                root.changeRule(card.index, { cameras: ids })
                                            }
                                        }
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text { text: "When"; color: Theme.textDim; font.pixelSize: 12; Layout.preferredWidth: 70 }
                            Repeater {
                                model: 7
                                Rectangle {
                                    required property int index
                                    readonly property var days: card.modelData.days || []
                                    readonly property bool on: days.length === 0 || days.indexOf(index) >= 0
                                    width: 38; height: 24; radius: 4
                                    color: on ? Theme.accentSoft : "transparent"
                                    border.color: on ? "#2a6f93" : Theme.border
                                    Text { anchors.centerIn: parent; text: root.dayNames[index]; color: parent.on ? Theme.accent : Theme.textFaint; font.pixelSize: 11 }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            var d = parent.days.length === 0 ? [0, 1, 2, 3, 4, 5, 6] : parent.days.slice()
                                            var at = d.indexOf(index)
                                            if (at >= 0) d.splice(at, 1); else d.push(index)
                                            d.sort()
                                            if (d.length === 7 || d.length === 0) d = []
                                            root.changeRule(card.index, { days: d })
                                        }
                                    }
                                }
                            }
                            Text { text: "from"; color: Theme.textDim; font.pixelSize: 12; Layout.leftMargin: 8 }
                            TextField {
                                Layout.preferredWidth: 70
                                text: card.modelData.from || ""
                                placeholderText: "00:00"
                                onEditingFinished: if (text !== (card.modelData.from || "")) root.changeRule(card.index, { from: text.trim() })
                            }
                            Text { text: "to"; color: Theme.textDim; font.pixelSize: 12 }
                            TextField {
                                Layout.preferredWidth: 70
                                text: card.modelData.to || ""
                                placeholderText: "24:00"
                                onEditingFinished: if (text !== (card.modelData.to || "")) root.changeRule(card.index, { to: text.trim() })
                            }
                            Item { Layout.fillWidth: true }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text { text: "Then"; color: Theme.textDim; font.pixelSize: 12; Layout.preferredWidth: 70 }
                            CheckBox { text: "Notify phones"; checked: !!card.modelData.notify; onToggled: root.changeRule(card.index, { notify: checked }) }
                            ComboBox {
                                enabled: !!card.modelData.notify
                                Layout.preferredWidth: 130
                                model: ["Min", "Low", "Normal", "High", "Urgent"]
                                currentIndex: Math.max(0, (card.modelData.priority || 3) - 1)
                                onActivated: root.changeRule(card.index, { priority: currentIndex + 1 })
                            }
                            CheckBox { text: "Bookmark it"; checked: !!card.modelData.bookmark; onToggled: root.changeRule(card.index, { bookmark: checked }) }
                            Text { text: "at most every"; color: Theme.textDim; font.pixelSize: 12; Layout.leftMargin: 6 }
                            SpinBox {
                                from: 10; to: 86400; stepSize: 30; editable: true
                                Layout.preferredWidth: 110
                                value: card.modelData.cooldown || 60
                                onValueModified: root.changeRule(card.index, { cooldown: value })
                            }
                            Text { text: "s"; color: Theme.textDim; font.pixelSize: 12 }
                            Item { Layout.fillWidth: true }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text { text: "Webhook"; color: Theme.textDim; font.pixelSize: 12; Layout.preferredWidth: 70 }
                            TextField {
                                Layout.fillWidth: true
                                text: card.modelData.webhook || ""
                                placeholderText: "optional: http://homeassistant.local:8123/api/webhook/…"
                                font.pixelSize: 12
                                onEditingFinished: if (text !== (card.modelData.webhook || "")) root.changeRule(card.index, { webhook: text.trim() })
                            }
                        }
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.status !== ""
            text: root.status
            color: root.statusError ? Theme.live : Theme.online
            wrapMode: Text.Wrap
            font.pixelSize: 12
        }
    }

    footer: Item {
        implicitHeight: 64
        Rectangle { width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 8
            Text { visible: root.dirty; text: "Unsaved changes"; color: Theme.warn; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            AppButton { text: "Close"; onClicked: root.close() }
            AppButton { text: "Save"; kind: "primary"; enabled: root.dirty; onClicked: root.save() }
        }
    }
}
