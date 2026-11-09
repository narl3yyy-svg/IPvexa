import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Ipvexa

// Add / edit a camera. Brand templates build the RTSP URLs from IP + credentials.
AppDialog {
    id: root
    modal: true
    padding: 20
    title: camId > 0 ? "Camera settings" : "Add camera"
    subtitle: camId > 0 ? name.text : "Connect an IP camera by its address, or search the network"

    property int camId: 0
    property string errorText: ""
    property var discovered: []
    property bool discovering: false
    property string ptzResult: ""
    property bool ptzTesting: false
    property bool probing: false
    property var probe: null          // last ONVIF stream detection result
    property int motionPad: 10        // seconds kept around motion (server setting)
    property var schedule: []         // recording schedule rules (see server store.ScheduleRule)
    function changeRule(i, patch) {
        var l = schedule.slice()
        l[i] = Object.assign({}, l[i], patch)
        schedule = l
    }
    function removeRule(i) { var l = schedule.slice(); l.splice(i, 1); schedule = l }
    property string probeError: ""
    readonly property string brandKey: brands[brand.currentIndex] ? brands[brand.currentIndex].key : ""

    readonly property var brands: [
        { key: "dahua",     name: "Dahua / Amcrest / Lorex", main: "/cam/realmonitor?channel={ch}&subtype=0", sub: "/cam/realmonitor?channel={ch}&subtype=1", port: 554 },
        { key: "openipc",   name: "OpenIPC firmware",        main: "/stream=0", sub: "/stream=1", port: 554, user: "root",
          hint: "OpenIPC uses the camera's web login for video and PTZ (ptzd). Use Test PTZ after saving to check." },
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

    // Stream URLs are shown WITHOUT the login; the username/password fields hold it and
    // are added back when saving. Keeps passwords off screen (and out of screenshots).
    function splitCreds(url) {
        var m = (url || "").match(/^([a-z0-9+.-]+:\/\/)(?:([^:@\/]*)(?::([^@\/]*))?@)?(.*)$/i)
        if (!m) return { url: url || "", user: "", pass: "" }
        var dec = function (v) { try { return decodeURIComponent(v || "") } catch (e) { return v || "" } }
        return { url: m[1] + m[4], user: dec(m[2]), pass: dec(m[3]) }
    }
    function withCreds(url) {
        url = url.trim()
        if (url === "" || url.indexOf("demo://") === 0 || user.text.length === 0) return url
        var m = url.match(/^([a-z0-9+.-]+:\/\/)(.*)$/i)
        if (!m || m[2].split("/")[0].indexOf("@") >= 0) return url // already has a login
        return m[1] + encodeURIComponent(user.text) + (pass.text.length > 0 ? ":" + encodeURIComponent(pass.text) : "") + "@" + m[2]
    }

    function buildUrls() {
        var b = brands[brand.currentIndex]
        if (b.key === "demo") { mainUrl.text = "demo://pattern"; subUrl.text = "demo://pattern"; return }
        if (b.main === "" || ip.text.trim() === "") return
        var host = ip.text.trim() + (port.value !== 554 ? ":" + port.value : "")
        var base = "rtsp://" + host
        mainUrl.text = base + b.main.replace("{ch}", channel.value)
        subUrl.text = b.sub.length > 0 ? base + b.sub.replace("{ch}", channel.value) : ""
    }

    // Ask the camera (over ONVIF, through the server) for its stream addresses.
    function detectStreams() {
        errorText = ""; probeError = ""; probe = null
        if (ip.text.trim() === "") { probeError = "Enter the camera's address first."; return }
        probing = true
        Api.call("POST", "/api/onvif/probe", {
            address: ip.text.trim(),
            port: onvifPort.value,
            username: onvifUser.text.trim() !== "" ? onvifUser.text.trim() : user.text,
            password: onvifPass.text !== "" ? onvifPass.text : pass.text
        }, function (err, info) {
            probing = false
            if (err) { probeError = err; return }
            probe = info
            mainUrl.text = info.main
            subUrl.text = info.sub || ""
            var maker = ((info.device && info.device.manufacturer) || "").toLowerCase()
            if (brandKey === "generic" || brandKey === "") {
                if (maker.indexOf("dahua") >= 0 || maker.indexOf("amcrest") >= 0) brand.currentIndex = brandIndex("dahua")
                else if (maker.indexOf("hik") >= 0) brand.currentIndex = brandIndex("hikvision")
            }
            if (name.text.trim() === "" && info.device && info.device.model) name.text = info.device.model
        })
    }
    function profileText(p) {
        var s = (p.name || p.token) + "  ·  " + (p.encoding || "?")
        if (p.width) s += " " + p.width + "×" + p.height
        if (p.fps) s += " @ " + p.fps + " fps"
        return s
    }

    function load(cam) {
        page = 0
        errorText = ""
        probe = null; probeError = ""
        discovered = []
        camId = cam ? cam.id : 0
        name.text = cam ? cam.name : ""
        brand.currentIndex = brandIndex(cam ? cam.brand : "dahua")
        ip.text = ""; user.text = cam ? "" : "admin"; pass.text = ""; channel.value = 1; port.value = 554
        var mainParts = splitCreds(cam ? cam.main_url : "")
        var subParts = splitCreds(cam ? cam.sub_url : "")
        mainUrl.text = mainParts.url
        subUrl.text = subParts.url
        if (cam && mainParts.user !== "") { user.text = mainParts.user; pass.text = mainParts.pass }
        recMode.currentIndex = cam && cam.record_mode === "continuous" ? 1 : cam && cam.record_mode === "motion" ? 2 : 0
        motionOn.checked = cam ? !!cam.motion : false
        sensitivity.value = cam && cam.motion_sensitivity ? cam.motion_sensitivity : 50
        zones.mask = cam && cam.motion_mask ? cam.motion_mask : ""
        schedule = cam && cam.record_schedule ? cam.record_schedule : []
        ptz.checked = cam ? !!cam.ptz : false
        onvifPort.value = cam && cam.onvif_port ? cam.onvif_port : 80
        onvifUser.text = cam && cam.onvif_user ? cam.onvif_user : ""
        onvifPass.text = ""
        ptzProto.currentIndex = cam && cam.ptz_protocol === "onvif" ? 1 : cam && cam.ptz_protocol === "ptzd" ? 2 : 0
        ptzResult = ""
        retention.value = cam ? cam.retention_days : 30
        recSub.checked = cam ? !!cam.record_sub : true
        // Server-wide defaults: retention for new cameras, motion recording buffer.
        Api.call("GET", "/api/settings", null, function (err, d) {
            if (err || !d) return
            root.motionPad = d.motion_pad_sec || 10
            if (!cam) retention.value = d.retention_days || 30
        })
        tcp.currentIndex = cam && cam.transport === "udp" ? 1 : 0
        enabled_.checked = cam ? cam.enabled : true
        // Pre-fill the IP from an existing URL so templates can be reused.
        var m = mainUrl.text.match(/^rtsps?:\/\/([^:\/?]+)(?::(\d+))?/)
        if (m) { ip.text = m[1]; if (m[2]) port.value = parseInt(m[2]) }
    }

    function save() {
        errorText = ""
        if (name.text.trim() === "") { errorText = "Give the camera a name."; page = 0; return }
        if (mainUrl.text.trim() === "") { errorText = "Enter the camera's address, or its high-quality stream URL."; page = ip.text.trim() === "" ? 0 : 1; return }
        var cam = {
            name: name.text.trim(),
            brand: brands[brand.currentIndex].key,
            main_url: withCreds(mainUrl.text),
            sub_url: withCreds(subUrl.text),
            transport: tcp.currentIndex === 1 ? "udp" : "tcp",
            record_mode: ["off", "continuous", "motion"][recMode.currentIndex],
            motion: motionOn.checked || recMode.currentIndex === 2 || schedule.some(function (r) { return r.mode === "motion" }),
            motion_sensitivity: Math.round(sensitivity.value),
            motion_mask: zones.mask,
            record_schedule: schedule,
            record_sub: recSub.checked && subUrl.text.trim() !== "",
            retention_days: retention.value,
            enabled: enabled_.checked,
            ptz: ptz.checked,
            onvif_port: onvifPort.value,
            onvif_user: onvifUser.text.trim(),
            ptz_protocol: ["auto", "onvif", "ptzd"][ptzProto.currentIndex]
        }
        if (onvifPass.text.length > 0) cam.onvif_pass = onvifPass.text
        if (camId > 0) cam.id = camId
        Api.saveCamera(cam, function (err) {
            if (err) root.errorText = err
            else root.close()
        })
    }

    property int page: 0
    width: 700

    contentItem: ColumnLayout {
        spacing: 16

        TabStrip {
            Layout.fillWidth: true
            tabs: ["General", "Streams", "PTZ", "Motion", "Recording"]
            current: root.page
            onCurrentChanged: root.page = current
        }

        StackLayout {
            Layout.fillWidth: true
            currentIndex: root.page

            // ---------------- General ----------------
            GridLayout {
                columns: 2
                columnSpacing: 12
                rowSpacing: 10
                Layout.alignment: Qt.AlignTop

                FieldLabel { text: "Name" }
                TextField { id: name; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "Front door" }

                FieldLabel { text: "Brand" }
                ComboBox {
                    id: brand
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    model: root.brands.map(function (b) { return b.name })
                    onActivated: {
                        var b = root.brands[currentIndex]
                        if (b.user && root.camId === 0) user.text = b.user
                        root.buildUrls()
                    }
                }

                Item { visible: hintBox.visible; implicitWidth: 1; implicitHeight: 1 }
                Rectangle {
                    id: hintBox
                    visible: !!root.brands[brand.currentIndex] && !!root.brands[brand.currentIndex].hint
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    implicitHeight: hintText.implicitHeight + 14
                    radius: 6
                    color: "#2a2414"
                    border.color: "#4d3f1c"
                    Text {
                        id: hintText
                        anchors.fill: parent
                        anchors.margins: 7
                        anchors.leftMargin: 10
                        text: hintBox.visible ? root.brands[brand.currentIndex].hint : ""
                        wrapMode: Text.Wrap
                        color: "#e8c77a"
                        font.pixelSize: 11
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                FieldLabel { text: "Address" }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    TextField { id: ip; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "192.168.1.64"; onTextEdited: root.buildUrls() }
                    Text { text: "Port"; color: Theme.textDim; font.pixelSize: 12 }
                    SpinBox { id: port; from: 1; to: 65535; value: 554; editable: true; Layout.preferredWidth: 110; onValueModified: root.buildUrls() }
                    AppButton {
                        text: root.discovering ? "Searching…" : "Find cameras"
                        enabled: !root.discovering
                        tip: "Search the local network for ONVIF cameras"
                        onClicked: {
                            root.discovering = true
                            Api.discover(function (err, list) {
                                root.discovering = false
                                if (err) { root.errorText = err; return }
                                root.discovered = list || []
                                if (root.discovered.length === 0) root.errorText = "No ONVIF cameras answered. Enter the address manually."
                            })
                        }
                    }
                }

                // Discovered devices
                Item { visible: root.discovered.length > 0; implicitWidth: 1; implicitHeight: 1 }
                Flow {
                    visible: root.discovered.length > 0
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    spacing: 6
                    Repeater {
                        model: root.discovered
                        AppButton {
                            kind: "ghost"
                            implicitHeight: 28
                            text: modelData.address + (modelData.name ? " · " + modelData.name : "") + (modelData.hardware ? " (" + modelData.hardware + ")" : "")
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

                FieldLabel { text: "Login" }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    TextField { id: user; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "username"; onTextEdited: root.buildUrls() }
                    TextField { id: pass; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "password"; echoMode: TextInput.Password; onTextEdited: root.buildUrls() }
                    AppButton {
                        text: root.probing ? "Detecting…" : "Detect streams"
                        enabled: !root.probing
                        tip: "Ask the camera for its stream addresses (ONVIF)"
                        onClicked: root.detectStreams()
                    }
                }

                Item { visible: probeLine.visible; implicitWidth: 1; implicitHeight: 1 }
                Text {
                    id: probeLine
                    visible: text !== ""
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    wrapMode: Text.Wrap
                    font.pixelSize: 12
                    color: root.probeError !== "" ? Theme.live : Theme.online
                    text: root.probeError !== "" ? "✗ " + root.probeError
                        : root.probe ? "✓ Found " + [root.probe.device.manufacturer, root.probe.device.model].filter(function (x) { return !!x }).join(" ")
                                       + " with " + root.probe.profiles.length + " stream profile" + (root.probe.profiles.length === 1 ? "" : "s")
                                       + ". Stream addresses filled in (see Streams)."
                        : ""
                }

                FieldLabel { text: "Channel" }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    SpinBox { id: channel; from: 1; to: 64; value: 1; Layout.preferredWidth: 110; onValueModified: root.buildUrls() }
                    Text { text: "Transport"; color: Theme.textDim; font.pixelSize: 12; Layout.leftMargin: 10 }
                    ComboBox { id: tcp; Layout.preferredWidth: 160; model: ["TCP (reliable)", "UDP"] }
                    Item { Layout.fillWidth: true }
                }

                FieldLabel { text: "Status" }
                Switch { id: enabled_; text: checked ? "Enabled" : "Disabled — not streamed or recorded" }
            }

            // ---------------- Streams ----------------
            GridLayout {
                columns: 2
                columnSpacing: 12
                rowSpacing: 10
                Layout.alignment: Qt.AlignTop
                Text {
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    text: "Filled in from the brand and address on the General tab. The login from the General tab is added when saving, so it isn't shown here."
                    color: Theme.textDim
                    wrapMode: Text.Wrap
                    font.pixelSize: 12
                }
                FieldLabel { text: "High quality" }
                TextField { id: mainUrl; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "rtsp://camera-address:554/…"; font.family: Theme.mono; font.pixelSize: 12 }
                FieldLabel { text: "Low quality" }
                TextField { id: subUrl; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "optional substream, used for small tiles"; font.family: Theme.mono; font.pixelSize: 12 }

                Item { implicitWidth: 1; implicitHeight: 1 }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    AppButton {
                        text: root.probing ? "Detecting…" : "Detect from camera"
                        enabled: !root.probing
                        tip: "Ask the camera for its stream addresses over ONVIF, using the login and control port from the other tabs"
                        onClicked: root.detectStreams()
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 100
                        visible: root.probeError !== ""
                        text: "✗ " + root.probeError
                        color: Theme.live
                        wrapMode: Text.Wrap
                        font.pixelSize: 12
                    }
                }

                // Profiles the camera reported
                Item { visible: !!root.probe; implicitWidth: 1; implicitHeight: 1 }
                Column {
                    visible: !!root.probe
                    Layout.fillWidth: true
                    spacing: 3
                    Repeater {
                        model: root.probe ? root.probe.profiles : []
                        Text {
                            required property var modelData
                            readonly property bool used: !!modelData.uri && (modelData.uri === mainUrl.text || modelData.uri === subUrl.text)
                            text: (used ? (modelData.uri === mainUrl.text ? "High  ▸  " : "Low   ▸  ") : "         ") + root.profileText(modelData)
                                  + (modelData.uri ? "" : "  (no RTSP address)")
                            color: used ? Theme.text : Theme.textFaint
                            font.family: Theme.mono
                            font.pixelSize: 11
                        }
                    }
                }
            }

            // ---------------- PTZ ----------------
            GridLayout {
                columns: 2
                columnSpacing: 12
                rowSpacing: 10
                Layout.alignment: Qt.AlignTop

                FieldLabel { text: "PTZ" }
                Switch { id: ptz; text: "This camera can pan / tilt / zoom" }

                FieldLabel { text: "Protocol"; opacity: ptz.checked ? 1 : 0.4 }
                RowLayout {
                    enabled: ptz.checked
                    Layout.fillWidth: true
                    spacing: 8
                    ComboBox {
                        id: ptzProto
                        Layout.preferredWidth: 180
                        model: ["Auto-detect", "ONVIF", "OpenIPC ptzd"]
                        ToolTip.visible: hovered
                        ToolTip.text: "Auto-detect uses OpenIPC's ptzd when the camera has it, otherwise ONVIF."
                        ToolTip.delay: 600
                    }
                    Text { text: "Control port"; color: Theme.textDim; font.pixelSize: 12; Layout.leftMargin: 10 }
                    SpinBox { id: onvifPort; from: 1; to: 65535; value: 80; editable: true; Layout.preferredWidth: 110 }
                    Item { Layout.fillWidth: true }
                }

                FieldLabel { text: "Control login"; opacity: ptz.checked ? 1 : 0.4 }
                RowLayout {
                    enabled: ptz.checked
                    Layout.fillWidth: true
                    spacing: 8
                    TextField { id: onvifUser; Layout.fillWidth: true; Layout.preferredWidth: 100; placeholderText: "same as stream login" }
                    TextField {
                        id: onvifPass
                        Layout.fillWidth: true
                        Layout.preferredWidth: 100
                        echoMode: TextInput.Password
                        placeholderText: root.camId > 0 && onvifUser.text !== "" ? "unchanged" : "same as stream login"
                    }
                }

                Item { implicitWidth: 1; implicitHeight: 1 }
                RowLayout {
                    enabled: ptz.checked
                    Layout.fillWidth: true
                    spacing: 12
                    AppButton {
                        text: root.ptzTesting ? "Testing…" : "Test PTZ"
                        enabled: root.camId > 0 && !root.ptzTesting
                        tip: root.camId === 0 ? "Add the camera first, then test PTZ" : "Check that the camera answers PTZ commands"
                        onClicked: {
                            root.ptzTesting = true
                            root.ptzResult = ""
                            Api.call("GET", "/api/cameras/" + root.camId + "/ptz/check", null, function (err, data) {
                                root.ptzTesting = false
                                if (err) root.ptzResult = "✗ " + err
                                else if (data.ok) root.ptzResult = "✓ PTZ works via " + (data.protocol === "ptzd" ? "OpenIPC ptzd" : "ONVIF")
                                                                   + (data.zoom ? "" : " · pan/tilt only")
                                                                   + (data.presets_supported ? " · " + data.presets + " presets" : " · no presets")
                                else root.ptzResult = "✗ " + data.error
                            })
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 100
                        text: root.ptzResult !== "" ? root.ptzResult : "Save changes before testing."
                        color: root.ptzResult.indexOf("✓") === 0 ? Theme.online : root.ptzResult !== "" ? Theme.live : Theme.textFaint
                        wrapMode: Text.Wrap
                        font.pixelSize: 12
                    }
                }
            }

            // ---------------- Motion ----------------
            ColumnLayout {
                spacing: 10
                Layout.alignment: Qt.AlignTop
                RowLayout {
                    spacing: 12
                    Switch {
                        id: motionOn
                        text: checked || recMode.currentIndex === 2 ? "Detect motion" : "Motion detection off"
                        checked: false
                        enabled: recMode.currentIndex !== 2
                    }
                    Item { Layout.fillWidth: true }
                    Text { text: "Sensitivity"; color: Theme.textDim; font.pixelSize: 12 }
                    Slider { id: sensitivity; from: 1; to: 100; stepSize: 1; value: 50; Layout.preferredWidth: 160 }
                    Text { text: Math.round(sensitivity.value); color: Theme.text; font.pixelSize: 12; Layout.preferredWidth: 24 }
                }
                Text {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    text: "Things that keep moving in place, like trees and flags in the wind, are learned and ignored automatically, and motion only counts when something moves across the picture. Paint areas to ignore completely (red), such as a busy road or the camera's clock."
                    color: Theme.textDim
                    wrapMode: Text.Wrap
                    font.pixelSize: 12
                }
                MotionZoneEditor {
                    id: zones
                    Layout.fillWidth: true
                    Layout.preferredHeight: width * 9 / 16
                    cameraId: root.camId
                    opacity: motionOn.checked || recMode.currentIndex === 2 ? 1 : 0.5
                }
                RowLayout {
                    spacing: 8
                    AppButton { text: "Clear zones"; onClicked: zones.clearAll() }
                    AppButton { text: "Refresh picture"; enabled: root.camId > 0; onClicked: zones.reload() }
                }
            }

            // ---------------- Recording ----------------
            GridLayout {
                columns: 2
                columnSpacing: 12
                rowSpacing: 10
                Layout.alignment: Qt.AlignTop
                FieldLabel { text: "Record" }
                ComboBox {
                    id: recMode
                    Layout.preferredWidth: 260
                    model: ["Off (live view only)", "Always (24/7)", "Only when there's motion"]
                }
                Item { implicitWidth: 1; implicitHeight: 1; visible: recMode.currentIndex === 2 }
                Text {
                    visible: recMode.currentIndex === 2
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    text: "Keeps " + root.motionPad + " seconds before and after each motion event (change this in Server settings) and anything you bookmark. The rest is removed after a couple of minutes. Uses the zones and sensitivity on the Motion tab."
                    color: Theme.textDim
                    wrapMode: Text.Wrap
                    font.pixelSize: 12
                }
                FieldLabel { text: "Low quality"; visible: subUrl.text.trim() !== "" }
                ColumnLayout {
                    visible: subUrl.text.trim() !== ""
                    Layout.fillWidth: true
                    spacing: 2
                    Switch { id: recSub; text: "Also record the low-quality stream"; checked: true }
                    Text {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 100
                        text: "Small tiles then play back recordings smoothly, several at a time. Uses roughly 10–20% more storage."
                        color: Theme.textFaint
                        wrapMode: Text.Wrap
                        font.pixelSize: 11
                    }
                }
                FieldLabel { text: "Keep footage" }
                RowLayout {
                    spacing: 8
                    SpinBox { id: retention; from: 0; to: 3650; value: 30; editable: true; Layout.preferredWidth: 110 }
                    Text { text: "days  (0 = until the disk is full)"; color: Theme.textDim; font.pixelSize: 12 }
                }
                Item { implicitWidth: 1; implicitHeight: 1 }
                Text {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 100
                    text: "The oldest footage is also removed early whenever free disk space runs low."
                    color: Theme.textFaint
                    wrapMode: Text.Wrap
                    font.pixelSize: 11
                }

                FieldLabel { text: "Schedule"; Layout.alignment: Qt.AlignTop; Layout.topMargin: 6 }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 100
                        text: root.schedule.length === 0
                              ? "Optional: use a different mode at certain times, e.g. motion only during the day."
                              : "These times override the mode above (first match wins)."
                        color: Theme.textDim; font.pixelSize: 12; wrapMode: Text.Wrap
                    }
                    Repeater {
                        model: root.schedule
                        RowLayout {
                            id: srow
                            required property var modelData
                            required property int index
                            spacing: 4
                            Repeater {
                                model: 7
                                Rectangle {
                                    required property int index
                                    readonly property var days: srow.modelData.days || []
                                    readonly property bool on: days.length === 0 || days.indexOf(index) >= 0
                                    implicitWidth: 26; implicitHeight: 24; radius: 4
                                    color: on ? Theme.accentSoft : "transparent"
                                    border.color: on ? "#2a6f93" : Theme.border
                                    Text { anchors.centerIn: parent; text: "SMTWTFS".charAt(index); color: parent.on ? Theme.accent : Theme.textFaint; font.pixelSize: 11 }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            var d = parent.days.length === 0 ? [0, 1, 2, 3, 4, 5, 6] : parent.days.slice()
                                            var at = d.indexOf(index)
                                            if (at >= 0) d.splice(at, 1); else d.push(index)
                                            d.sort()
                                            root.changeRule(srow.index, { days: d.length === 7 ? [] : d })
                                        }
                                    }
                                }
                            }
                            TextField {
                                Layout.preferredWidth: 62; Layout.leftMargin: 6
                                text: srow.modelData.from; placeholderText: "08:00"
                                onEditingFinished: if (text !== srow.modelData.from) root.changeRule(srow.index, { from: text.trim() })
                            }
                            Text { text: "–"; color: Theme.textDim }
                            TextField {
                                Layout.preferredWidth: 62
                                text: srow.modelData.to; placeholderText: "18:00"
                                onEditingFinished: if (text !== srow.modelData.to) root.changeRule(srow.index, { to: text.trim() })
                            }
                            ComboBox {
                                Layout.preferredWidth: 130
                                model: ["Off", "Always", "Motion only"]
                                currentIndex: ["off", "continuous", "motion"].indexOf(srow.modelData.mode)
                                onActivated: root.changeRule(srow.index, { mode: ["off", "continuous", "motion"][currentIndex] })
                            }
                            IconButton { iconKind: "close"; iconSize: 10; size: 26; tip: "Remove"; onClicked: root.removeRule(srow.index) }
                        }
                    }
                    AppButton {
                        text: "+  Add time window"
                        kind: "ghost"
                        implicitHeight: 28
                        enabled: root.schedule.length < 20
                        onClicked: root.schedule = root.schedule.concat([{ days: [1, 2, 3, 4, 5], from: "08:00", to: "18:00", mode: "motion" }])
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.preferredWidth: 100
            visible: root.errorText.length > 0
            text: root.errorText
            color: Theme.live
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
            AppButton {
                visible: root.camId > 0
                text: "Delete camera"
                kind: "danger"
                onClicked: confirmDelete.open()
            }
            Item { Layout.fillWidth: true }
            AppButton { text: "Cancel"; onClicked: root.close() }
            AppButton { text: root.camId > 0 ? "Save" : "Add camera"; kind: "primary"; onClicked: root.save() }
        }
    }

    ConfirmDialog {
        id: confirmDelete
        title: "Delete camera?"
        message: "\"" + name.text + "\" is removed and stops recording. Footage already recorded is kept until retention removes it."
        confirmText: "Delete camera"
        danger: true
        onConfirmed: Api.deleteCamera(root.camId, function (err) { if (err) root.errorText = err; else root.close() })
    }
}
