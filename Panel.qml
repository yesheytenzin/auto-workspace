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
    property bool showAddForm: false
    property var expandedWs: ({})
    property string draggedId: ""
    property var liveByWs: ({})

    property int formWorkspace: 1
    property string formName: ""
    property string formCommand: ""
    property string formType: "app"
    property string formExecPreview: ""
    property bool formOnlyOnBoot: false
    onShowAddFormChanged: if (showAddForm) formOnlyOnBoot = Model.defaultOnlyOnBootForType(formType)

    // Visual tokens like lock-explorer
    readonly property color scrim: Color.menu.scrim
    readonly property color cardBg: Color.menu.background
    readonly property color cardFg: Color.menu.text
    readonly property color muted: Qt.rgba(cardFg.r, cardFg.g, cardFg.b, 0.6)
    readonly property int cardRadius: Style.cornerRadius
    readonly property var cardBorderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
    readonly property int gap: Style.space(16)
    readonly property int thumbGap: Style.space(12)

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
        showAddForm=false; saveConfig(); statusText="Added "+item.name+" → WS"+item.workspace; clearStatusTimer.restart()
    }
    function removeAssignment(id) { assignments=assignments.filter(function(a){return a.id!==id}); config.assignments=assignments.slice(); saveConfig(); statusText="Removed"; clearStatusTimer.restart() }
    function toggleEnabled(id) { assignments=assignments.map(function(a){ if(a.id===id){var b=Model.clone(a); b.enabled=!b.enabled; return b} return a}); config.assignments=assignments.slice(); saveConfig() }
    function toggleOnlyOnBoot(id) { assignments=assignments.map(function(a){ if(a.id===id){var b=Model.clone(a); b.onlyOnBoot=!b.onlyOnBoot; return b} return a}); config.assignments=assignments.slice(); saveConfig(); statusText="Updated launch timing"; clearStatusTimer.restart() }
    function isExpanded(ws) { return expandedWs[ws]===true }
    function toggleExpanded(ws) { var n={}; for(var k in expandedWs) n[k]=expandedWs[k]; n[ws]=!n[ws]; expandedWs=n; if(n[ws]&&appList.length===0) appsProc.running=true }
    function getAppsForWs(ws) { var out=[]; for(var i=0;i<assignments.length;i++) if(assignments[i].workspace===ws) out.push(assignments[i]); return out }
    function moveAssignment(id,targetWs,targetIndex) {
        var idx=-1, item=null; for(var i=0;i<assignments.length;i++) if(assignments[i].id===id){idx=i; item=assignments[i]; break}
        if(idx===-1||!item) return
        var newList=assignments.slice(); newList.splice(idx,1)
        var countInTarget=-1, insertAt=newList.length
        for(var j=0;j<newList.length;j++) if(newList[j].workspace===targetWs){countInTarget++; if(countInTarget===targetIndex){insertAt=j; break}}
        if(targetIndex!==0 && countInTarget < targetIndex){
            var last=-1; for(var k=newList.length-1;k>=0;k--) if(newList[k].workspace===targetWs){last=k; break}
            if(last!==-1) insertAt=last+1; else { insertAt=newList.length; for(var p=0;p<newList.length;p++) if(newList[p].workspace>targetWs){insertAt=p; break} }
        }
        var moved=Model.clone(item); moved.workspace=targetWs; newList.splice(insertAt,0,moved)
        assignments=newList; config.assignments=newList.slice(); saveConfig()
        statusText="Moved "+moved.name+" → WS"+targetWs; clearStatusTimer.restart()
        var proc=Qt.createQmlObject('import Quickshell.Io; Process {}', root)
        proc.command=["bash","-c","addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg name \""+moved.name.replace(/\"/g,'')+"\" '.[] | select(.class|test($name;\"i\") or .title|test($name;\"i\")) | .address' | head -n1); [[ -n \"$addr\" ]] && hyprctl eval \"hl.dsp.window.move({workspace=\\\""+targetWs+"\\\", window=\\\"address:$addr\\\", follow:false})\" >/dev/null 2>&1 || true"]
        proc.running=true
    }
    function launchAll(force) { statusText=force?"Force launching...":"Launching..."; launchProc.command=force?["bash",root.script,"--force-launch-all"]:["bash",root.script,"--launch-all"]; launchProc.running=true }
    function updateFormPreview() {
        if(formType==="webapp" && (formCommand.indexOf("http://")===0 || formCommand.indexOf("https://")===0)) formExecPreview="omarchy-launch-webapp '"+formCommand+"'"
        else formExecPreview=formCommand
    }
    onFormCommandChanged: updateFormPreview()
    onFormTypeChanged: { if(showAddForm) formOnlyOnBoot=Model.defaultOnlyOnBootForType(formType); updateFormPreview() }
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
        id: launchProc
        stdout: SplitParser { onRead: function(d){ root.statusText=d.trim().slice(0,80)}}
        stderr: SplitParser { onRead: function(d){ root.errorText=d.trim().slice(0,120)}}
        onExited: function(code){ if(code===0){ root.statusText="Launched ✓"; clearStatusTimer.restart()} else root.errorText="Launch failed ("+code+")"}
    }
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
    Process {
        id: liveProc
        command: ["bash", "-c", "hyprctl clients -j 2>/dev/null | jq -c '[.[] | {ws: .workspace.name, class: .class, title: .title, address: .address}]' 2>/dev/null || echo '[]'"]
        stdout: StdioCollector { id: liveOut; waitForEnd: true }
        onExited: function(code){
            if(code!==0) return
            try{ var arr=JSON.parse(liveOut.text||"[]"), map={}; for(var i=0;i<arr.length;i++){ var w=String(arr[i].ws); if(!map[w]) map[w]=[]; map[w].push(arr[i])} root.liveByWs=map }catch(e){}
        }
    }
    Timer { id: liveTimer; interval: 2000; repeat: true; running: root.opened; triggeredOnStart: true; onTriggered: if(!liveProc.running) liveProc.running=true }
    property var filteredApps: {
        var f=appFilter.trim().toLowerCase()
        if(!f) return appList.slice(0,20)
        var out=[]
        for(var i=0;i<appList.length;i++){ var a=appList[i]; if(a.name.toLowerCase().indexOf(f)!==-1 || a.exec.toLowerCase().indexOf(f)!==-1){ out.push(a); if(out.length>=20) break } }
        return out
    }

    // ——— centered card like lock-explorer ———
    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        centerOnBar: true
        focusTarget: keyCatcher
        // lock-explorer card sizing: min(1560, screen - gaps*4)
        contentWidth: panel.fittedContentWidth(Math.min(Style.space(1100), panel.screenW - Style.gapsOut*4))
        contentHeight: panel.fittedContentHeight(content.implicitHeight, panel.screenH - Style.gapsOut*2 - Style.space(40))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(dir){ root.switchPanel(dir) }

            // scrim behind card (like Explorer)
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0,0,0,0.35)
                visible: true
                MouseArea { anchors.fill: parent; onClicked: root.close() }
            }

            BorderSurface {
                id: card
                anchors.centerIn: parent
                width: Math.min(Style.space(1100), panel.screenW - Style.gapsOut*4)
                height: Math.min(content.implicitHeight + Style.space(32), panel.screenH - Style.gapsOut*2 - Style.space(20))
                radius: Style.cornerRadius
                color: Color.menu.background
                borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

                ColumnLayout {
                    id: content
                    anchors.fill: parent
                    anchors.margins: Style.space(16)
                    spacing: Style.space(10)

                    // Header — lock-explorer style
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            RowLayout {
                                spacing: Style.space(8)
                                Text { text: "Auto Workspace"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.display; font.bold: true }
                                Rectangle {
                                    implicitHeight: 18; implicitWidth: verText.implicitWidth+10; radius: 9; color: Color.accent
                                    Text { id: verText; anchors.centerIn: parent; text: "2.0 centered"; color: "white"; font.family: Style.font.family; font.pixelSize: Style.font.caption-2; font.bold: true }
                                }
                            }
                            Text {
                                text: root.assignments.length + " rules • " + root.assignments.filter(function(a){return a.enabled}).length + " enabled  —  WS 1-10 • drag to move • live Hypr preview"
                                color: muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
                            }
                        }
                        Button { text: root.config.settings.enabled?"Enabled":"Disabled"; selected: root.config.settings.enabled; onClicked: { var c=Model.clone(root.config); c.settings.enabled=!c.settings.enabled; root.config=c; root.saveConfig() } }
                        Button { text: "Launch all"; onClicked: root.launchAll(false) }
                        Button { text: "Force"; onClicked: root.launchAll(true) }
                    }

                    Text {
                        visible: root.statusText!==""
                        Layout.fillWidth: true
                        text: root.statusText; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                    }
                    Text {
                        visible: root.errorText!==""
                        Layout.fillWidth: true
                        text: root.errorText; color: Color.urgent||"#ff4444"; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                    }

                    PanelSeparator { Layout.fillWidth: true }

                    // Add form — collapsible
                    ColumnLayout {
                        visible: root.showAddForm
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        PanelSeparator { Layout.fillWidth: true }
                        Text { text: "Add rule"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
                        // WS picker 1-10
                        RowLayout {
                            Layout.fillWidth: true; spacing: Style.space(8)
                            Text { text: "Workspace"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                            RowLayout { spacing: 4; Repeater { model: 10; delegate: Button { required property int index; text: String(index+1); selected: root.formWorkspace===(index+1); onClicked: root.formWorkspace=index+1; horizontalPadding: 8; verticalPadding: 4 } } }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: Style.space(8)
                            Text { text: "Name"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                            TextField { Layout.fillWidth: true; placeholderText: "e.g. YouTube"; text: root.formName; onTextChanged: root.formName=text }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: Style.space(8)
                            Text { text: "Type"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                            RowLayout { spacing: Style.space(6)
                                Button { text: "App"; selected: root.formType==="app"; onClicked: root.formType="app" }
                                Button { text: "Web App"; selected: root.formType==="webapp"; onClicked: root.formType="webapp" }
                                Button { text: "Custom"; selected: root.formType==="custom"; onClicked: root.formType="custom" }
                            }
                            Text { text: root.formType==="webapp"?"URL → omarchy-launch-webapp":root.formType==="app"?".desktop Exec":"raw command"; color: Qt.darker(root.barForeground,1.3); font.family: Style.font.family; font.pixelSize: Style.font.caption }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: Style.space(8)
                            Text { text: "Launch"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                            Button { text: root.formOnlyOnBoot?"Once per boot":"Every restart"; selected: root.formOnlyOnBoot; onClicked: root.formOnlyOnBoot=!root.formOnlyOnBoot }
                            Text { text: root.formOnlyOnBoot?"once":"every — resilient"; color: Qt.darker(root.barForeground,1.4); font.family: Style.font.family; font.pixelSize: Style.font.caption }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: Style.space(8)
                            Text { text: root.formType==="webapp"?"URL":"Command"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.preferredWidth: 80 }
                            TextField { id: cmdField; Layout.fillWidth: true; placeholderText: root.formType==="webapp"?"https://youtube.com":"e.g. code, foot, spotify"; text: root.formCommand; onTextChanged: root.formCommand=text; onAccepted: root.addAssignment() }
                        }
                        Text { visible: root.formExecPreview!=="" && root.formExecPreview!==root.formCommand; Layout.fillWidth: true; text: "→ "+root.formExecPreview; color: Qt.darker(root.barForeground,1.4); font.family: "monospace"; font.pixelSize: Style.font.caption-1; wrapMode: Text.WrapAnywhere }
                        RowLayout {
                            Layout.fillWidth: true; spacing: Style.space(8)
                            TextField { id: filterField; Layout.fillWidth: true; placeholderText: "Filter installed apps..."; text: root.appFilter; onTextChanged: root.appFilter=text; onAccepted: if(root.filteredApps.length>0){ root.formCommand=root.filteredApps[0].exec; root.formName=root.filteredApps[0].name } }
                            Button { text: "Refresh"; onClicked: appsProc.running=true }
                        }
                        ColumnLayout {
                            visible: root.filteredApps.length>0 && root.formType!=="webapp"
                            Layout.fillWidth: true; spacing: 2
                            Repeater {
                                model: root.filteredApps
                                delegate: Rectangle {
                                    required property var modelData; Layout.fillWidth: true; implicitHeight: 28; radius: Style.cornerRadius; color: Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.04); border.width: 1; border.color: Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.08)
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                        Text { text: modelData.name; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.fillWidth: true; elide: Text.ElideRight }
                                        Text { text: modelData.exec; color: Qt.darker(root.barForeground,1.4); font.family: "monospace"; font.pixelSize: Style.font.caption-2; Layout.maximumWidth: 180; elide: Text.ElideMiddle }
                                        Button { verticalPadding: 2; horizontalPadding: 6; text: "Use"; onClicked: { root.formCommand=modelData.exec; root.formName=modelData.name; root.formType="app" } }
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: { root.formCommand=modelData.exec; root.formName=modelData.name; root.formType="app" } }
                                }
                            }
                        }
                        RowLayout { Layout.fillWidth: true; Item{Layout.fillWidth:true} Button { text: "Add to WS"+root.formWorkspace; selected: true; onClicked: root.addAssignment() } }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "Workspaces 1-10 — drag tiles to reorder / move"; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
                        Item{Layout.fillWidth:true}
                        Button { text: root.showAddForm?"Cancel":"+ Add"; onClicked: { root.showAddForm=!root.showAddForm; if(root.showAddForm&&root.appList.length===0) appsProc.running=true } }
                    }

                    // ——— 3-col grid like lock-explorer Explorer.qml:637 ———
                    GridLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        columns: 2
                        columnSpacing: Style.space(12)
                        rowSpacing: Style.space(12)
                        Repeater {
                            model: 10
                            delegate: Rectangle {
                                required property int index
                                property int ws: index+1
                                property var appsForWs: root.getAppsForWs(ws)
                                property var liveForWs: root.liveByWs[String(ws)] || []
                                property bool expanded: root.isExpanded(ws)
                                Layout.fillWidth: true
                                Layout.preferredHeight: expanded ? 210 : 132
                                radius: Style.cornerRadius
                                color: expanded ? Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.04) : Color.menu.background
                                border.width: 1
                                border.color: appsForWs.length>0 ? Qt.rgba(Color.accent.r,Color.accent.g,Color.accent.b,0.18) : Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.08)

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: Style.space(8)
                                    spacing: Style.space(6)
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: Style.space(6)
                                        Rectangle { implicitWidth: 28; implicitHeight: 22; radius: 6; color: appsForWs.length>0?Color.accent:Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.12); Text{ anchors.centerIn: parent; text: String(ws); color: appsForWs.length>0?Color.background:Qt.darker(Color.foreground,1.1); font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true } }
                                        Text { text: appsForWs.length>0?appsForWs.map(function(a){return a.name}).join(" · "):"Empty"; color: appsForWs.length>0?root.barForeground:Qt.darker(root.barForeground,1.4); font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.fillWidth: true; elide: Text.ElideRight; font.bold: appsForWs.length>0 }
                                        Text { visible: liveForWs.length>0; text: "● "+liveForWs.length+" live"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.caption-2; font.bold: true }
                                        Button { text: expanded?"Hide":(appsForWs.length>0?"Show":"+ Add"); onClicked: root.toggleExpanded(ws) }
                                        Button { visible: appsForWs.length>0; text: "↗"; tooltipText: "Launch WS"+ws; onClicked: { for(var i=0;i<appsForWs.length;i++){ var p=["bash",root.script,"--launch",String(ws),appsForWs[i].exec||appsForWs[i].command,"true"]; singleLaunchProc.command=p; singleLaunchProc.running=true } root.statusText="Launching WS"+ws+"..." } }
                                    }
                                    WorkspacePreview {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 92
                                        workspace: ws
                                        assignedApps: appsForWs
                                        liveClients: liveForWs
                                        draggedIdGlobal: root.draggedId
                                        onDropRequest: function(draggedId, targetWs, targetIndex){ root.moveAssignment(draggedId, targetWs, targetIndex) }
                                        onDragStarted: function(id){ root.draggedId=id }
                                        onDragEnded: function(){ root.draggedId="" }
                                    }
                                    // expanded list
                                    ColumnLayout {
                                        visible: expanded
                                        Layout.fillWidth: true; spacing: 4
                                        Repeater {
                                            model: appsForWs
                                            delegate: Rectangle {
                                                required property var modelData; Layout.fillWidth: true; implicitHeight: 30; radius: 6; color: Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.03); border.width: 1; border.color: Qt.rgba(Color.foreground.r,Color.foreground.g,Color.foreground.b,0.06)
                                                RowLayout {
                                                    anchors.fill: parent; anchors.margins: Style.space(6); spacing: 6
                                                    Text { text: modelData.name; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.fillWidth: true; elide: Text.ElideRight }
                                                    Text { text: modelData.onlyOnBoot?"once":"every"; color: modelData.onlyOnBoot?Color.accent:Qt.darker(Color.foreground,1.2); font.family: Style.font.family; font.pixelSize: Style.font.caption-2 }
                                                    Button { text: modelData.enabled?"on":"off"; selected: modelData.enabled; onClicked: root.toggleEnabled(modelData.id) }
                                                    Button { text: "✕"; onClicked: root.removeAssignment(modelData.id) }
                                                }
                                                MouseArea { anchors.fill: parent; drag.threshold: 6; onPressed: root.draggedId=modelData.id; onReleased: root.draggedId="" }
                                            }
                                        }
                                        Button { Layout.alignment: Qt.AlignLeft; text: "+ Add app to WS"+ws; onClicked: { root.formWorkspace=ws; root.formOnlyOnBoot=Model.defaultOnlyOnBootForType(root.formType); root.showAddForm=true } }
                                    }
                                }
                            }
                        }
                    }

                    Process {
                        id: singleLaunchProc
                        stdout: SplitParser { onRead: function(d){ root.statusText=d.slice(0,80)}}
                        stderr: SplitParser { onRead: function(d){ root.errorText=d.slice(0,100)}}
                        onExited: function(c){ if(c===0){ root.statusText="Launched ✓"; clearStatusTimer.restart()} }
                    }

                    PanelSeparator { Layout.fillWidth: true }
                    RowLayout {
                        Layout.fillWidth: true; spacing: Style.space(6)
                        Text { text: "Config: "+root.configFile; color: Qt.darker(root.barForeground,1.6); font.family: "monospace"; font.pixelSize: Style.font.caption-2; Layout.fillWidth: true; elide: Text.ElideMiddle }
                        Button { text: "Open config"; onClicked: { var proc=Qt.createQmlObject('import Quickshell.Io; Process {}', root); proc.command=["bash","-c","xdg-open \"$1\" 2>/dev/null || foot -e nvim \"$1\" &","_",root.configFile]; proc.running=true } }
                    }
                    Text { Layout.fillWidth: true; text: "Tip: drag tiles in preview to reorder or move between workspaces — live windows update every 2s."; color: Qt.darker(root.barForeground,1.35); font.family: Style.font.family; font.pixelSize: Style.font.caption-1; wrapMode: Text.WordWrap }
                }
            }
        }
    }

    Component.onCompleted: loadConfig()
}
