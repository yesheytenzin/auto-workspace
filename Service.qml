pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root

    // Injected by shell — keep for compatibility (even if not used by service)
    property QtObject bar: null
    property string moduleName: "yesheytenzin.auto-workspace"
    property var settings: ({})
    property var shell: null
    property var manifest: null

    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || home + "/.config"
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
    readonly property string pluginId: "yesheytenzin.auto-workspace"
    readonly property string script: home + "/.config/omarchy/plugins/" + pluginId + "/auto-workspace.sh"
    readonly property string configFile: configHome + "/omarchy/plugins/" + pluginId + "/config.json"

    property bool autoEnabled: true
    property int launchDelayMs: 800
    property bool launchedThisSession: false
    property string lastStatus: ""

    function log(msg) {
        console.log("[auto-workspace] " + msg)
    }

    // ---- processes ----
    Process {
        id: ensureProc
        command: ["bash", root.script, "--ensure-config"]
        stdout: StdioCollector { id: ensureOut; waitForEnd: true }
        onExited: function(code) {
            if (code !== 0) {
                root.log("ensure-config failed: " + code)
                return
            }
            var txt = ensureOut.text || ""
            try {
                var cfg = JSON.parse(txt)
                if (cfg.settings) {
                    root.autoEnabled = cfg.settings.enabled !== false
                    root.launchDelayMs = Number(cfg.settings.launchDelayMs || 800)
                }
            } catch(e) { root.log("parse ensure-config: " + e) }
            // schedule autostart after delay
            if (root.autoEnabled && !root.launchedThisSession) {
                launchTimer.interval = root.launchDelayMs
                launchTimer.restart()
            }
        }
    }

    Process {
        id: launchProc
        stdout: SplitParser { onRead: function(d){ console.log("[auto-workspace launch] " + d) } }
        stderr: SplitParser { onRead: function(d){ console.warn("[auto-workspace launch err] " + d) } }
        onExited: function(code) {
            root.lastStatus = code === 0 ? "launched" : "failed:" + code
            root.launchedThisSession = true
            root.log("launch-all exited " + code)
        }
    }

    Process {
        id: statusProc
        stdout: StdioCollector { id: statusOut; waitForEnd: true }
        onExited: function(code) {
            if (code === 0) root.lastStatus = statusOut.text
        }
    }

    Process {
        id: manualLaunchProc
        stdout: SplitParser { onRead: function(d){ console.log("[auto-workspace manual] " + d) } }
        stderr: SplitParser { onRead: function(d){ console.warn("[auto-workspace manual err] " + d) } }
    }

    Timer {
        id: launchTimer
        interval: 800
        repeat: false
        onTriggered: {
            if (!root.autoEnabled) {
                root.log("autostart disabled, skipping")
                return
            }
            if (root.launchedThisSession) {
                root.log("already launched this session, skipping (use force)")
                return
            }
            root.log("auto-launching assignments...")
            launchProc.command = ["bash", root.script, "--launch-all"]
            launchProc.running = true
        }
    }

    // public API for Panel / IPC
    function launchAll(force) {
        var args = force ? ["bash", root.script, "--launch-all", "true"] : ["bash", root.script, "--launch-all"]
        // force needs different path: script expects --launch-all true for force, but we have helper
        if (force) {
            launchProc.command = ["bash", root.script, "--force-launch-all"]
        } else {
            launchProc.command = ["bash", root.script, "--launch-all"]
        }
        launchProc.running = true
    }

    function launchOnWorkspace(workspace, execCmd) {
        var silent = "true"
        // read silent from config quickly via status? assume true
        manualLaunchProc.command = ["bash", root.script, "--launch", String(workspace), execCmd, silent]
        manualLaunchProc.running = true
    }

    function refreshConfig() {
        ensureProc.running = true
    }

    function status(): string {
        // synchronous-ish via cached lastStatus + immediate proc trigger for next call
        if (!statusProc.running) statusProc.command = ["bash", root.script, "--status"]
        if (!statusProc.running) statusProc.running = true
        try {
            var cached = statusProc.running ? root.lastStatus : root.lastStatus
            if (cached && cached.indexOf("{") === 0) return cached
        } catch(e) {}
        return JSON.stringify({ plugin: pluginId, enabled: autoEnabled, launched: launchedThisSession, lastStatus: lastStatus })
    }

    IpcHandler {
        target: root.pluginId
        function launchAll(): void { root.launchAll(false) }
        function forceLaunchAll(): void { root.launchAll(true) }
        function launch(workspace: string, execCmd: string): void { root.launchOnWorkspace(workspace, execCmd) }
        function refreshConfig(): void { root.refreshConfig() }
        function status(): string { return root.status() }
    }

    Component.onCompleted: {
        root.log("service started, ensuring config " + root.configFile)
        ensureProc.running = true
    }
}
