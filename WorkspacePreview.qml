import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Mock preview of a workspace's tiling. Shows assigned apps as tiles in a dwindle-like split
// plus live Hypr windows currently on that workspace.
Item {
    id: root
    property int workspace: 1
    property var assignedApps: [] // assignments filtered for this WS
    property var liveClients: [] // optional live hyprctl clients for this WS
    property bool isExpanded: false
    property int screenW: 0
    property int screenH: 0
    readonly property real screenAspect: screenW > 0 && screenH > 0 ? screenH / screenW : 0.5625

    implicitWidth: 320
    implicitHeight: previewBox.implicitHeight + 28 + (liveClients && liveClients.length>0 ? 22 : 0)

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
            Text {
                visible: root.liveClients && root.liveClients.length > 0
                text: "● live " + (root.liveClients ? root.liveClients.length : 0)
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 2
            }
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

            // Live indicator top-right
            Rectangle {
                visible: root.liveClients && root.liveClients.length > 0
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 4
                implicitHeight: 14
                implicitWidth: liveCountText.implicitWidth + 8
                radius: 7
                color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.9)
                Text {
                    id: liveCountText
                    anchors.centerIn: parent
                    text: "● " + (root.liveClients ? root.liveClients.length : 0) + " live"
                    color: "white"
                    font.family: Style.font.family
                    font.pixelSize: 7
                    font.bold: true
                }
            }

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

            // Tiles - manual position for dwindle mock, fallback to Flow for >4
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
                            Text {
                                Layout.fillWidth: true
                                text: {
                                    var e = modelData.exec || modelData.command || ""
                                    // shorten: show basename or host
                                    var m = e.match(/omarchy-launch-webapp\s+'([^']+)'/)
                                    if (m) {
                                        try { var u = new URL(m[1]); return u.hostname.replace(/^www\./,"") } catch(e){ return m[1].slice(0,16) }
                                    }
                                    var base = e.split(" ")[0].split("/").pop()
                                    return base.slice(0, 14)
                                }
                                color: Qt.darker(Color.foreground, 1.35)
                                font.family: "monospace"
                                font.pixelSize: 7
                                elide: Text.ElideMiddle
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Item { Layout.fillHeight: true }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: modelData.onlyOnBoot ? "once" : "every"
                                color: modelData.onlyOnBoot ? Color.accent : Qt.darker(Color.foreground, 1.2)
                                font.family: Style.font.family
                                font.pixelSize: 7
                            }
                        }
                    }
                }
            }
        }

        // Live Hypr windows (maybe) — chips below preview
        RowLayout {
            visible: root.liveClients && root.liveClients.length > 0
            Layout.fillWidth: true
            spacing: 4
            Text {
                text: "Live:"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: 7
                font.bold: true
            }
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: root.liveClients
                    delegate: Rectangle {
                        implicitHeight: 16
                        implicitWidth: liveChipText.implicitWidth + 10
                        radius: 8
                        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)
                        border.width: 1
                        border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.28)
                        Text {
                            id: liveChipText
                            anchors.centerIn: parent
                            text: (modelData.class || modelData.title || "win").toString().slice(0,14)
                            color: Color.accent
                            font.family: Style.font.family
                            font.pixelSize: 7
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }

        // Bottom spacer (pairs with the top one) keeps the mini screen centered
        Item { Layout.fillHeight: true; Layout.minimumHeight: 0 }
    }
}
