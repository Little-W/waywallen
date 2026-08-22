import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T

import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    implicitWidth: collapsed ? 76 : 240
    implicitHeight: 520
    clip: true

    property var model: []
    property int currentIndex: 0
    property bool collapsed: false
    // The shell captures the current page before changing its logical width.
    // Keep navigation inert during those few transition frames so clicks
    // cannot land on the pre-transition snapshot.
    property bool transitioning: false
    property real expansion: collapsed ? 0 : 1
    // Keep the product name in lockstep with navigation labels: it vanishes
    // before the header can become too narrow for natural text layout.
    readonly property real titleOpacity: Math.max(0, Math.min(1,
        (expansion - 0.76) / 0.24))

    Behavior on expansion {
        NumberAnimation {
            duration: 220
            easing.type: Easing.OutCubic
        }
    }

    signal pageSelected(int index)
    signal sidebarToggleRequested()
    signal pluginsRequested()
    signal settingsRequested()
    signal aboutRequested()

    component SidebarButton: T.Button {
        id: control

        property string iconName: ""
        property string label: ""
        property bool selected: false
        property bool collapsed: false
        property real expansion: root.expansion
        // Fade labels during the first quarter of a collapse while there is
        // still room to render them at their natural width. The remaining
        // width animation is then icon-only, so glyphs never get squeezed.
        readonly property real labelOpacity: Math.max(0, Math.min(1,
            (expansion - 0.76) / 0.24))
        // Keep navigation labels quiet and use small, semantic colour tiles
        // for recognition.  This avoids making the whole sidebar a single
        // high-saturation accent colour.
        property color tileColor: "#75839A"

        implicitHeight: 40
        enabled: !root.transitioning
        topPadding: 0
        bottomPadding: 0
        // Padding stays fixed while the parent changes its visual width.
        // Only the icon translates; changing Layout inputs every frame would
        // relayout every navigation action during the sidebar animation.
        leftPadding: 10
        rightPadding: 10
        hoverEnabled: true

        contentItem: Item {
            clip: true
            Rectangle {
                id: iconBubble
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Math.round((parent.width - width) / 2 * (1 - control.expansion))
                width: 24
                height: 24
                radius: 8
                color: control.selected
                    ? control.tileColor
                    : Qt.rgba(control.tileColor.r,
                              control.tileColor.g,
                              control.tileColor.b,
                              0.10)

                MD.Icon {
                    anchors.centerIn: parent
                    name: control.iconName
                    size: 18
                    fill: control.selected
                    color: control.selected
                        ? "#FFFFFF"
                        : control.tileColor
                }
            }

            MD.Label {
                visible: control.expansion > 0.76
                anchors.left: iconBubble.right
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: control.label
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                typescale: MD.Token.typescale.label_large
                font.weight: control.selected ? Font.DemiBold : Font.Normal
                color: MD.MProp.color.on_surface
                opacity: control.labelOpacity
            }
        }

        background: Rectangle {
            radius: 10
            color: {
                if (control.selected)
                    return Qt.rgba(MD.MProp.color.on_surface.r,
                                   MD.MProp.color.on_surface.g,
                                   MD.MProp.color.on_surface.b,
                                   0.075);
                if (control.down)
                    return Qt.rgba(MD.MProp.color.on_surface.r,
                                   MD.MProp.color.on_surface.g,
                                   MD.MProp.color.on_surface.b,
                                   0.10);
                if (control.hovered)
                    return Qt.rgba(MD.MProp.color.on_surface.r,
                                   MD.MProp.color.on_surface.g,
                                   MD.MProp.color.on_surface.b,
                                   0.06);
                return "transparent";
            }

            border.width: control.selected ? 1 : 0
            border.color: Qt.rgba(control.tileColor.r,
                                  control.tileColor.g,
                                  control.tileColor.b,
                                  0.18)

            Behavior on color {
                ColorAnimation {
                    duration: MD.Token.duration.short4
                }
            }

            MD.Ripple {
                anchors.fill: parent
                radius: parent.radius
                pressX: control.pressX
                pressY: control.pressY
                pressed: control.pressed
                stateOpacity: 0.12
                color: control.tileColor
            }
        }
    }

    W.CupertinoSurface {
        anchors.fill: parent
        frosted: W.App.frostedGlassAvailable
        surfaceColor: W.Global.cupertinoSidebar
        // Let the sidebar read as a distinct glass layer while the opaque
        // structural seam keeps its boundary with the main canvas clean.
        glassOpacity: 0.80
        // KWin's LightlyShaders effect owns the application window outline;
        // this surface stays rectangular to avoid a second inner silhouette.
        cornerRadius: 0
        borderOpacity: 0
        elevation: MD.Token.elevation.level0
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 8
            spacing: 2

            Rectangle {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                radius: 9
                color: Qt.rgba(MD.MProp.color.on_surface.r,
                               MD.MProp.color.on_surface.g,
                               MD.MProp.color.on_surface.b,
                               0.06)
                border.width: 1
                border.color: Qt.rgba(W.Global.cupertinoBorder.r,
                                      W.Global.cupertinoBorder.g,
                                      W.Global.cupertinoBorder.b,
                                      0.50)

                Image {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    source: "qrc:/waywallen/ui/assets/waywallen-ui.svg"
                    fillMode: Image.PreserveAspectFit
                    sourceSize.width: 44
                    sourceSize.height: 44
                }
            }

            MD.Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.leftMargin: root.expansion > 0.76 ? 8 : 0
                Layout.preferredWidth: 132
                visible: root.expansion > 0.76
                text: "waywallen"
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                typescale: MD.Token.typescale.title_medium
                font.weight: Font.DemiBold
                color: MD.MProp.color.on_surface
                opacity: root.titleOpacity
            }

            MD.StandardIconButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                Layout.leftMargin: root.expansion > 0.76 ? 8 : 0
                icon.name: root.collapsed ? MD.Token.icon.menu : MD.Token.icon.menu_open
                backgroundRadius: 9
                enabled: !root.transitioning
                onClicked: root.sidebarToggleRequested()
            }
        }

        Repeater {
            model: root.model

            delegate: SidebarButton {
                required property var modelData
                required property int index

                Layout.fillWidth: true
                iconName: modelData.icon
                label: modelData.name
                tileColor: modelData.tint
                selected: root.currentIndex === index
                collapsed: root.collapsed
                onClicked: root.pageSelected(index)
            }
        }

        Item {
            Layout.fillHeight: true
        }

        // A small spatial break separates utility actions without a bright
        // horizontal rule competing with the window's real white seam.
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 8
        }

        SidebarButton {
            Layout.fillWidth: true
            iconName: MD.Token.icon.extension
            label: qsTr("Plugins")
            tileColor: "#8779C5"
            collapsed: root.collapsed
            onClicked: root.pluginsRequested()
        }

        SidebarButton {
            Layout.fillWidth: true
            iconName: MD.Token.icon.settings
            label: qsTr("Settings")
            tileColor: "#748399"
            collapsed: root.collapsed
            onClicked: root.settingsRequested()
        }

        SidebarButton {
            Layout.fillWidth: true
            iconName: MD.Token.icon.info
            label: qsTr("About")
            tileColor: "#8B929D"
            collapsed: root.collapsed
            onClicked: root.aboutRequested()
        }
    }
}
