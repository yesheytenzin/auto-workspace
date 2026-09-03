pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root

    // Injected by shell — keep for compatibility (even if not used by service)
    property QtObject bar: null
    property string moduleName: "tenzin.auto-workspace"
    property var settings: ({})
    property var shell: null
    property var manifest: null

    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || home + "/.config"
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
    readonly property string pluginId: "tenzin.auto-workspace"
    readonly property string script: home + "/.config/omarchy/plugins/" + pluginId + "/auto-workspace.sh"
    // Outside the plugin dir: the shell reloads the plugin on any file change there
    readonly property string configFile: stateHome + "/omarchy/auto-workspace/config.json"

    property bool autoEnabled: true
    property int launchDelayMs: 1500
    property bool launchedThisSession: false
    property bool launchScheduled: false
    property string lastStatus: ""

    function log(msg) {
        console.log("[auto-workspace] " + msg)
    }

    // ---- processes ----
    Process {
        id: ensureProc
        command: ["/usr/bin/bash", root.script, "--ensure-config"]
        stdout: StdioCollector { id: ensureOut; waitForEnd: true }
        onRunningChanged: if (running) ensureWatchdog.restart(); else ensureWatchdog.stop()
        onExited: function(code) {
            ensureWatchdog.stop()
            if (code !== 0) {
                root.log("ensure-config failed: " + code)
                return
            }
            var txt = ensureOut.text || ""
            if (txt.length > 1048576) { root.log("ensure-config output too large (" + txt.length + "), truncating"); txt = txt.slice(0, 1048576) }
            try {
                var cfg = JSON.parse(txt)
                if (cfg.settings) {
                    root.autoEnabled = cfg.settings.enabled !== false
                    root.launchDelayMs = Number(cfg.settings.launchDelayMs || 1500)
                }
            } catch(e) { root.log("parse ensure-config: " + e) }
            // schedule autostart once per service lifetime — later
            // refreshConfig calls (panel saves) must never re-launch apps
            if (!root.launchScheduled) {
                root.launchScheduled = true
                if (root.autoEnabled) {
                    launchTimer.interval = root.launchDelayMs
                    launchTimer.restart()
                }
            }
        }
    }

    Process {
        id: launchProc
        stdout: SplitParser { onRead: function(d){ console.log("[auto-workspace launch] " + d) } }
        stderr: SplitParser { onRead: function(d){ console.warn("[auto-workspace launch err] " + d) } }
        onRunningChanged: if (running) launchWatchdog.restart(); else launchWatchdog.stop()
        onExited: function(code) {
            launchWatchdog.stop()
            root.lastStatus = code === 0 ? "launched" : "failed:" + code
            root.launchedThisSession = true
            root.log("launch-all exited " + code)
        }
    }

    Process {
        id: statusProc
        stdout: StdioCollector { id: statusOut; waitForEnd: true }
        onRunningChanged: if (running) statusWatchdog.restart(); else statusWatchdog.stop()
        onExited: function(code) {
            statusWatchdog.stop()
            var txt = statusOut.text || ""
            if (txt.length > 1048576) txt = txt.slice(0, 1048576)
            if (code === 0) root.lastStatus = txt
        }
    }

    Process {
        id: manualLaunchProc
        stdout: SplitParser { onRead: function(d){ console.log("[auto-workspace manual] " + d) } }
        stderr: SplitParser { onRead: function(d){ console.warn("[auto-workspace manual err] " + d) } }
        onRunningChanged: if (running) manualWatchdog.restart(); else manualWatchdog.stop()
        onExited: function(code) { manualWatchdog.stop() }
    }

    // ---- watchdogs: hard wall-clock deadlines ----
    Timer { id: ensureWatchdog; interval: 15000; repeat: false; onTriggered: { if (ensureProc.running) { root.log("ensure-config timeout, terminating"); ensureProc.running = false } } }
    Timer { id: launchWatchdog; interval: 120000; repeat: false; onTriggered: { if (launchProc.running) { root.log("launch-all timeout, terminating"); launchProc.running = false } } }
    Timer { id: statusWatchdog; interval: 10000; repeat: false; onTriggered: { if (statusProc.running) { root.log("status timeout, terminating"); statusProc.running = false } } }
    Timer { id: manualWatchdog; interval: 30000; repeat: false; onTriggered: { if (manualLaunchProc.running) { root.log("manual launch timeout, terminating"); manualLaunchProc.running = false } } }

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
            launchProc.command = ["/usr/bin/bash", root.script, "--launch-all"]
            launchProc.running = true
        }
    }

    // public API for Panel / IPC
    function launchAll(force) {
        // force needs different path: script expects --force-launch-all
        if (force) {
            launchProc.command = ["/usr/bin/bash", root.script, "--force-launch-all"]
        } else {
            launchProc.command = ["/usr/bin/bash", root.script, "--launch-all"]
        }
        launchProc.running = true
    }

    function launchOnWorkspace(workspace, execCmd) {
        var ws = String(workspace)
        if (!(ws.match(/^[0-9]+$/) || ws.indexOf("special:") === 0)) {
            root.log("launchOnWorkspace: invalid workspace " + ws)
            return
        }
        var cmd = String(execCmd || "").slice(0, 500)
        if (!cmd.length) { root.log("launchOnWorkspace: empty exec"); return }
        var silent = "true"
        manualLaunchProc.command = ["/usr/bin/bash", root.script, "--launch", ws, cmd, silent]
        manualLaunchProc.running = true
    }

    function refreshConfig() {
        if (!ensureProc.running) ensureProc.running = true
    }

    function status(): string {
        // synchronous-ish via cached lastStatus + immediate proc trigger for next call
        if (!statusProc.running) statusProc.command = ["/usr/bin/bash", root.script, "--status"]
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
