import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "yesheytenzin.auto-workspace"

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property string pluginId: "yesheytenzin.auto-workspace"
    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || home + "/.config"
    readonly property string configFile: configHome + "/omarchy/plugins/" + pluginId + "/config.json"
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
        command: ["bash", "-c", "cat \"$1\" 2>/dev/null | jq -c '{total: (.assignments|length), enabled: ([.assignments[]|select(.enabled==true)]|length), pluginEnabled: (.settings.enabled // true)}' 2>/dev/null || echo '{\"total\":0,\"enabled\":0,\"pluginEnabled\":true}'", "_", root.configFile]
        property string out: ""
        stdout: SplitParser { onRead: function(d){ statusProc.out += d } }
        onExited: function(code){
            try {
                var j = JSON.parse(statusProc.out.trim() || "{}")
                root.totalCount = Number(j.total || 0)
                root.enabledCount = Number(j.enabled || 0)
                root.pluginEnabled = j.pluginEnabled !== false
            } catch(e) {}
            statusProc.out = ""
        }
    }

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
        // distinctive workspace icon; use 4 squares
        text: "󰨧"
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
