import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Add / edit a camera. Brand templates build the RTSP URLs from IP + credentials.
Dialog {
    id: root
    modal: true
    width: 620
    padding: 20
    title: camId > 0 ? "Camera settings" : "Add camera"

    property int camId: 0
    property string errorText: ""
    property var discovered: []
    property bool discovering: false
    property string ptzResult: ""
    property bool ptzTesting: false
    readonly property string brandKey: brands[brand.currentIndex] ? brands[brand.currentIndex].key : ""

    readonly property var brands: [
        { key: "dahua",     name: "Dahua / Amcrest / Lorex", main: "/cam/realmonitor?channel={ch}&subtype=0", sub: "/cam/realmonitor?channel={ch}&subtype=1", port: 554 },
        { key: "openipc",   name: "OpenIPC firmware",        main: "/stream=0", sub: "/stream=1", port: 554, user: "root",
          hint: "OpenIPC uses the camera's web login for video. For PTZ, PTZ must be enabled in the camera's ONVIF settings." },
        { key: "thingino",  name: "Thingino firmware (Wyze etc.)", main: "/ch0", sub: "/ch1", port: 554, user: "thingino",
          hint: "Thingino's video stream has its own login, separate from the root web login (factory default thingino / thingino). Check it in the camera's web page under the streamer / RTSP settings." },
        { key: "hikvision", name: "Hikvision / Annke",       main: "/Streaming/Channels/{ch}01", sub: "/Streaming/Channels/{ch}02", port: 554 },
        { key: "reolink",   name: "Reolink",                 main: "/h264Preview_0{ch}_main", sub: "/h264Preview_0{ch}_sub", port: 554 },
        { key: "uniview",   name: "Uniview",                 main: "/unicast/c{ch}/s0/live", sub: "/unicast/c{ch}/s1/live", port: 554 },
        { key: "axis",      name: "Axis",                    main: "/axis-media/media.amp", sub: "/axis-media/media.amp?resolution=640x360", port: 554 },
        { key: "generic",   name: "Generic RTSP / ONVIF (enter URLs)", main: "", sub: "", port: 554 },
        { key: "demo",      name: "Demo test pattern",       main: "", sub: "", port: 0 }
    ]

    function brandIndex(key) {
        for (var i = 0; i < brands.length; i++) if (brands[i].key === key) return i
        return brands.length - 2
    }

    function buildUrls() {
        var b = brands[brand.currentIndex]
        if (b.key === "demo") { mainUrl.text = "demo://pattern"; subUrl.text = "demo://pattern"; return }
        if (b.main === "" || ip.text.trim() === "") return
        var cred = user.text.length > 0 ? encodeURIComponent(user.text) + (pass.text.length > 0 ? ":" + encodeURIComponent(pass.text) : "") + "@" : ""
        var host = ip.text.trim() + (port.value !== 554 ? ":" + port.value : "")
        var base = "rtsp://" + cred + host
        mainUrl.text = base + b.main.replace("{ch}", channel.value)
        subUrl.text = b.sub.length > 0 ? base + b.sub.replace("{ch}", channel.value) : ""
    }

    function load(cam) {
        errorText = ""
        discovered = []
        camId = cam ? cam.id : 0
        name.text = cam ? cam.name : ""
        brand.currentIndex = brandIndex(cam ? cam.brand : "dahua")
        ip.text = ""; user.text = cam ? "" : "admin"; pass.text = ""; channel.value = 1; port.value = 554
        mainUrl.text = cam ? cam.main_url : ""
        subUrl.text = cam ? cam.sub_url : ""
        record.checked = cam ? cam.record_mode === "continuous" : false
        ptz.checked = cam ? !!cam.ptz : false
        onvifPort.value = cam && cam.onvif_port ? cam.onvif_port : 80
        onvifUser.text = cam && cam.onvif_user ? cam.onvif_user : ""
        onvifPass.text = ""
        ptzResult = ""
        retention.value = cam ? cam.retention_days : 30
        tcp.currentIndex = cam && cam.transport === "udp" ? 1 : 0
        enabled_.checked = cam ? cam.enabled : true
        // Pre-fill the IP from an existing URL so templates can be reused.
        var m = mainUrl.text.match(/^rtsps?:\/\/(?:[^@\/]*@)?([^:\/?]+)(?::(\d+))?/)
        if (m) { ip.text = m[1]; if (m[2]) port.value = parseInt(m[2]) }
    }

    function save() {
        errorText = ""
        if (name.text.trim() === "") { errorText = "Give the camera a name"; return }
        if (mainUrl.text.trim() === "") { errorText = "Main stream URL is required"; return }
        var cam = {
            name: name.text.trim(),
            brand: brands[brand.currentIndex].key,
            main_url: mainUrl.text.trim(),
            sub_url: subUrl.text.trim(),
            transport: tcp.currentIndex === 1 ? "udp" : "tcp",
            record_mode: record.checked ? "continuous" : "off",
            record_sub: false,
            retention_days: retention.value,
            enabled: enabled_.checked,
            ptz: ptz.checked,
            onvif_port: onvifPort.value,
            onvif_user: onvifUser.text.trim()
        }
        if (onvifPass.text.length > 0) cam.onvif_pass = onvifPass.text
        if (camId > 0) cam.id = camId
        Api.saveCamera(cam, function (err) {
            if (err) root.errorText = err
            else root.close()
        })
    }

    contentItem: ColumnLayout {
        spacing: 10

        GridLayout {
            columns: 4
            columnSpacing: 10
            rowSpacing: 8
            Layout.fillWidth: true

            Label { text: "Name" }
            TextField { id: name; Layout.columnSpan: 3; Layout.fillWidth: true; placeholderText: "Front door" }

            Label { text: "Brand" }
            ComboBox {
                id: brand
                Layout.columnSpan: 3
                Layout.fillWidth: true
                model: root.brands.map(function (b) { return b.name })
                onActivated: {
                    var b = root.brands[currentIndex]
                    if (b.user && root.camId === 0) user.text = b.user
                    root.buildUrls()
                }
            }

            Item { visible: hintText.visible; width: 1; height: 1 }
            Text {
                id: hintText
                visible: !!root.brands[brand.currentIndex] && !!root.brands[brand.currentIndex].hint
                text: visible ? "ⓘ  " + root.brands[brand.currentIndex].hint : ""
                Layout.columnSpan: 3
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.warn
                font.pixelSize: 11
            }

            Label { text: "IP address" }
            RowLayout {
                Layout.columnSpan: 3
                Layout.fillWidth: true
                TextField { id: ip; Layout.fillWidth: true; placeholderText: "192.168.1.64"; onTextEdited: root.buildUrls() }
                Label { text: "Port" }
                SpinBox { id: port; from: 1; to: 65535; value: 554; editable: true; onValueModified: root.buildUrls() }
                Button {
                    text: root.discovering ? "Searching…" : "Find cameras"
                    enabled: !root.discovering
                    onClicked: {
                        root.discovering = true
                        Api.discover(function (err, list) {
                            root.discovering = false
                            if (err) { root.errorText = err; return }
                            root.discovered = list || []
                            if (root.discovered.length === 0) root.errorText = "No ONVIF cameras answered. Enter the IP manually."
                        })
                    }
                }
            }

            // Discovered devices
            Item { visible: root.discovered.length > 0; width: 1; height: 1 }
            Flow {
                visible: root.discovered.length > 0
                Layout.columnSpan: 3
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: root.discovered
                    Button {
                        text: modelData.address + (modelData.name ? " · " + modelData.name : "") + (modelData.hardware ? " (" + modelData.hardware + ")" : "")
                        flat: true
                        onClicked: {
                            ip.text = modelData.address
                            var hw = ((modelData.name || "") + " " + (modelData.hardware || "")).toLowerCase()
                            if (hw.indexOf("dahua") >= 0 || hw.indexOf("amcrest") >= 0) brand.currentIndex = root.brandIndex("dahua")
                            else if (hw.indexOf("hik") >= 0) brand.currentIndex = root.brandIndex("hikvision")
                            else if (hw.indexOf("openipc") >= 0) brand.currentIndex = root.brandIndex("openipc")
                            else if (hw.indexOf("thingino") >= 0) brand.currentIndex = root.brandIndex("thingino")
                            if (name.text === "") name.text = modelData.name || modelData.address
                            root.buildUrls()
                        }
                    }
                }
            }

            Label { text: "Username" }
            TextField { id: user; Layout.fillWidth: true; onTextEdited: root.buildUrls() }
            Label { text: "Password" }
            TextField { id: pass; Layout.fillWidth: true; echoMode: TextInput.Password; onTextEdited: root.buildUrls() }

            Label { text: "Channel" }
            SpinBox { id: channel; from: 1; to: 64; value: 1; onValueModified: root.buildUrls() }
            Label { text: "Transport" }
            ComboBox { id: tcp; Layout.fillWidth: true; model: ["TCP (reliable)", "UDP"] }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        GridLayout {
            columns: 2
            columnSpacing: 10
            rowSpacing: 8
            Layout.fillWidth: true
            Label { text: "Main stream" }
            TextField { id: mainUrl; Layout.fillWidth: true; placeholderText: "rtsp://user:pass@ip:554/…"; font.family: Theme.mono; font.pixelSize: 12 }
            Label { text: "Substream" }
            TextField { id: subUrl; Layout.fillWidth: true; placeholderText: "optional — low-res stream for grids"; font.family: Theme.mono; font.pixelSize: 12 }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        // ---- PTZ ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Switch { id: ptz; text: "PTZ camera (pan / tilt / zoom)" }
            Item { Layout.fillWidth: true }
            Label { visible: ptz.checked; text: "ONVIF port" }
            SpinBox { visible: ptz.checked; id: onvifPort; from: 1; to: 65535; value: 80; editable: true }
        }
        GridLayout {
            visible: ptz.checked
            columns: 4
            columnSpacing: 10
            rowSpacing: 8
            Layout.fillWidth: true
            Label { text: "ONVIF user" }
            TextField { id: onvifUser; Layout.fillWidth: true; placeholderText: "same as stream login" }
            Label { text: "ONVIF password" }
            TextField {
                id: onvifPass
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: root.camId > 0 && onvifUser.text !== "" ? "unchanged" : "same as stream login"
            }
            Button {
                Layout.columnSpan: 1
                text: root.ptzTesting ? "Testing…" : "Test PTZ"
                enabled: root.camId > 0 && !root.ptzTesting
                ToolTip.visible: hovered && root.camId === 0
                ToolTip.text: "Save the camera first, then test PTZ"
                onClicked: {
                    root.ptzTesting = true
                    root.ptzResult = ""
                    Api.call("GET", "/api/cameras/" + root.camId + "/ptz/check", null, function (err, data) {
                        root.ptzTesting = false
                        if (err) root.ptzResult = "✗ " + err
                        else if (data.ok) root.ptzResult = "✓ PTZ works (" + data.presets + " presets)"
                        else root.ptzResult = "✗ " + data.error
                    })
                }
            }
            Text {
                Layout.columnSpan: 3
                Layout.fillWidth: true
                text: root.ptzResult !== "" ? root.ptzResult : "Save changes before testing."
                color: root.ptzResult.indexOf("✓") === 0 ? Theme.online : root.ptzResult !== "" ? Theme.live : Theme.textFaint
                wrapMode: Text.Wrap
                font.pixelSize: 11
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Switch { id: record; text: "Record 24/7" }
            Label { text: "Keep footage" }
            SpinBox { id: retention; from: 0; to: 3650; value: 30; editable: true }
            Label { text: "days"; color: Theme.textDim }
            Item { Layout.fillWidth: true }
            Switch { id: enabled_; text: "Enabled" }
        }

        Text {
            Layout.fillWidth: true
            visible: root.errorText.length > 0
            text: root.errorText
            color: Theme.live
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 6
            Button {
                visible: root.camId > 0
                text: "Delete camera"
                onClicked: confirmDelete.open()
            }
            Item { Layout.fillWidth: true }
            Button { text: "Cancel"; onClicked: root.close() }
            Button { text: root.camId > 0 ? "Save" : "Add camera"; highlighted: true; onClicked: root.save() }
        }
    }

    Dialog {
        id: confirmDelete
        anchors.centerIn: parent
        modal: true
        title: "Delete camera?"
        standardButtons: Dialog.Yes | Dialog.No
        Label { text: "The camera is removed and stops recording.\nExisting footage is kept until retention removes it." }
        onAccepted: Api.deleteCamera(root.camId, function (err) { if (err) root.errorText = err; else root.close() })
    }
}
