import QtQuick
import QtQuick.Controls
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
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
    readonly property string pluginId: "tenzin.auto-workspace"
    // Outside the plugin dir: the shell reloads the plugin on any file change there
    readonly property string configFile: stateHome + "/omarchy/auto-workspace/config.json"
    readonly property string legacyConfigFile: configHome + "/omarchy/plugins/" + pluginId + "/config.json"
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
    property bool workspacePicked: false
    property string formName: ""
    property string formCommand: ""
    property string formType: "app"
    property string formExecPreview: ""
    property bool formNameEdited: false
    property string autoName: ""
    property bool fillingName: false
    onFormTypeChanged: { updateFormPreview(); updateAutofillName() }

    // --- keyboard cursor model (plugin-manager pattern) ---
    property bool cursorActive: false
    property int selectedRow: 0
    property int selectedButton: 0

    readonly property color foreground: root.barForeground
    readonly property color dim: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.55)
    readonly property string fontFamily: Style.font.family

    readonly property int totalCount: assignments.length
    readonly property int enabledCount: (function(){
        var n = 0
        for (var i = 0; i < assignments.length; i++) if (assignments[i].enabled !== false) n++
        return n
    })()

    function open() { root.controller.show(); loadConfig(); root.workspacePicked = true }
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
        saveProc.pendingJson = JSON.stringify(cfg,null,2)
        if (saveProc.running) { saveProc.wantsSave = true; return }
        saveProc.command=["bash","-c","mkdir -p \"$(dirname \"$1\")\"; printf '%s' \"$2\" > \"$1\"; cat \"$1\" | jq empty && echo OK || echo FAIL", "_", root.configFile, saveProc.pendingJson]
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
        var item=Model.normalizeAssignment({workspace:formWorkspace, name:name, command:cmd, exec:execStr, type:formType, enabled:true, onlyOnBoot:true})
        assignments=assignments.concat([item]); config.assignments=assignments.slice()
        formName=""; formCommand=""; formType="app"; formNameEdited=false
        saveConfig(); statusText="Added "+item.name+" → WS"+item.workspace; clearStatusTimer.restart()
        if (root.bar && typeof root.bar.broadcast === "function") root.bar.broadcast("refreshCounts")
        root.countsChanged()
    }
    function updateFormPreview() {
        if(formType==="webapp" && (formCommand.indexOf("http://")===0 || formCommand.indexOf("https://")===0)) formExecPreview="omarchy-launch-webapp '"+formCommand+"'"
        else formExecPreview=formCommand
    }
    function persistFormWorkspace() {
        var s=Model.clone(root.config); s.settings.lastFormWorkspace=root.formWorkspace; root.config=s; root.saveConfig()
    }
    function removeAssignment(id) {
        root.assignments=root.assignments.filter(function(a){return a.id!==id})
        root.config.assignments=root.assignments.slice()
        root.saveConfig()
        root.statusText="Removed"; clearStatusTimer.restart()
    }
    function isInList(list, exec) {
        if (!list) return false
        for (var i=0;i<list.length;i++) if (list[i].exec===exec || list[i].command===exec) return true
        return false
    }
    function toggleInWorkspace(exec, name) {
        var ws=root.formWorkspace
        for (var i=0;i<root.assignments.length;i++) {
            var a=root.assignments[i]
            if (a.workspace===ws && (a.exec===exec || a.command===exec)) {
                root.removeAssignment(a.id)
                root.statusText="Removed "+a.name+" from WS"+ws; clearStatusTimer.restart()
                return
            }
        }
        var item=Model.normalizeAssignment({workspace:ws, name:name, command:exec, exec:exec, type:"app", enabled:true, onlyOnBoot:true})
        root.assignments=root.assignments.concat([item]); root.config.assignments=root.assignments.slice()
        root.saveConfig(); root.statusText="Added "+item.name+" → WS"+item.workspace; clearStatusTimer.restart()
        if (root.bar && typeof root.bar.broadcast === "function") root.bar.broadcast("refreshCounts")
        root.countsChanged()
    }
    function updateAutofillName() {
        var cmd=formCommand.trim()
        if (!cmd.length) { autoName=""; if (!formNameEdited) { fillingName=true; formName=""; fillingName=false } return }
        var n
        if (formType==="webapp" && (cmd.indexOf("http://")===0 || cmd.indexOf("https://")===0)) n=Model.displayNameForExec("omarchy-launch-webapp '"+cmd+"'", "Web App")
        else n=Model.displayNameForExec(cmd, "App")
        autoName=n
        if (!formNameEdited) { fillingName=true; formName=n; fillingName=false }
    }
    onFormCommandChanged: { updateFormPreview(); updateAutofillName() }
    Timer { id: clearStatusTimer; interval: 3000; onTriggered: root.statusText="" }

    // --- cursor model helpers (plugin-manager pattern) ---
    function actionCount(app) { return 1 }

    function clampCursor() {
        var rows = filteredApps
        if (rows.length === 0) { selectedRow = 0; selectedButton = 0; return }
        selectedRow = Math.max(0, Math.min(selectedRow, rows.length - 1))
        selectedButton = Math.max(0, Math.min(selectedButton, actionCount(rows[selectedRow]) - 1))
    }

    function setCursor(row, button) {
        cursorActive = true
        selectedRow = row
        selectedButton = button
        clampCursor()
    }

    function moveCursor(dx, dy) {
        var rows = filteredApps
        if (rows.length === 0) return
        if (!cursorActive) { setCursor(0, 0); return }
        if (dy !== 0) {
            if (dy < 0 && selectedRow === 0) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            if (dy > 0 && selectedRow === rows.length - 1) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            selectedRow = Math.max(0, Math.min(rows.length - 1, selectedRow + dy))
            selectedButton = Math.min(selectedButton, actionCount(rows[selectedRow]) - 1)
        } else if (dx !== 0) {
            selectedButton = Math.max(0, Math.min(actionCount(rows[selectedRow]) - 1, selectedButton + dx))
        }
        cursorActive = true
    }

    function moveTabCursor(direction) {
        var rows = filteredApps
        if (rows.length === 0) return
        if (!cursorActive) {
            if (direction > 0) setCursor(0, 0)
            else return
            return
        }
        if (direction > 0) {
            if (selectedRow === rows.length - 1) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            selectedRow++
            selectedButton = 0
        } else {
            if (selectedRow === 0) {
                cursorActive = false
                filterField.forceActiveFocus()
                return
            }
            selectedRow--
            selectedButton = actionCount(rows[selectedRow]) - 1
        }
        cursorActive = true
    }

    function activateCursor() {
        var app = filteredApps[selectedRow]
        if (!app) return
        toggleInWorkspace(app.exec, app.name)
    }

    function ensureCursorVisible(item) {
        if (!item || !resultsScroll) return
        var flick = resultsScroll.contentItem
        var point = item.mapToItem(flick.contentItem || flick, 0, 0)
        var top = point.y
        var bottom = top + item.height
        if (top < flick.contentY) flick.contentY = Math.max(0, top - Style.space(8))
        else if (bottom > flick.contentY + flick.height)
            flick.contentY = bottom - flick.height + Style.space(8)
    }

    Process {
        id: loadProc
        command: ["bash", "-c", "mkdir -p \"$(dirname \"$1\")\"; [[ -f \"$1\" || ! -f \"$3\" ]] || cp \"$3\" \"$1\"; [[ -f \"$1\" ]] || echo '{\"version\":1,\"settings\":{\"enabled\":true,\"launchDelayMs\":800,\"staggerMs\":400,\"silent\":true,\"onlyOnBoot\":true,\"lastFormWorkspace\":1},\"assignments\":[]}' > \"$1\"; cat \"$1\"", "_", root.configFile, "", root.legacyConfigFile]
        stdout: StdioCollector { id: loadOut; waitForEnd: true }
        stderr: StdioCollector { id: loadErr; waitForEnd: true }
        onExited: function(code){
            root.loading=false; var txt=loadOut.text||""
            if(code!==0){ root.errorText="Failed to load config ("+code+")"; return}
            try{ var j=JSON.parse(txt); var sane=Model.sanitizeConfig(j); root.config=sane; root.assignments=sane.assignments.slice(); root.formWorkspace=sane.settings.lastFormWorkspace; root.countsChanged() }catch(e){ root.errorText="Invalid config JSON: "+e}
        }
    }
    Process {
        id: saveProc
        property string pendingJson: ""
        property bool wantsSave: false
        stdout: StdioCollector { id: saveOut; waitForEnd: true }
        stderr: StdioCollector { id: saveErr; waitForEnd: true }
        onExited: function(code){
            if(code!==0){ root.errorText="Save failed ("+code+"): "+(saveErr.text||""); }
            else root.errorText=""
            if (saveProc.wantsSave) {
                saveProc.wantsSave=false
                saveProc.command=["bash","-c","mkdir -p \"$(dirname \"$1\")\"; printf '%s' \"$2\" > \"$1\"; cat \"$1\" | jq empty && echo OK || echo FAIL", "_", root.configFile, saveProc.pendingJson]
                saveProc.running=true
            } else if (code===0) {
                root.countsChanged(); refreshServiceProc.running=true
            }
        }
    }
    Process { id: refreshServiceProc; command: ["bash","-c","omarchy-shell -q tenzin.auto-workspace refreshConfig >/dev/null 2>&1 || true"] }
    Process {
        id: appsProc
        command: ["bash", root.script, "--list-apps"]
        stdout: StdioCollector { id: appsOut; waitForEnd: true }
        onExited: function(code){
            if(code!==0) return
            var txt=appsOut.text||"", lines=txt.split("\n"), list=[]
            for(var i=0;i<lines.length;i++){ var l=lines[i].trim(); if(!l) continue; var p=l.split("\t"); if(p.length<2) continue; list.push({name:p[0],exec:p[1],icon:p[2]||"",score:Number(p[4])||0}); if(list.length>600) break}
            root.appList=list
        }
    }
    function alphabeticalCompare(a, b) {
        var na = a.name.toLowerCase(), nb = b.name.toLowerCase()
        return na.localeCompare(nb, undefined, { numeric: true })
    }
    function isActivated(exec) {
        for (var i = 0; i < assignments.length; i++)
            if (assignments[i].exec === exec || assignments[i].command === exec) return true
        return false
    }
    property var filteredApps: {
        var f = appFilter.trim().toLowerCase()
        var list = []
        for (var i=0;i<appList.length;i++){
            list.push(appList[i])
        }
        if (!f) {
            // No apps assigned yet → show commonly used; once any are
            // assigned, show only the activated ones
            var act = list.filter(function(a){ return root.isActivated(a.exec) })
            var pool = act.length > 0 ? act : list
            pool.sort(function(a, b){
                if (b.score !== a.score) return b.score - a.score
                return root.alphabeticalCompare(a, b)
            })
            return pool.slice(0, 8)
        }
        var exact = [], prefix = [], sub = []
        for (var j=0;j<list.length;j++){
            var b = list[j]
            var n = b.name.toLowerCase(), e = b.exec.toLowerCase()
            if (n === f || e === f) exact.push(b)
            else if (n.indexOf(f) === 0) prefix.push(b)
            else if (n.indexOf(f) !== -1 || e.indexOf(f) !== -1) sub.push(b)
        }
        exact.sort(root.alphabeticalCompare)
        prefix.sort(root.alphabeticalCompare)
        sub.sort(root.alphabeticalCompare)
        return exact.concat(prefix, sub).slice(0, 6)
    }
    function getAppsForWs(ws) {
        var out=[]
        for(var i=0;i<assignments.length;i++) if(assignments[i].workspace===ws) out.push(assignments[i])
        return out
    }
    property var addedApps: {
        var out=[]
        for(var i=0;i<assignments.length;i++) if(assignments[i].workspace===formWorkspace) out.push(assignments[i])
        return out
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        centerOnBar: true
        focusTarget: keyCatcher
        padding: Style.space(24)
        contentWidth: panel.fittedContentWidth(Style.space(900))
        contentHeight: panel.fittedContentHeight(content.implicitHeight + Style.space(40), panel.screenH - Style.gapsOut*2 - Style.space(16))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: filterField.activeFocus
            onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
            onActivateRequested: root.activateCursor()
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.moveTabCursor(direction) }
            onTextKey: function(t) {
                if (t === "/") {
                    cursorActive = false
                    filterField.forceActiveFocus()
                    filterField.selectAll()
                }
            }

            ColumnLayout {
                id: content
                anchors.fill: parent
                spacing: Style.space(14)

                // ——— Header ———
                PanelHero {
                    Layout.fillWidth: true
                    title: "Auto Workspace"
                    meta: root.totalCount + " assignments · " + root.enabledCount + " enabled"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    iconComponent: Component {
                        Text {
                            text: "󰨧"
                            color: Color.accent
                            font.family: Style.font.family
                            font.pixelSize: Style.font.display
                        }
                    }
                }

                Text {
                    text: "↑↓ navigate · Enter toggles · / searches · Esc closes"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                // ——— Body: 2 columns — pick+search | preview ———
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(Style.space(440), Math.round(panel.screenH * 0.5))
                    Layout.maximumHeight: Layout.preferredHeight
                    Layout.minimumHeight: Layout.preferredHeight
                    spacing: Style.space(14)

                    // ——— Col 1: workspace picker + app search ———
                    ColumnLayout {
                        id: leftStack
                        Layout.fillWidth: false
                        Layout.preferredWidth: Math.round(content.width * 0.30)
                        Layout.minimumWidth: Style.space(240)
                        Layout.alignment: Qt.AlignTop
                        spacing: Style.space(10)

                        PanelSectionHeader {
                            text: "PICK A WORKSPACE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        // Workspace picker 1-10 (5 per row)
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 5
                            columnSpacing: Style.space(4)
                            rowSpacing: Style.space(4)
                            Repeater {
                                model: 10
                                delegate: Button {
                                    required property int index
                                    text: String(index+1)
                                    selected: root.workspacePicked && root.formWorkspace===(index+1)
                                    horizontalPadding: 0
                                    verticalPadding: 0
                                    onClicked: { root.workspacePicked = true; root.formWorkspace=index+1; root.persistFormWorkspace() }
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: Style.space(38)
                                }
                            }
                        }

                        PanelSeparator {
                            Layout.fillWidth: true
                            foreground: root.foreground
                        }

                        PanelSectionHeader {
                            text: "SEARCH APPS"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        // App picker
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(8)
                            TextField {
                                id: filterField
                                Layout.fillWidth: true
                                verticalPadding: Style.space(9)
                                placeholderText: "Search installed apps..."
                                foreground: root.foreground
                                accent: Color.accent
                                font.family: root.fontFamily
                                text: root.appFilter
                                onTextChanged: { root.appFilter = text; root.cursorActive = false }
                                Keys.onPressed: function(event) {
                                    if (event.key === Qt.Key_Escape) {
                                        root.close()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                                        var direction = (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1
                                        if (direction < 0 && !root.cursorActive) {
                                            var rows = root.filteredApps
                                            if (rows.length > 0) {
                                                root.setCursor(rows.length - 1, 0)
                                                keyCatcher.forceActiveFocus()
                                            }
                                        } else {
                                            root.moveTabCursor(direction)
                                            if (root.cursorActive) keyCatcher.forceActiveFocus()
                                        }
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Down) {
                                        root.setCursor(0, 0)
                                        keyCatcher.forceActiveFocus()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Up) {
                                        var rows = root.filteredApps
                                        if (rows.length > 0) {
                                            root.setCursor(rows.length - 1, 0)
                                            keyCatcher.forceActiveFocus()
                                            event.accepted = true
                                        }
                                    }
                                }
                            }
                            Button { text: "⟳"; tooltipText: "Refresh app list"; verticalPadding: Style.space(9); onClicked: appsProc.running=true }
                        }

                        Text {
                            visible: root.filteredApps.length===0 && root.appFilter.trim().length>0
                            Layout.fillWidth: true
                            text: "No matches"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            visible: root.filteredApps.length===0 && root.appFilter.trim().length===0
                            Layout.fillWidth: true
                            text: "No apps assigned yet — type to search and add"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        // Results — scrollable (plugin-manager pattern)
                        ScrollView {
                            id: resultsScroll
                            visible: root.filteredApps.length>0
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            ScrollBar.vertical.policy: ScrollBar.AsNeeded

                            Column {
                                width: resultsScroll.width
                                spacing: Style.space(6)

                                Repeater {
                                    model: root.filteredApps
                                    delegate: AppRow {
                                        app: modelData
                                        rowIndex: index
                                        width: parent.width
                                    }
                                }
                            }
                        }
                    }

                    // ——— Col 2: preview ———
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: Math.round(content.width * 0.70)
                        Layout.alignment: Qt.AlignTop
                        spacing: Style.space(10)

                        PanelSectionHeader {
                            text: "PREVIEW"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        WorkspacePreview {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: Math.min(Style.space(200), Math.round(panel.screenH * 0.3))
                            workspace: root.formWorkspace
                            assignedApps: root.addedApps
                            screenW: panel.screenW
                            screenH: panel.screenH
                        }
                    }
                }

                // ——— Footer: status ———
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(12)

                    Text {
                        visible: root.statusText!==""
                        text: "✓ " + root.statusText
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    Text {
                        visible: root.errorText!==""
                        text: root.errorText
                        color: Color.urgent || "#ff4444"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }
            }
        }
    }

    component AppRow: CursorSurface {
        property var app: null
        property int rowIndex: 0
        readonly property bool rowSelected: root.cursorActive && root.selectedRow === rowIndex
        hasCursor: rowSelected
        foreground: root.foreground
        implicitHeight: Style.space(44)

        onRowSelectedChanged: if (rowSelected) root.ensureCursorVisible(this)

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Text {
                text: "󰐱"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.preferredWidth: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Text {
                    text: app ? app.name : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    text: app ? (app.exec.indexOf("omarchy-launch-webapp") !== -1 ? "web app" : app.exec.split(" ")[0].split("/").pop()) : ""
                    color: root.dim
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption - 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            ToggleSwitch {
                Layout.alignment: Qt.AlignVCenter
                checked: app ? root.isInList(root.addedApps, app.exec) : false
                cursorRing: true
                cursorPad: Style.space(3)
                foreground: root.foreground
                accent: Color.accent
                hasCursor: rowSelected && root.selectedButton === 0
                onHovered: function(on) {
                    if (on) root.setCursor(rowIndex, 0)
                }
                onToggled: if (app) root.toggleInWorkspace(app.exec, app.name)
            }
        }
    }

    Component.onCompleted: { loadConfig(); appsProc.running = true }
}