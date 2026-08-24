import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Mock preview of a workspace's tiling. Geometry mirrors the real Hyprland
// configuration fed from Panel.qml via hyprctl getoption / hyprctl monitors:
//   - dwindle simulated as a binary-split tree (split along each leaf's longer
//     axis, newest leaf first) instead of hardcoded patterns
//   - master uses the real master:mfact
//   - scrolling renders the newest (focused) column centered at the real
//     scrolling:column_width with neighbor columns peeking on both edges
//   - the box aspect is the TRUE tileable area (monitor minus bar minus
//     gaps_out) and all gaps/borders/radii are scaled from real values
Item {
    id: root
    property int workspace: 1
    property var assignedApps: [] // assignments filtered for this WS
    property var appList: [] // installed apps with iconPath, for icon lookup
    property bool isExpanded: false
    property int screenW: 0
    property int screenH: 0
    property var bar: null
    // Actual Hyprland layout — fed from Panel via hyprctl getoption. Preview branches per layout.
    property string hyprLayout: "dwindle"
    property real columnWidth: 0.49 // scrolling:column_width
    // Real Hyprland general/decoration/master options (effective values)
    property int hyprGapsIn: 5
    property int hyprGapsOut: 10
    property int hyprBorder: 2
    property int hyprRounding: 0
    property real hyprMfact: 0.55
    // Focused monitor logical size (falls back to panel screen)
    property real hyprScale: 1.0
    property int monW: 0
    property int monH: 0
    // Reserved bar edge of the monitor the panel lives on
    property string barPos: "top"
    property real barSizeH: 0 // bar thickness if horizontal bar (KeyboardPanel.barH)
    property real barSizeW: 0 // bar thickness if vertical bar (KeyboardPanel.barW)
    // Windows actually tiled on this workspace right now (hyprctl clients -j)
    property var liveWindows: []

    readonly property bool barHorizontal: root.barPos === "top" || root.barPos === "bottom"
    readonly property real effMonW: root.monW > 0 ? root.monW : root.screenW
    readonly property real effMonH: root.monH > 0 ? root.monH : root.screenH
    // True tileable area: monitor minus reserved bar edge minus outer gaps
    readonly property real tileableW: Math.max(1, root.effMonW - (root.barHorizontal ? 0 : root.barSizeW) - 2 * root.hyprGapsOut)
    readonly property real tileableH: Math.max(1, root.effMonH - (root.barHorizontal ? root.barSizeH : 0) - 2 * root.hyprGapsOut)
    readonly property real screenAspect: root.tileableW > 1 ? root.tileableH / root.tileableW : 0.5625
    readonly property var appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
    readonly property string layoutLabel: {
        if (hyprLayout === "scrolling") return "scrolling • " + Math.round(columnWidth * 100) + "% columns"
        if (hyprLayout === "master") return "master"
        if (hyprLayout === "dwindle") return "dwindle"
        return hyprLayout
    }

    // px → preview-unit scale and derived metrics (clamped so the mini view
    // never collapses or explodes at extreme sizes)
    readonly property real pxScale: tilesContainer.width > 0 && root.tileableW > 1 ? tilesContainer.width / root.tileableW : 0
    readonly property int gapIn: Math.max(1, Math.min(8, Math.round(root.hyprGapsIn * pxScale)))
    readonly property int gapOut: Math.max(2, Math.min(16, Math.round(root.hyprGapsOut * pxScale)))
    readonly property int tileRadius: Math.max(0, Math.min(6, Math.round(root.hyprRounding * pxScale)))

    function iconPathFor(exec) {
        for (var i = 0; i < appList.length; i++)
            if (appList[i].exec === exec || appList[i].command === exec) return appList[i].iconPath || ""
        return ""
    }
    function iconSourceFor(exec) {
        // Local iconPath from list-apps, otherwise reuse the shell's AppLibrary
        // (same lookup the Omarchy menu uses: themed plus fallback icon).
        for (var i = 0; i < appList.length; i++) {
            if (appList[i].exec === exec || appList[i].command === exec) {
                var a = appList[i]
                if (a.iconPath && a.iconPath !== "") return "file://" + a.iconPath
                var icon = String(a.icon || "")
                if (root.appLibrary && typeof root.appLibrary.iconSource === "function") return root.appLibrary.iconSource(icon)
                if (icon !== "" && icon.charAt(0) === "/") return "file://" + icon
                var themed = ""
                try { themed = Quickshell.iconPath(icon, true) } catch(e) { themed = "" }
                if (themed && themed.length > 0) return themed
                try { return Quickshell.iconPath("application-x-executable", true) } catch(e) { return "" }
            }
        }
        // Exec not in appList (e.g. custom command): try icon by basename, else generic
        var base = String(exec || "").split(" ")[0].split("/").pop()
        if (root.appLibrary && typeof root.appLibrary.iconSource === "function") return root.appLibrary.iconSource(base)
        var fb = ""
        try { fb = Quickshell.iconPath(base, true) } catch(e) { fb = "" }
        if (fb && fb.length > 0 && fb.indexOf("image://icon/application-x-executable") === -1) return fb
        try { return Quickshell.iconPath("application-x-executable", true) } catch(e) { return "" }
    }

    // --- tiling math -------------------------------------------------------
    // Mirrors Hyprland dwindle: each new window is inserted into the leaf
    // created by the previous insertion and splits it along its longer axis.
    // (Order approximates the plugin's staggered launch order.)
    function dwindleLeaves(total, W, H) {
        var leaves = [{x:0, y:0, w:W, h:H}]
        for (var i = 1; i < total; i++) {
            var li = leaves.length - 1
            var L = leaves[li]
            var a, b
            if (L.w > L.h) {
                var hx = Math.round(L.w / 2)
                a = {x:L.x, y:L.y, w:hx, h:L.h}
                b = {x:L.x + hx, y:L.y, w:L.w - hx, h:L.h}
            } else {
                var hy = Math.round(L.h / 2)
                a = {x:L.x, y:L.y, w:L.w, h:hy}
                b = {x:L.x, y:L.y + hy, w:L.w, h:L.h - hy}
            }
            leaves.splice(li, 1, a, b)
        }
        return leaves
    }
    // Master: left master pane at real master:mfact, remaining apps stacked
    // vertically in the right pane (Hyprland default orientation).
    function masterLeaves(total, W, H) {
        if (total === 1) return [{x:0, y:0, w:W, h:H}]
        var mf = Math.min(0.9, Math.max(0.1, root.hyprMfact))
        var mw = Math.round(W * mf)
        var out = [{x:0, y:0, w:mw, h:H}]
        var sn = total - 1
        var sh = Math.floor(H / sn)
        for (var i = 0; i < sn; i++)
            out.push({x:mw, y:i * sh, w:W - mw, h:(i === sn - 1) ? H - i * sh : sh})
        return out
    }
    // Final rects for the tiled (non-scrolling) branches: leaves separated by
    // the scaled inner gap + window borders (hyprctl bboxes include the
    // border), each carrying its app for the delegate.
    readonly property int borderPx: Math.max(1, Math.min(4, Math.round(root.hyprBorder * pxScale)))
    readonly property var tiledRects: {
        var n = root.assignedApps ? root.assignedApps.length : 0
        if (n === 0 || root.hyprLayout === "scrolling") return []
        var W = tilesContainer.width, H = tilesContainer.height
        if (!(W > 0) || !(H > 0)) return []
        var leaves = root.hyprLayout === "master" ? root.masterLeaves(n, W, H) : root.dwindleLeaves(n, W, H)
        var inset = Math.ceil(root.gapIn / 2) + root.borderPx
        var out = []
        for (var i = 0; i < leaves.length; i++) {
            var r = leaves[i]
            out.push({x: r.x + inset, y: r.y + inset, w: Math.max(10, r.w - 2 * inset), h: Math.max(10, r.h - 2 * inset), app: root.assignedApps[i]})
        }
        return out
    }

    implicitWidth: 320
    implicitHeight: previewBox.implicitHeight + 28

    ColumnLayout {
        anchors.fill: parent
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Text {
                text: "WS " + root.workspace
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
            }
            Text {
                text: root.assignedApps.length + " app" + (root.assignedApps.length === 1 ? "" : "s")
                color: Qt.darker(Color.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
            }
            Text {
                visible: root.assignedApps.length > 0
                text: "· " + root.layoutLabel
                color: Qt.darker(Color.foreground, 1.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 2
                elide: Text.ElideRight
            }
            Item { Layout.fillWidth: true }
        }

        // Spacers center the mini screen vertically in whatever room the
        // column gives it, instead of stretching the aspect ratio.
        Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }

        // Preview box — aspect matches the REAL tileable area (monitor minus
        // bar minus gaps_out), so proportions match what Hyprland renders.
        Rectangle {
            id: previewBox
            Layout.fillWidth: true
            Layout.preferredHeight: width > 0 ? Math.round(width * root.screenAspect) : 92
            Layout.maximumHeight: Layout.preferredHeight
            Layout.alignment: Qt.AlignHCenter
            implicitHeight: width > 0 ? Math.round(width * root.screenAspect) : 92
            radius: Style.cornerRadius
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
            border.width: 1
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
            clip: true

            // Empty state
            Text {
                visible: root.assignedApps.length === 0
                anchors.centerIn: parent
                text: "Empty — use + Add to assign apps"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                horizontalAlignment: Text.AlignHCenter
            }

            // Live indicator — real windows currently on this workspace
            Text {
                visible: root.liveWindows.length > 0
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 4
                anchors.rightMargin: 6
                text: "● live " + root.liveWindows.length
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 2
                font.bold: true
            }

            Item {
                id: tilesContainer
                anchors.fill: parent
                // Outer gaps scaled from the real general:gaps_out
                anchors.margins: Math.max(4, root.gapOut)
                visible: root.assignedApps.length > 0
                property int count: root.assignedApps.length

                // Scrolling: newest (focused) column centered at the real
                // column_width; older columns trail left and peek past the
                // edges exactly like niri-style scrolling.
                Item {
                    id: scrollingStrip
                    visible: root.hyprLayout === "scrolling" && tilesContainer.count > 0
                    anchors.fill: parent
                    clip: true
                    property real colW: Math.max(28, tilesContainer.width * root.columnWidth)
                    property real gap: Math.max(2, root.gapIn)
                    property real centerX: (tilesContainer.width - colW) / 2
                    function colX(i) { return centerX + (i - (tilesContainer.count - 1)) * (colW + gap) }
                    function fullyVisible(i) {
                        var x = colX(i)
                        return x >= -1 && x + colW <= tilesContainer.width + 1
                    }
                    Repeater {
                        model: root.hyprLayout === "scrolling" ? root.assignedApps : []
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            x: scrollingStrip.colX(index)
                            y: 0
                            width: scrollingStrip.colW
                            height: scrollingStrip.height
                            radius: Math.max(2, root.tileRadius)
                            color: modelData.enabled ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                            border.width: 1
                            border.color: modelData.enabled ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
                            // dim columns peeking past the edges → hints scroll
                            opacity: scrollingStrip.fullyVisible(index) ? 1.0 : 0.55
                            clip: true
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 4
                                spacing: 1
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: 2
                                        Image {
                                            Layout.alignment: Qt.AlignHCenter
                                            Layout.preferredWidth: 16
                                            Layout.preferredHeight: 16
                                            visible: source !== ""
                                            source: root.iconSourceFor(modelData.exec || modelData.command)
                                            fillMode: Image.PreserveAspectFit
                                            asynchronous: true
                                            cache: true
                                            onStatusChanged: if (status === Image.Error) source = ""
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.name || "App"
                                            color: modelData.enabled ? Color.foreground : Qt.darker(Color.foreground, 1.3)
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.caption - 1
                                            font.bold: true
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                            horizontalAlignment: Text.AlignHCenter
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // scroll hint arrow when the newest column runs off the right edge
                    Text {
                        visible: tilesContainer.count > 0 && scrollingStrip.colX(tilesContainer.count - 1) + scrollingStrip.colW > tilesContainer.width + 1
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.rightMargin: 2
                        text: "›"
                        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)
                        font.pixelSize: 14
                        font.bold: true
                    }
                }

                // Tiled layouts (dwindle / master / unknown) — real split-tree rects
                Repeater {
                    model: root.tiledRects
                    delegate: Rectangle {
                        required property var modelData
                        x: modelData.x
                        y: modelData.y
                        width: modelData.w
                        height: modelData.h
                        radius: root.tileRadius
                        color: modelData.app.enabled ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                        border.width: 1
                        border.color: modelData.app.enabled ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
                        clip: true
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 1
                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 2
                                    Image {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 16
                                        Layout.preferredHeight: 16
                                        visible: source !== ""
                                        source: root.iconSourceFor(modelData.app.exec || modelData.app.command)
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        cache: true
                                        onStatusChanged: if (status === Image.Error) source = ""
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.app.name || "App"
                                        color: modelData.app.enabled ? Color.foreground : Qt.darker(Color.foreground, 1.3)
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption - 1
                                        font.bold: true
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Live windows actually tiled on this workspace right now — thin
            // outlines mapped from real hyprctl clients coordinates into
            // preview space (monitor coords minus gaps_out/bar, scaled).
            Repeater {
                model: root.liveWindows
                delegate: Rectangle {
                    required property var modelData
                    readonly property real ox: root.hyprGapsOut + (root.barHorizontal ? 0 : root.barSizeW)
                    readonly property real oy: root.hyprGapsOut + (root.barHorizontal ? root.barSizeH : 0)
                    readonly property real lx: root.pxScale > 0 && modelData.at ? (modelData.at[0] - ox) * root.pxScale : 0
                    readonly property real ly: root.pxScale > 0 && modelData.at ? (modelData.at[1] - oy) * root.pxScale : 0
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.85)
                    radius: root.tileRadius
                    x: Math.max(-2, lx)
                    y: Math.max(-2, ly)
                    width: root.pxScale > 0 && modelData.size ? Math.max(4, modelData.size[0] * root.pxScale) : 0
                    height: root.pxScale > 0 && modelData.size ? Math.max(4, modelData.size[1] * root.pxScale) : 0
                    visible: root.pxScale > 0 && width > 4 && height > 4
                }
            }
        }

        // Bottom spacer (pairs with the top one) keeps the mini screen centered
        Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }
    }
}
