import QtQuick
import QtQuick.Templates as T

import Qcm.Material as MD
import waywallen.ui as W

// Match Qcm's switch geometry, focus ring, ripple and thumb motion while
// binding the checked track directly to the resolved Waywallen accent. This
// makes the Accent Color setting visibly apply to every on/off control.
T.Switch {
    id: root

    property color accentColor: W.Global.effectiveAccentColor
    readonly property color inactiveTrackColor: W.Global.cupertinoControlFill
    readonly property color inactiveHandleColor: "#FFFFFF"

    implicitWidth: 52
    implicitHeight: 32
    padding: 0
    spacing: 8
    hoverEnabled: true

    icon.width: 16
    icon.height: 16
    icon.color: root.checked ? "#FFFFFF" : MD.MProp.color.on_surface_variant

    indicator: Rectangle {
        id: track

        width: 52
        height: 32
        radius: height / 2
        y: parent.height / 2 - height / 2
        color: root.checked ? root.accentColor : root.inactiveTrackColor
        opacity: root.enabled ? 1.0 : 0.42
        border.width: root.checked ? 0 : 1
        border.color: Qt.rgba(W.Global.cupertinoBorder.r,
                              W.Global.cupertinoBorder.g,
                              W.Global.cupertinoBorder.b,
                              0.72)

        Behavior on color {
            ColorAnimation {
                duration: 180
                easing.type: Easing.OutCubic
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: 120
            }
        }

        Rectangle {
            id: handle

            readonly property int edgeInset: 3
            readonly property int normalSize: 24

            width: normalSize
            height: normalSize
            radius: width / 2
            x: root.checked ? track.width - width - edgeInset : edgeInset
            y: (track.height - height) / 2
            color: root.checked ? "#FFFFFF" : root.inactiveHandleColor

            Behavior on x {
                enabled: !root.pressed
                SmoothedAnimation {
                    duration: 220
                    velocity: -1
                }
            }

            Behavior on width {
                NumberAnimation {
                    duration: 120
                }
            }

            Behavior on height {
                NumberAnimation {
                    duration: 120
                }
            }

            MD.Icon {
                anchors.centerIn: parent
                name: root.icon.name
                size: root.icon.width
                color: root.icon.color
                visible: name.length > 0
            }
        }

        MD.Ripple {
            x: handle.x + handle.width / 2 - width / 2
            y: handle.y + handle.height / 2 - height / 2
            width: 30
            height: 30
            radius: track.radius
            pressed: root.pressed
            pressX: root.pressX
            pressY: root.pressY
            color: root.checked ? root.accentColor : MD.MProp.color.on_surface
            stateOpacity: root.hovered ? MD.Token.state.hover.state_layer_opacity : 0
        }

        MD.FocusIndicator {
            anchors.centerIn: track
            width: track.width + 4
            height: track.height + 4
            active: root.visualFocus
            corners: MD.Util.corners(width / 2)
        }
    }

    contentItem: Item {
        implicitWidth: root.indicator.width
        implicitHeight: root.indicator.height
    }
}
