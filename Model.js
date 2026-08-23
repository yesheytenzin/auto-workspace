.pragma library

// Shared helpers for Auto Workspace panel + service
// File paths are resolved in QML via Quickshell.env

function defaultConfig() {
    return {
        version: 1,
        settings: {
            enabled: true,
            launchDelayMs: 800,
            staggerMs: 400,
            silent: true,
            onlyOnBoot: true,
            lastFormWorkspace: 1
        },
        assignments: []
    }
}

function clone(o) { return JSON.parse(JSON.stringify(o)) }

function makeId() {
    return "aw-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2,6)
}

function defaultOnlyOnBootForType(type) {
    return true
}

function normalizeAssignment(a) {
    var ws = parseInt(a.workspace, 10)
    if (!(ws >= 1 && ws <= 10) && String(a.workspace).indexOf("special:") !== 0) ws = 1
    var type = (a.type === "webapp" || a.type === "app" || a.type === "custom") ? a.type : "app"
    var onlyOnBoot = true
    return {
        id: String(a.id || makeId()),
        workspace: ws,
        name: String(a.name || a.command || "App").slice(0, 80),
        command: String(a.command || a.exec || "").slice(0, 500),
        exec: String(a.exec || a.command || "").slice(0, 500),
        type: type,
        enabled: a.enabled !== false,
        onlyOnBoot: onlyOnBoot
    }
}

function sanitizeConfig(cfg) {
    if (!cfg || typeof cfg !== "object") return defaultConfig()
    var out = clone(defaultConfig())
    if (cfg.settings && typeof cfg.settings === "object") {
        out.settings.enabled = cfg.settings.enabled !== false
        out.settings.launchDelayMs = Math.max(0, Math.min(10000, parseInt(cfg.settings.launchDelayMs) || 800))
        out.settings.staggerMs = Math.max(0, Math.min(2000, parseInt(cfg.settings.staggerMs) || 400))
        out.settings.silent = cfg.settings.silent !== false
        out.settings.onlyOnBoot = cfg.settings.onlyOnBoot !== false
        out.settings.lastFormWorkspace = Math.max(1, Math.min(10, parseInt(cfg.settings.lastFormWorkspace) || 1))
    }
    if (Array.isArray(cfg.assignments)) {
        // Backfill: existing assignments without onlyOnBoot inherit global or type default
        var globalOnly = out.settings.onlyOnBoot
        out.assignments = cfg.assignments.slice(0, 50).map(function(raw){
            // If raw already has onlyOnBoot, normalize will keep it; else use type default
            // but if no per-item value and global was false, keep type default logic inside normalize
            // For migration: if raw lacks onlyOnBoot and global was false, app types would get false anyway
            // so we just call normalize which applies type defaults. To respect old global for migration,
            // we inject global as fallback for items lacking explicit value:
            var copy = clone(raw)
            if (copy.onlyOnBoot === undefined || copy.onlyOnBoot === null) {
                // Old config: use type default, not global, for best new behavior
                // (global remains fallback for script's clients check)
            }
            return normalizeAssignment(copy)
        })
    }
    out.version = 1
    return out
}

function execForAssignment(a) {
    // Prefer explicit exec, else derive
    if (a.exec && String(a.exec).trim().length) return String(a.exec).trim()
    if (a.command && String(a.command).trim().length) {
        var cmd = String(a.command).trim()
        if (a.type === "webapp") {
            // if command is a URL, wrap with omarchy-launch-webapp
            if (cmd.indexOf("http://") === 0 || cmd.indexOf("https://") === 0) {
                return "omarchy-launch-webapp '" + cmd.replace(/'/g, "'\\''") + "'"
            }
            return cmd
        }
        return cmd
    }
    return ""
}

function displayNameForExec(execStr, fallback) {
    var s = String(execStr || "").trim()
    if (!s) return fallback || "App"
    // unwrap webapp
    var m = s.match(/omarchy-launch-webapp\s+'([^']+)'/)
    if (m) {
        try {
            var u = new URL(m[1])
            return u.hostname.replace(/^www\./, "") + u.pathname.split("/").slice(0,2).join("/")
        } catch(e) { return m[1].slice(0, 40) }
    }
    // take basename of first token
    var first = s.split(/\s+/)[0]
    var base = first.split("/").pop()
    return base || fallback || "App"
}
