import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
    id: root
    moduleName: "tenzin.auto-workspace"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null

    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || home + "/.config"
    readonly property string pluginId: "tenzin.auto-workspace"
    readonly property string configFile: configHome + "/omarchy/plugins/" + pluginId + "/config.json"
    readonly property string script: home + "/.config/omarchy/plugins/" + pluginId + "/auto-workspace.sh"

    signal countsChanged()

    // data
    property var config: Model.defaultConfig()
    property var assignments: []
    property bool loading: true
    property string errorText: ""
    property string statusText: ""
    property var appList: [] // {name, exec, icon}
    property string appFilter: ""
    property bool showAddForm: false

    // form fields
    property int formWorkspace: 1
    property string formName: ""
    property string formCommand: ""
    property string formType: "app" // app | webapp | custom
    property string formExecPreview: ""

    function open() { root.controller.show(); loadConfig() }
    function close() { root.controller.hide() }
    function toggle() { root.opened ? root.close() : root.open() }
    function closeForPopoutSwitch() { root.close() }

    function switchPanel(dir) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.hostWidget || root, dir)
        return false
    }

    function loadConfig() {
        loading = true
        errorText = ""
        loadProc.running = true
    }

    function saveConfig() {
        var cfg = Model.sanitizeConfig(config)
        cfg.assignments = assignments.slice(0, 50)
        // update exec for each
        for (var i=0;i<cfg.assignments.length;i++) {
            var a = cfg.assignments[i]
            // ensure exec reflects type/command
            if (a.type === "webapp" && a.command.indexOf("http") === 0) {
                a.exec = "omarchy-launch-webapp '" + a.command.replace(/'/g, "'\\''") + "'"
                if (!a.name || a.name === a.command) a.name = Model.displayNameForExec(a.exec, "Web App")
            } else if (a.exec === "" && a.command !== "") {
                a.exec = a.command
            }
            cfg.assignments[i] = a
        }
        config = cfg
        assignments = cfg.assignments.slice()
        var json = JSON.stringify(cfg, null, 2)
        // write via Process
        saveProc.jsonText = json
        saveProc.running = true
    }

    function addAssignment() {
        var name = formName.trim()
        var cmd = formCommand.trim()
        if (!cmd.length) { errorText = "Command / URL is required"; return }
        if (!name.length) {
            // auto-derive
            if (formType === "webapp") name = Model.displayNameForExec("omarchy-launch-webapp '" + cmd + "'", "Web App")
            else name = Model.displayNameForExec(cmd, "App")
        }
        var execStr = cmd
        if (formType === "webapp" && (cmd.indexOf("http://")===0 || cmd.indexOf("https://")===0)) {
            execStr = "omarchy-launch-webapp '" + cmd.replace(/'/g, "'\\''") + "'"
        }
        var item = Model.normalizeAssignment({
            workspace: formWorkspace,
            name: name,
            command: cmd,
            exec: execStr,
            type: formType,
            enabled: true
        })
        assignments = assignments.concat([item])
        config.assignments = assignments.slice()
        // reset form
        formName = ""; formCommand = ""; formType = "app"; formWorkspace = 1
        showAddForm = false
        saveConfig()
        statusText = "Added " + item.name + " → WS" + item.workspace
        clearStatusTimer.restart()
    }

    function removeAssignment(id) {
        assignments = assignments.filter(function(a){ return a.id !== id })
        config.assignments = assignments.slice()
        saveConfig()
        statusText = "Removed"
        clearStatusTimer.restart()
    }

    function toggleEnabled(id) {
        assignments = assignments.map(function(a){
            if (a.id === id) { var b = Model.clone(a); b.enabled = !a.enabled; return b }
            return a
        })
        config.assignments = assignments.slice()
        saveConfig()
    }

    function launchAll(force) {
        statusText = force ? "Force launching..." : "Launching..."
        var cmd = force ? ["bash", root.script, "--force-launch-all"] : ["bash", root.script, "--launch-all"]
        launchProc.command = cmd
        launchProc.running = true
    }

    function updateFormPreview() {
        if (formType === "webapp" && (formCommand.indexOf("http://")===0 || formCommand.indexOf("https://")===0)) {
            formExecPreview = "omarchy-launch-webapp '" + formCommand + "'"
        } else {
            formExecPreview = formCommand
        }
    }

    onFormCommandChanged: updateFormPreview()
    onFormTypeChanged: updateFormPreview()

    Timer { id: clearStatusTimer; interval: 3000; onTriggered: root.statusText = "" }

    // processes
    Process {
        id: loadProc
        command: ["bash", "-c", "mkdir -p \"$(dirname \"$1\")\"; [[ -f \"$1\" ]] || echo '{\"version\":1,\"settings\":{\"enabled\":true,\"launchDelayMs\":800,\"staggerMs\":400,\"silent\":true,\"onlyOnBoot\":true},\"assignments\":[]}' > \"$1\"; cat \"$1\"", "_", root.configFile]
        property string out: ""
        stdout: StdioCollector { id: loadOut; waitForEnd: true }
        stderr: StdioCollector { id: loadErr; waitForEnd: true }
        onExited: function(code){
            root.loading = false
            var txt = loadOut.text || ""
            if (code !== 0) { root.errorText = "Failed to load config ("+code+")"; return }
            try {
                var j = JSON.parse(txt)
                var sane = Model.sanitizeConfig(j)
                root.config = sane
                root.assignments = sane.assignments.slice()
                root.countsChanged()
            } catch(e){ root.errorText = "Invalid config JSON: " + e }
        }
    }

    Process {
        id: saveProc
        property string jsonText: ""
        stdout: StdioCollector { id: saveOut; waitForEnd: true }
        stderr: StdioCollector { id: saveErr; waitForEnd: true }
        onExited: function(code){
            if (code !== 0) { root.errorText = "Save failed ("+code+"): " + (saveErr.text || ""); return }
            root.errorText = ""
            root.countsChanged()
            // notify service to reload
            refreshServiceProc.running = true
        }
        // dynamic command via binding doesn't work well; set on trigger
        onRunningChanged: if (running) {
            // use bash to write atomically
            command = ["bash", "-c", "mkdir -p \"$(dirname \"$1\")\"; printf '%s' \"$2\" > \"$1\"; cat \"$1\" | jq empty && echo OK || echo FAIL", "_", root.configFile, jsonText]
        }
    }

    Process {
        id: refreshServiceProc
        command: ["bash", "-c", "omarchy-shell -q tenzin.auto-workspace refreshConfig >/dev/null 2>&1 || true; omarchy-shell -q tenzin.auto-workspace status >/dev/null 2>&1 || true"]
    }

    Process {
        id: launchProc
        stdout: SplitParser { onRead: function(d){ root.statusText = d.trim().slice(0,80) } }
        stderr: SplitParser { onRead: function(d){ root.errorText = d.trim().slice(0,120) } }
        onExited: function(code){
            if (code===0) { root.statusText = "Launched ✓"; clearStatusTimer.restart() }
            else { root.errorText = "Launch failed ("+code+")"; }
        }
    }

    Process {
        id: appsProc
        command: ["bash", root.script, "--list-apps"]
        property string out: ""
        stdout: StdioCollector { id: appsOut; waitForEnd: true }
        onExited: function(code){
            if (code!==0) return
            var txt = appsOut.text || ""
            var lines = txt.split("\n")
            var list=[]
            for (var i=0;i<lines.length;i++){
                var l = lines[i].trim()
                if (!l) continue
                var parts = l.split("\t")
                if (parts.length<2) continue
                list.push({ name: parts[0], exec: parts[1], icon: parts[2] || "" })
                if (list.length>600) break
            }
            root.appList = list
        }
    }

    // filtered apps
    property var filteredApps: {
        var f = appFilter.trim().toLowerCase()
        if (!f) return appList.slice(0, 20)
        var out=[]
        for (var i=0;i<appList.length;i++){
            var a = appList[i]
            if (a.name.toLowerCase().indexOf(f) !== -1 || a.exec.toLowerCase().indexOf(f) !== -1) {
                out.push(a)
                if (out.length>=20) break
            }
        }
        return out
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(560))
        contentHeight: panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(dir){ root.switchPanel(dir) }

            ColumnLayout {
                id: content
                width: parent.width
                spacing: Style.space(10)

                // Header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    Text {
                        text: "Auto Workspace"
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.title
                        font.bold: true
                        Layout.fillWidth: true
                    }
                    Text {
                        text: root.assignments.length + " rules • " + root.assignments.filter(function(a){return a.enabled}).length + " enabled"
                        color: Qt.darker(root.barForeground, 1.2)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "Apps auto-launch on their workspace after boot/login. Multiple apps per workspace supported."
                    color: Qt.darker(root.barForeground, 1.25)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                // Controls row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(6)

                    Button {
                        text: root.config.settings.enabled ? "Enabled" : "Disabled"
                        selected: root.config.settings.enabled
                        onClicked: {
                            var c = Model.clone(root.config)
                            c.settings.enabled = !c.settings.enabled
                            root.config = c
                            root.saveConfig()
                        }
                        tooltipText: "Toggle entire autostart on/off"
                    }
                    Button {
                        text: root.config.settings.onlyOnBoot ? "Once per boot" : "On every shell start"
                        onClicked: {
                            var c = Model.clone(root.config)
                            c.settings.onlyOnBoot = !c.settings.onlyOnBoot
                            root.config = c
                            root.saveConfig()
                        }
                        tooltipText: "Once per boot avoids duplicates on shell rescan"
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "Launch all"
                        onClicked: root.launchAll(false)
                        tooltipText: "Launch enabled apps now (respects dedup)"
                    }
                    Button {
                        text: "Force"
                        onClicked: root.launchAll(true)
                        tooltipText: "Force launch even if already running"
                    }
                }

                // Status / error
                Text {
                    visible: root.statusText !== ""
                    Layout.fillWidth: true
                    text: root.statusText
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }
                Text {
                    visible: root.errorText !== ""
                    Layout.fillWidth: true
                    text: root.errorText
                    color: Color.urgent || "#ff4444"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                PanelSeparator { Layout.fillWidth: true }

                // Assignments list header
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Workspaces"
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: root.showAddForm ? "Cancel" : "+ Add"
                        onClicked: {
                            root.showAddForm = !root.showAddForm
                            if (root.showAddForm && root.appList.length===0) appsProc.running = true
                        }
                    }
                }

                // Empty state
                Text {
                    visible: !root.loading && root.assignments.length===0 && !root.showAddForm
                    Layout.fillWidth: true
                    text: "No rules yet. Example: assign YouTube to workspace 1 so it always opens there.\nTap + Add to create one."
                    color: Qt.darker(root.barForeground, 1.3)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                // List
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(6)
                    visible: root.assignments.length>0
                    Repeater {
                        model: root.assignments
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            implicitHeight: row.implicitHeight + Style.space(10)
                            radius: Style.cornerRadius
                            color: modelData.enabled ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.02)
                            border.width: 1
                            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, modelData.enabled ? 0.12 : 0.06)
                            RowLayout {
                                id: row
                                anchors.fill: parent
                                anchors.margins: Style.space(8)
                                spacing: Style.space(8)

                                Rectangle {
                                    implicitWidth: 36
                                    implicitHeight: 28
                                    radius: 6
                                    color: modelData.enabled ? Color.accent : Qt.darker(Color.foreground, 1.5)
                                    Text {
                                        anchors.centerIn: parent
                                        text: String(modelData.workspace)
                                        color: Color.background
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name || "Unnamed"
                                        color: modelData.enabled ? root.barForeground : Qt.darker(root.barForeground, 1.4)
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.exec || modelData.command
                                        color: Qt.darker(root.barForeground, 1.35)
                                        font.family: "monospace"
                                        font.pixelSize: Style.font.caption - 1
                                        elide: Text.ElideMiddle
                                        maximumLineCount: 1
                                    }
                                }

                                Button {
                                    text: modelData.enabled ? "on" : "off"
                                    selected: modelData.enabled
                                    onClicked: root.toggleEnabled(modelData.id)
                                    tooltipText: "Enable/disable this rule"
                                }
                                Button {
                                    text: "↗"
                                    onClicked: {
                                        // test launch single
                                        var p = ["bash", root.script, "--launch", String(modelData.workspace), modelData.exec || modelData.command, "true"]
                                        // use manual proc? quick one-off
                                        singleLaunchProc.command = p
                                        singleLaunchProc.running = true
                                        root.statusText = "Launching " + modelData.name + "..."
                                    }
                                    tooltipText: "Launch this one now"
                                }
                                Button {
                                    text: "✕"
                                    onClicked: root.removeAssignment(modelData.id)
                                    tooltipText: "Remove"
                                }
                            }
                        }
                    }

                    // single launch helper
                    Process {
                        id: singleLaunchProc
                        stdout: SplitParser { onRead: function(d){ root.statusText = d.slice(0,80) } }
                        stderr: SplitParser { onRead: function(d){ root.errorText = d.slice(0,100) } }
                        onExited: function(c){ if(c===0) { root.statusText="Launched ✓"; clearStatusTimer.restart() } }
                    }
                }

                // Add form
                ColumnLayout {
                    visible: root.showAddForm
                    Layout.fillWidth: true
                    spacing: Style.space(8)

                    PanelSeparator { Layout.fillWidth: true }

                    Text {
                        text: "Add rule"
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                    }

                    // Workspace picker
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: "Workspace"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                        // simple 1-10 buttons
                        RowLayout {
                            spacing: 4
                            Repeater {
                                model: 10
                                delegate: Button {
                                    required property int index
                                    text: String(index+1)
                                    selected: root.formWorkspace === (index+1)
                                    onClicked: root.formWorkspace = index+1
                                    // compact
                                    horizontalPadding: 8
                                    verticalPadding: 4
                                }
                            }
                        }
                    }

                    // Name
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: "Name"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                        TextField {
                            Layout.fillWidth: true
                            placeholderText: "e.g. YouTube (auto-filled if empty)"
                            text: root.formName
                            onTextChanged: root.formName = text
                        }
                    }

                    // Type
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: "Type"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                        ButtonGroup {
                            id: typeGroup
                        }
                        RowLayout {
                            spacing: Style.space(6)
                            Button {
                                text: "App"
                                selected: root.formType === "app"
                                onClicked: root.formType = "app"
                            }
                            Button {
                                text: "Web App"
                                selected: root.formType === "webapp"
                                onClicked: root.formType = "webapp"
                            }
                            Button {
                                text: "Custom"
                                selected: root.formType === "custom"
                                onClicked: root.formType = "custom"
                            }
                        }
                        Text {
                            text: root.formType === "webapp" ? "URL → omarchy-launch-webapp" : root.formType === "app" ? ".desktop Exec" : "raw command"
                            color: Qt.darker(root.barForeground, 1.3)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }

                    // Command / URL
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: root.formType === "webapp" ? "URL" : "Command"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                        TextField {
                            id: cmdField
                            Layout.fillWidth: true
                            placeholderText: root.formType === "webapp" ? "https://youtube.com" : "e.g. code, chromium, firefox, foot, spotify"
                            text: root.formCommand
                            onTextChanged: root.formCommand = text
                            onAccepted: root.addAssignment()
                        }
                    }

                    Text {
                        visible: root.formExecPreview !== "" && root.formExecPreview !== root.formCommand
                        Layout.fillWidth: true
                        text: "→ " + root.formExecPreview
                        color: Qt.darker(root.barForeground, 1.4)
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption - 1
                        wrapMode: Text.WrapAnywhere
                    }

                    // App picker
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        TextField {
                            id: filterField
                            Layout.fillWidth: true
                            placeholderText: "Filter installed apps (type to search)..."
                            text: root.appFilter
                            onTextChanged: root.appFilter = text
                            onAccepted: {
                                if (root.filteredApps.length>0) {
                                    root.formCommand = root.filteredApps[0].exec
                                    root.formName = root.filteredApps[0].name
                                    if (root.formType !== "webapp") root.formType = "app"
                                }
                            }
                        }
                        Button {
                            text: "Refresh"
                            onClicked: appsProc.running = true
                        }
                    }

                    // filtered list
                    ColumnLayout {
                        visible: root.filteredApps.length>0 && root.formType !== "webapp"
                        Layout.fillWidth: true
                        spacing: 2
                        Repeater {
                            model: root.filteredApps
                            delegate: Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 28
                                radius: Style.cornerRadius
                                color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
                                border.width: 1
                                border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 8
                                    Text {
                                        text: modelData.name
                                        color: root.barForeground
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        text: modelData.exec
                                        color: Qt.darker(root.barForeground, 1.4)
                                        font.family: "monospace"
                                        font.pixelSize: Style.font.caption - 2
                                        Layout.maximumWidth: 180
                                        elide: Text.ElideMiddle
                                    }
                                    Button {
                                        text: "Use"
                                        onClicked: {
                                            root.formCommand = modelData.exec
                                            root.formName = modelData.name
                                            root.formType = "app"
                                        }
                                        verticalPadding: 2
                                        horizontalPadding: 6
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.formCommand = modelData.exec
                                        root.formName = modelData.name
                                        root.formType = "app"
                                    }
                                }
                            }
                        }
                        Text {
                            visible: root.filteredApps.length===0 && root.appFilter.trim().length>0
                            text: "No matches"
                            color: Qt.darker(root.barForeground, 1.4)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Item { Layout.fillWidth: true }
                        Button {
                            text: "Add to WS" + root.formWorkspace
                            selected: true
                            onClicked: root.addAssignment()
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Tips: Multiple apps on same workspace are allowed. Web App URLs open with your default browser via omarchy-launch-webapp. You can set a custom workspace like special:scratchpad (type 11+ not needed, edit config). Test one with ↗ before saving many."
                        color: Qt.darker(root.barForeground, 1.5)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption - 1
                        wrapMode: Text.WordWrap
                    }
                }

                PanelSeparator { Layout.fillWidth: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(6)
                    Text {
                        text: "Config: " + root.configFile
                        color: Qt.darker(root.barForeground, 1.6)
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption - 2
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                    }
                    Button {
                        text: "Open config"
                        onClicked: {
                            var proc = Qt.createQmlObject('import Quickshell.Io; Process {}', root)
                            proc.command = ["bash", "-c", "xdg-open \"$1\" 2>/dev/null || foot -e nvim \"$1\" &", "_", root.configFile]
                            proc.running = true
                        }
                        tooltipText: "Open config.json in editor/viewer"
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "Will run on next login/boot. Click Launch all to test now."
                    color: Qt.darker(root.barForeground, 1.35)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                Item { Layout.fillHeight: true; Layout.preferredHeight: Style.space(4) }
            }
        }
    }

    Component.onCompleted: {
        loadConfig()
        // prefetch apps lazily when panel opened (already triggered via open())
    }
}
