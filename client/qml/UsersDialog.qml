import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// User management (admins): list on the left, editor on the right.
AppDialog {
    id: root
    title: "User management"
    subtitle: "Local accounts on this server and what each one may see and do"
    width: Math.min(880, parent ? parent.width - 40 : 880)
    height: Math.min(600, parent ? parent.height - 40 : 600)
    padding: 0
    topPadding: 0
    bottomPadding: 0

    property var users: []
    property int selId: 0           // 0 = nothing, -1 = new user
    property var sel: null
    property string errorText: ""
    property string okText: ""
    property bool busy: false
    property var camSel: ({})       // camera id -> true for "selected cameras"

    readonly property var roles: [
        { key: "admin",    name: "Administrator", desc: "Everything, including cameras, users and settings." },
        { key: "operator", name: "Operator",      desc: "Live video, recordings and PTZ, as allowed below." },
        { key: "viewer",   name: "Viewer",        desc: "Watches video only, as allowed below." }
    ]
    function roleIndex(k) { for (var i = 0; i < roles.length; i++) if (roles[i].key === k) return i; return 2 }
    function roleName(k) { return roles[roleIndex(k)].name }

    onOpened: { selId = 0; sel = null; reload() }

    function reload(selectName) {
        Api.call("GET", "/api/users", null, function (err, list) {
            if (err) { errorText = err; return }
            users = list || []
            var pick = null
            for (var i = 0; i < users.length; i++)
                if ((selectName && users[i].username === selectName) || (!selectName && users[i].id === selId)) pick = users[i]
            if (!pick && users.length > 0 && selId === 0) pick = users[0]
            if (pick) edit(pick)
        })
    }

    function edit(u) {
        errorText = ""; okText = ""
        sel = u
        selId = u ? u.id : -1
        uname.text = u ? u.username : ""
        fname.text = u ? (u.full_name || "") : ""
        role.currentIndex = roleIndex(u ? u.role : "viewer")
        pw.text = ""
        enabledSw.checked = u ? !u.disabled : true
        var p = u ? u.permissions : { all_cameras: true, cameras: [], playback: true, ptz: false, export: false }
        allCams.checked = !!p.all_cameras
        playback.checked = !!p.playback
        ptz.checked = !!p.ptz
        exportPerm.checked = !!p.export
        var m = {}
        ;(p.cameras || []).forEach(function (id) { m[id] = true })
        camSel = m
        if (!u) uname.forceActiveFocus()
    }

    function save() {
        errorText = ""; okText = ""
        var body = {
            username: uname.text.trim(),
            full_name: fname.text.trim(),
            role: roles[role.currentIndex].key,
            disabled: !enabledSw.checked,
            password: pw.text,
            permissions: {
                all_cameras: allCams.checked,
                cameras: Object.keys(camSel).filter(function (k) { return camSel[k] }).map(function (k) { return parseInt(k) }),
                playback: playback.checked,
                ptz: ptz.checked,
                export: exportPerm.checked && playback.checked
            }
        }
        if (body.username === "") { errorText = "Enter a username."; return }
        if (selId < 0 && pw.text.length < 8) { errorText = "Give the new user a password of at least 8 characters."; return }
        if (pw.text.length > 0 && pw.text.length < 8) { errorText = "Passwords must be at least 8 characters."; return }
        busy = true
        var isNew = selId < 0
        Api.call(isNew ? "POST" : "PUT", isNew ? "/api/users" : "/api/users/" + selId, body, function (err, u) {
            busy = false
            if (err) { errorText = err; return }
            okText = isNew ? "User created." : "Changes saved."
            selId = u.id
            reload(u.username)
            if (u.username === Api.username) Api.refreshMe()
        })
    }

    contentItem: RowLayout {
        spacing: 0

        // ---------- User list ----------
        Rectangle {
            Layout.preferredWidth: 270
            Layout.fillHeight: true
            color: "#151b1e"
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8
                AppButton {
                    Layout.fillWidth: true
                    text: "+  Add user"
                    kind: "primary"
                    onClicked: root.edit(null)
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    model: root.users
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: 48
                        radius: 6
                        readonly property bool isSel: modelData.id === root.selId
                        color: isSel ? Theme.accentSoft : rowMa.containsMouse ? Theme.panelAlt : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10
                            Rectangle {
                                implicitWidth: 30; implicitHeight: 30; radius: 15
                                color: modelData.disabled ? "#2a3035" : modelData.role === "admin" ? "#1f5f86" : "#2b4a3c"
                                Text {
                                    anchors.centerIn: parent
                                    text: (modelData.full_name || modelData.username).charAt(0).toUpperCase()
                                    color: "white"; font.pixelSize: 13; font.weight: Font.DemiBold
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.full_name ? modelData.full_name : modelData.username
                                    color: modelData.disabled ? Theme.textFaint : Theme.text
                                    font.pixelSize: 13; font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: (modelData.full_name ? modelData.username + " · " : "") + root.roleName(modelData.role)
                                          + (modelData.disabled ? " · disabled" : "")
                                          + (modelData.username === Api.username ? " · you" : "")
                                    color: Theme.textDim; font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.edit(modelData) }
                    }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Theme.border }

        // ---------- Editor ----------
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Text {
                visible: root.selId === 0
                anchors.centerIn: parent
                text: "Select a user, or add a new one"
                color: Theme.textFaint
                font.pixelSize: 13
            }

            ColumnLayout {
                visible: root.selId !== 0
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                Text {
                    text: root.selId < 0 ? "New user" : (root.sel ? root.sel.username : "")
                    color: Theme.text
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }

                GridLayout {
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 10
                    Layout.fillWidth: true
                    FieldLabel { text: "Username" }
                    TextField { id: uname; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "e.g. frontdesk" }
                    FieldLabel { text: "Full name" }
                    TextField { id: fname; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "optional" }
                    FieldLabel { text: root.selId < 0 ? "Password" : "New password" }
                    TextField {
                        id: pw
                        Layout.fillWidth: true
                        Layout.preferredWidth: 100
                        echoMode: TextInput.Password
                        placeholderText: root.selId < 0 ? "at least 8 characters" : "leave empty to keep the current password"
                    }
                    FieldLabel { text: "Role" }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        ComboBox {
                            id: role
                            Layout.preferredWidth: 170
                            model: root.roles.map(function (r) { return r.name })
                            onActivated: {
                                var d = root.roles[currentIndex].key
                                if (d === "viewer") { ptz.checked = false }
                                if (d === "operator") { playback.checked = true; ptz.checked = true; exportPerm.checked = true }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.roles[role.currentIndex] ? root.roles[role.currentIndex].desc : ""
                            color: Theme.textDim; font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                    }
                    FieldLabel { text: "Account" }
                    Switch { id: enabledSw; text: checked ? "Enabled" : "Disabled — can't sign in" }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }

                // ---- Permissions ----
                readonly property bool isAdminRole: root.roles[role.currentIndex] && root.roles[role.currentIndex].key === "admin"
                Text { text: "Permissions"; color: Theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                Text {
                    visible: parent.isAdminRole
                    text: "Administrators can see every camera and use every feature."
                    color: Theme.textDim; font.pixelSize: 12
                }
                RowLayout {
                    visible: !parent.isAdminRole
                    spacing: 24
                    CheckBox { id: playback; text: "View recordings (playback)" }
                    CheckBox { id: ptz; text: "Control PTZ cameras" }
                    CheckBox { id: exportPerm; text: "Export video clips"; enabled: playback.checked }
                }
                RowLayout {
                    visible: !parent.isAdminRole
                    spacing: 10
                    Text { text: "Cameras"; color: Theme.textDim; font.pixelSize: 12 }
                    Segmented {
                        value: allCams.checked ? "all" : "some"
                        options: [{ value: "all", label: "All cameras" }, { value: "some", label: "Only selected" }]
                        onPicked: (v) => allCams.checked = (v === "all")
                    }
                    CheckBox { id: allCams; visible: false }
                    Text {
                        visible: !allCams.checked
                        text: Object.keys(root.camSel).filter(function (k) { return root.camSel[k] }).length + " selected"
                        color: Theme.textFaint; font.pixelSize: 11
                    }
                }
                Rectangle {
                    visible: !parent.isAdminRole && !allCams.checked
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 60
                    color: "#0e1215"
                    radius: 6
                    border.color: Theme.border
                    ListView {
                        anchors.fill: parent
                        anchors.margins: 4
                        clip: true
                        model: Api.cameras
                        delegate: CheckBox {
                            required property var modelData
                            width: ListView.view.width
                            text: modelData.name
                            checked: !!root.camSel[modelData.id]
                            onToggled: {
                                var m = Object.assign({}, root.camSel)
                                m[modelData.id] = checked
                                root.camSel = m
                            }
                        }
                    }
                }
                Item { Layout.fillHeight: true; visible: parent.isAdminRole || allCams.checked }

                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: root.errorText !== "" ? root.errorText : root.okText !== "" ? "✓  " + root.okText : ""
                    color: root.errorText !== "" ? Theme.live : Theme.online
                    wrapMode: Text.Wrap
                    font.pixelSize: 12
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    AppButton {
                        visible: root.selId > 0
                        text: "Delete user"
                        kind: "danger"
                        enabled: root.sel && root.sel.username !== Api.username
                        tip: root.sel && root.sel.username === Api.username ? "You can't delete your own account" : ""
                        onClicked: confirmDelete.open()
                    }
                    Item { Layout.fillWidth: true }
                    AppButton {
                        text: "Revert"
                        visible: root.selId > 0
                        onClicked: root.edit(root.sel)
                    }
                    AppButton {
                        text: root.busy ? "Saving…" : root.selId < 0 ? "Create user" : "Save changes"
                        kind: "primary"
                        enabled: !root.busy
                        onClicked: root.save()
                    }
                }
            }
        }
    }

    footer: Item {
        implicitHeight: 0
    }

    ConfirmDialog {
        id: confirmDelete
        title: "Delete user?"
        message: root.sel ? "The account \"" + root.sel.username + "\" is removed and signed out everywhere. This can't be undone." : ""
        confirmText: "Delete user"
        danger: true
        onConfirmed: Api.call("DELETE", "/api/users/" + root.selId, null, function (err) {
            if (err) { root.errorText = err; return }
            root.selId = 0; root.sel = null
            root.reload()
        })
    }
}
