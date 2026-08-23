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
    return type === "app" ? false : true
}

function normalizeAssignment(a) {
    var ws = parseInt(a.workspace, 10)
    if (!(ws >= 1 && ws <= 10) && String(a.workspace).indexOf("special:") !== 0) ws = 1
    var type = (a.type === "webapp" || a.type === "app" || a.type === "custom") ? a.type : "app"
    var onlyOnBoot = defaultOnlyOnBootForType(type)
    if (typeof a.onlyOnBoot === "boolean") {
        onlyOnBoot = a.onlyOnBoot
    } else if (a.onlyOnBoot === 1 || a.onlyOnBoot === "1" || a.onlyOnBoot === "true") {
        onlyOnBoot = true
    } else if (a.onlyOnBoot === 0 || a.onlyOnBoot === "0" || a.onlyOnBoot === "false") {
        onlyOnBoot = false
    }
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
        out.assignments = cfg.assignments.slice(0, 50).map(function(raw){
            return normalizeAssignment(clone(raw))
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
