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

    property var config: Model.defaultConfig()
    property var assignments: []
    property bool loading: true
    property string errorText: ""
    property string statusText: ""
    property var appList: []
    property string appFilter: ""
    property bool adding: false
    property int formWorkspace: 1
    property string formName: ""
    property string formCommand: ""
    property string formType: "app"
    property string formExecPreview: ""
    property bool formOnlyOnBoot: false
    onFormTypeChanged: { formOnlyOnBoot = Model.defaultOnlyOnBootForType(formType); updateFormPreview() }

    function open() { root.controller.show(); loadConfig() }
    function close() { root.controller.hide() }
    function toggle() { root.opened ? root.close() : root.open() }
    function closeForPopoutSwitch() { root.close() }
    function switchPanel(dir) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.hostWidget || root, dir)
        return false
    }

    function loadConfig() { loading=true; errorText=""; loadProc.running=true }
    function saveConfig() {
        var cfg = Model.sanitizeConfig(config)
        cfg.assignments = assignments.slice(0, 50)
        for (var i=0;i<cfg.assignments.length;i++) {
            var a=cfg.assignments[i]
            if (a.type==="webapp" && a.command.indexOf("http")===0) {
                a.exec = "omarchy-launch-webapp '" + a.command.replace(/'/g,"'\\''") + "'"
                if (!a.name || a.name===a.command) a.name = Model.displayNameForExec(a.exec, "Web App")
            } else if (a.exec==="" && a.command!=="") a.exec=a.command
            cfg.assignments[i]=a
        }
        config=cfg; assignments=cfg.assignments.slice()
        saveProc.jsonText = JSON.stringify(cfg,null,2)
        saveProc.running=true
    }
    function addAssignment() {
        var name=formName.trim(), cmd=formCommand.trim()
        if (!cmd.length) { errorText="Command / URL is required"; return }
        if (!name.length) {
            if (formType==="webapp") name=Model.displayNameForExec("omarchy-launch-webapp '"+cmd+"'", "Web App")
            else name=Model.displayNameForExec(cmd, "App")
        }
        var execStr=cmd
        if (formType==="webapp" && (cmd.indexOf("http://")===0 || cmd.indexOf("https://")===0))
            execStr="omarchy-launch-webapp '" + cmd.replace(/'/g,"'\\''") + "'"
        var item=Model.normalizeAssignment({workspace:formWorkspace, name:name, command:cmd, exec:execStr, type:formType, enabled:true, onlyOnBoot:formOnlyOnBoot})
        assignments=assignments.concat([item]); config.assignments=assignments.slice()
        formName=""; formCommand=""; formType="app"; formWorkspace=1; formOnlyOnBoot=Model.defaultOnlyOnBootForType("app")
        saveConfig(); statusText="Added "+item.name+" → WS"+item.workspace; clearStatusTimer.restart()
        if (root.bar && typeof root.bar.broadcast === "function") root.bar.broadcast("refreshCounts")
        root.countsChanged()
    }
    function updateFormPreview() {
        if(formType==="webapp" && (formCommand.indexOf("http://")===0 || formCommand.indexOf("https://")===0)) formExecPreview="omarchy-launch-webapp '"+formCommand+"'"
        else formExecPreview=formCommand
    }
    onFormCommandChanged: updateFormPreview()
    Timer { id: clearStatusTimer; interval: 3000; onTriggered: root.statusText="" }

    Process {
        id: loadProc
        command: ["bash", "-c", "mkdir -p \"$(dirname \"$1\")\"; [[ -f \"$1\" ]] || echo '{\"version\":1,\"settings\":{\"enabled\":true,\"launchDelayMs\":800,\"staggerMs\":400,\"silent\":true,\"onlyOnBoot\":true},\"assignments\":[]}' > \"$1\"; cat \"$1\"", "_", root.configFile]
        stdout: StdioCollector { id: loadOut; waitForEnd: true }
        stderr: StdioCollector { id: loadErr; waitForEnd: true }
        onExited: function(code){
            root.loading=false; var txt=loadOut.text||""
            if(code!==0){ root.errorText="Failed to load config ("+code+")"; return}
            try{ var j=JSON.parse(txt); var sane=Model.sanitizeConfig(j); root.config=sane; root.assignments=sane.assignments.slice(); root.countsChanged() }catch(e){ root.errorText="Invalid config JSON: "+e}
        }
    }
    Process {
        id: saveProc
        property string jsonText: ""
        stdout: StdioCollector { id: saveOut; waitForEnd: true }
        stderr: StdioCollector { id: saveErr; waitForEnd: true }
        onExited: function(code){
            if(code!==0){ root.errorText="Save failed ("+code+"): "+(saveErr.text||""); return}
            root.errorText=""; root.countsChanged(); refreshServiceProc.running=true
        }
        onRunningChanged: if(running){ command=["bash","-c","mkdir -p \"$(dirname \"$1\")\"; printf '%s' \"$2\" > \"$1\"; cat \"$1\" | jq empty && echo OK || echo FAIL", "_", root.configFile, jsonText] }
    }
    Process { id: refreshServiceProc; command: ["bash","-c","omarchy-shell -q tenzin.auto-workspace refreshConfig >/dev/null 2>&1 || true"] }
    Process {
        id: appsProc
        command: ["bash", root.script, "--list-apps"]
        stdout: StdioCollector { id: appsOut; waitForEnd: true }
        onExited: function(code){
            if(code!==0) return
            var txt=appsOut.text||"", lines=txt.split("\n"), list=[]
            for(var i=0;i<lines.length;i++){ var l=lines[i].trim(); if(!l) continue; var p=l.split("\t"); if(p.length<2) continue; list.push({name:p[0],exec:p[1],icon:p[2]||""}); if(list.length>600) break}
            root.appList=list
        }
    }
    property var filteredApps: {
        var f=appFilter.trim().toLowerCase()
        if(!f) return appList.slice(0,20)
        var out=[]
        for(var i=0;i<appList.length;i++){ var a=appList[i]; if(a.name.toLowerCase().indexOf(f)!==-1 || a.exec.toLowerCase().indexOf(f)!==-1){ out.push(a); if(out.length>=20) break } }
        return out
    }

    // ——— centered card: ONLY the add-apps UI ———
    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        centerOnBar: true
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(560))
        contentHeight: panel.fittedContentHeight(content.implicitHeight, panel.screenH - Style.gapsOut*2 - Style.space(40))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(dir){ root.switchPanel(dir) }

            // scrim
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0,0,0,0.35)
                MouseArea { anchors.fill: parent; onClicked: root.close() }
            }

            BorderSurface {
                id: card
                anchors.centerIn: parent
                width: Math.min(Style.space(560), panel.screenW - Style.gapsOut*4)
                implicitHeight: content.implicitHeight + Style.space(32)
                radius: Style.cornerRadius
                color: Color.menu.background
                borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

                ColumnLayout {
                    id: content
                    anchors.fill: parent
                    anchors.margins: Style.space(20)
                    spacing: Style.space(12)

                    // Title
                    Text {
                        text: "Add apps to workspace"
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.display
                        font.bold: true
                    }
                    Text {
                        text: "Pick a workspace, then add an app or web app. Repeat for more."
                        color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.6)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    // Workspace picker 1-10
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: "Workspace"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 90 }
                        RowLayout {
                            spacing: 4
                            Repeater {
                                model: 10
                                delegate: Button {
                                    required property int index
                                    text: String(index+1)
                                    selected: root.formWorkspace===(index+1)
                                    onClicked: root.formWorkspace=index+1
                                    horizontalPadding: 10; verticalPadding: 6
                                }
                            }
                        }
                    }

                    // Name
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: "Name"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 90 }
                        TextField {
                            Layout.fillWidth: true
                            placeholderText: "e.g. YouTube (auto-filled if empty)"
                            text: root.formName
                            onTextChanged: root.formName=text
                        }
                    }

                    // Type
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: "Type"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 90 }
                        RowLayout { spacing: Style.space(6)
                            Button { text: "App"; selected: root.formType==="app"; onClicked: root.formType="app" }
                            Button { text: "Web App"; selected: root.formType==="webapp"; onClicked: root.formType="webapp" }
                            Button { text: "Custom"; selected: root.formType==="custom"; onClicked: root.formType="custom" }
                        }
                    }

                    // Launch timing
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: "Launch"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 90 }
                        Button {
                            text: root.formOnlyOnBoot ? "Once per boot" : "Every restart"
                            selected: root.formOnlyOnBoot
                            onClicked: root.formOnlyOnBoot=!root.formOnlyOnBoot
                        }
                        Text {
                            text: root.formOnlyOnBoot ? "no duplicate on rescan" : "comes back on shell restart"
                            color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption-1
                        }
                    }

                    // Command / URL
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text { text: root.formType==="webapp" ? "URL" : "Command"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 90 }
                        TextField {
                            Layout.fillWidth: true
                            placeholderText: root.formType==="webapp" ? "https://youtube.com" : "e.g. code, foot, spotify"
                            text: root.formCommand
                            onTextChanged: root.formCommand=text
                            onAccepted: root.addAssignment()
                        }
                    }
                    Text {
                        visible: root.formExecPreview!=="" && root.formExecPreview!==root.formCommand
                        Layout.fillWidth: true
                        text: "→ "+root.formExecPreview
                        color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.6)
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption-1
                        wrapMode: Text.WrapAnywhere
                    }

                    // App picker
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        TextField {
                            id: filterField
                            Layout.fillWidth: true
                            placeholderText: "Search installed apps..."
                            text: root.appFilter
                            onTextChanged: root.appFilter=text
                            onAccepted: if(root.filteredApps.length>0){ root.formCommand=root.filteredApps[0].exec; root.formName=root.filteredApps[0].name }
                        }
                        Button { text: "Refresh"; onClicked: appsProc.running=true }
                    }

                    ColumnLayout {
                        visible: root.filteredApps.length>0 && root.formType!=="webapp"
                        Layout.fillWidth: true
                        spacing: 2
                        Repeater {
                            model: root.filteredApps
                            delegate: Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 32
                                radius: Style.cornerRadius
                                color: Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.04)
                                border.width: 1
                                border.color: Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.08)
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10; anchors.rightMargin: 6
                                    spacing: 8
                                    Text { text: modelData.name; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.fillWidth: true; elide: Text.ElideRight }
                                    Text { text: modelData.exec; color: Qt.rgba(root.barForeground.r,root.barForeground.g,root.barForeground.b,0.6); font.family: "monospace"; font.pixelSize: Style.font.caption-2; Layout.maximumWidth: 200; elide: Text.ElideMiddle }
                                    Button { verticalPadding: 2; horizontalPadding: 8; text: "Use"; onClicked: { root.formCommand=modelData.exec; root.formName=modelData.name; root.formType="app" } }
                                }
                            }
                        }
                        Text {
                            visible: root.filteredApps.length===0 && root.appFilter.trim().length>0
                            text: "No matches"
                            color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }

                    // Status / error
                    Text {
                        visible: root.statusText!==""
                        Layout.fillWidth: true
                        text: root.statusText
                        color: Color.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        visible: root.errorText!==""
                        Layout.fillWidth: true
                        text: root.errorText
                        color: Color.urgent || "#ff4444"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    // Add button
                    RowLayout {
                        Layout.fillWidth: true
                        Item { Layout.fillWidth: true }
                        Button {
                            text: "Add to WS " + root.formWorkspace
                            selected: true
                            onClicked: root.addAssignment()
                        }
                    }
                }
            }
        }
    }

    Component.onCompleted: { loadConfig(); appsProc.running = true }
}