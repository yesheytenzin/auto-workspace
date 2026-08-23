import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Mock preview of a workspace's tiling. Shows assigned apps as tiles in a
// dwindle-like split, miniaturized to the user's screen aspect.
Item {
    id: root
    property int workspace: 1
    property var assignedApps: [] // assignments filtered for this WS
    property var appList: [] // installed apps with iconPath, for icon lookup
    property bool isExpanded: false
    property int screenW: 0
    property int screenH: 0
    property var bar: null
    readonly property real screenAspect: screenW > 0 && screenH > 0 ? screenH / screenW : 0.5625
    readonly property var appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null

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
            Item { Layout.fillWidth: true }
        }

        // Spacers center the mini screen vertically in whatever room the
        // column gives it, instead of stretching the aspect ratio.
        Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }

        // Preview box - dwindle mock, miniaturized to match the user's screen aspect
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

            // Tiles - manual position for dwindle mock, fallback to grid for >4
            Item {
                id: tilesContainer
                anchors.fill: parent
                anchors.margins: 6
                visible: root.assignedApps.length > 0

                // For 1-4 apps use tiled split, for >4 use grid
                property int count: root.assignedApps.length

                Repeater {
                    model: root.assignedApps
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        // Compute geometry for mock dwindle
                        // Use function to get rect for index
                        function rectFor(idx, total, parentW, parentH) {
                            if (total === 1) return Qt.rect(0, 0, parentW, parentH)
                            if (total === 2) {
                                if (idx === 0) return Qt.rect(0, 0, parentW * 0.5 - 2, parentH)
                                return Qt.rect(parentW * 0.5 + 2, 0, parentW * 0.5 - 2, parentH)
                            }
                            if (total === 3) {
                                if (idx === 0) return Qt.rect(0, 0, parentW * 0.5 - 2, parentH)
                                if (idx === 1) return Qt.rect(parentW * 0.5 + 2, 0, parentW * 0.5 - 2, parentH * 0.5 - 2)
                                return Qt.rect(parentW * 0.5 + 2, parentH * 0.5 + 2, parentW * 0.5 - 2, parentH * 0.5 - 2)
                            }
                            if (total === 4) {
                                if (idx === 0) return Qt.rect(0, 0, parentW * 0.5 - 2, parentH * 0.5 - 2)
                                if (idx === 1) return Qt.rect(parentW * 0.5 + 2, 0, parentW * 0.5 - 2, parentH * 0.5 - 2)
                                if (idx === 2) return Qt.rect(0, parentH * 0.5 + 2, parentW * 0.5 - 2, parentH * 0.5 - 2)
                                return Qt.rect(parentW * 0.5 + 2, parentH * 0.5 + 2, parentW * 0.5 - 2, parentH * 0.5 - 2)
                            }
                            // >4: grid 3 cols
                            var cols = total <= 6 ? 3 : 4
                            var rows = Math.ceil(total / cols)
                            var w = (parentW - (cols - 1) * 4) / cols
                            var h = (parentH - (rows - 1) * 4) / rows
                            var col = idx % cols
                            var row = Math.floor(idx / cols)
                            return Qt.rect(col * (w + 4), row * (h + 4), w, h)
                        }

                        property rect geom: rectFor(index, tilesContainer.count, tilesContainer.width, tilesContainer.height)

                        x: geom.x
                        y: geom.y
                        width: geom.width
                        height: geom.height
                        radius: 6
                        color: modelData.enabled ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                        border.width: 1
                        border.color: modelData.enabled ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
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
            }
        }

        // Bottom spacer (pairs with the top one) keeps the mini screen centered
        Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }
    }
}