import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// MD.EmbedChip keeps its leading/trailing icon and menu semantics.  This
// wrapper only replaces its Material tonal container.
MD.EmbedChip {
    id: root

    mdState.textColor: MD.Token.color.on_surface
    mdState.leadingIconColor: W.Global.effectiveAccentColor
    mdState.trailingIconColor: MD.Token.color.on_surface_variant

    background: MD.ElevationRectangle {
        implicitWidth: 32
        implicitHeight: 32
        radius: 8
        color: W.Global.cupertinoControlFill
        opacity: root.enabled ? 1.0 : 0.48
        border.width: root.visualFocus ? 1.5 : 1
        border.color: root.visualFocus
            ? W.Global.effectiveAccentColor
            : W.Global.cupertinoBorder
        elevation: root.hovered ? MD.Token.elevation.level1 : MD.Token.elevation.level0

        MD.Ripple {
            anchors.fill: parent
            radius: parent.radius
            pressX: root.pressX
            pressY: root.pressY
            pressed: root.pressed
            stateOpacity: root.mdState.stateLayerOpacity
            color: W.Global.effectiveAccentColor
        }

        MD.FocusIndicator {
            corners: MD.Util.corners(parent.radius)
            active: root.visualFocus
            outerColor: W.Global.effectiveAccentColor
            innerColor: W.Global.cupertinoCard
        }
    }
}
