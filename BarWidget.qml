import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "tenzin.auto-workspace"

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property string pluginId: "tenzin.auto-workspace"
    readonly property string home: Quickshell.env("HOME")
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
    // Outside the plugin dir: the shell reloads the plugin on any file change there
    readonly property string configFile: stateHome + "/omarchy/auto-workspace/config.json"
    readonly property string script: home + "/.config/omarchy/plugins/" + pluginId + "/auto-workspace.sh"

    property int totalCount: 0
    property int enabledCount: 0
    property bool pluginEnabled: true
    property string lastError: ""

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

    function open() { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
    function togglePanel() { toggle() }
    function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

    function injectPanel() {
        if (!panelLoader.item) return
        panelLoader.item.bar = root.bar
        panelLoader.item.anchorItem = button
        panelLoader.item.hostWidget = root
    }

    function refreshCounts() {
        if (!statusProc.running) statusProc.running = true
    }

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Process {
        id: statusProc
        command: ["/usr/bin/bash", "-c", "if [[ -L \"$1\" ]]; then echo '{\"total\":0,\"enabled\":0,\"pluginEnabled\":true}' >&2; exit 1; fi; sz=$(/usr/bin/stat -c%s \"$1\" 2>/dev/null || echo 0); if [[ \"$sz\" -gt 1048576 ]]; then echo '{\"total\":0,\"enabled\":0,\"pluginEnabled\":true}'; exit 0; fi; cat \"$1\" 2>/dev/null | /usr/bin/head -c 1048576 | /usr/bin/jq -c '{total: (.assignments|length), enabled: ([.assignments[]|select(.enabled==true)]|length), pluginEnabled: (.settings.enabled // true)}' 2>/dev/null || echo '{\"total\":0,\"enabled\":0,\"pluginEnabled\":true}'", "_", root.configFile]
        property string out: ""
        // bound output accumulation to 32k
        property int outBytes: 0
        stdout: SplitParser { onRead: function(d){ if (statusProc.outBytes < 32768) { statusProc.out += d; statusProc.outBytes += d.length; if (statusProc.outBytes > 32768) statusProc.out = statusProc.out.slice(0, 32768) } } }
        onRunningChanged: if (running) statusWatchdog.restart(); else statusWatchdog.stop()
        onExited: function(code){
            statusWatchdog.stop()
            try {
                var j = JSON.parse(statusProc.out.trim() || "{}")
                root.totalCount = Math.min(100, Number(j.total || 0))
                root.enabledCount = Math.min(100, Number(j.enabled || 0))
                root.pluginEnabled = j.pluginEnabled !== false
            } catch(e) {}
            statusProc.out = ""
            statusProc.outBytes = 0
        }
    }

    Timer { id: statusWatchdog; interval: 8000; repeat: false; onTriggered: if (statusProc.running) statusProc.running = false }

    Process {
        id: watcherProc
        // simple poll; inotify would be heavier
    }

    Timer {
        id: pollTimer
        interval: 2500
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshCounts()
    }

    // wiring to allow Panel to notify bar of changes
    Connections {
        target: panelLoader.item
        ignoreUnknownSignals: true
        function onCountsChanged() { root.refreshCounts() }
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        // workspace dashboard — clearer at small bar size than 4-squares-plus
        text: "󱂬"
        // fall back if font missing: ◧
        slotSize: Style.bar.statusSlot
        tooltipText: root.pluginEnabled
            ? ("Auto Workspace • " + root.enabledCount + "/" + root.totalCount + " enabled • click to manage")
            : "Auto Workspace • disabled • click to enable"
        onPressed: function(btn){
            if (btn === Qt.LeftButton) root.toggle()
        }
    }

    Component.onCompleted: refreshCounts()
}
