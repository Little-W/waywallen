import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// Preserve Qcm's chip sizing, check animation, keyboard focus and ripple,
// while swapping the Material container fill for a restrained desktop token.
MD.FilterChip {
    id: root

    mdState.textColor: MD.Token.color.on_surface
    mdState.leadingIconColor: W.Global.effectiveAccentColor
    mdState.trailingIconColor: MD.Token.color.on_surface_variant

    background: MD.ElevationRectangle {
        implicitWidth: 32
        implicitHeight: 32
        radius: 8
        color: root.checked
            ? Qt.rgba(W.Global.effectiveAccentColor.r,
                      W.Global.effectiveAccentColor.g,
                      W.Global.effectiveAccentColor.b,
                      W.Global.cupertinoDark ? 0.28 : 0.14)
            : W.Global.cupertinoCard
        opacity: root.enabled ? 1.0 : 0.48
        border.width: root.checked ? 1.5 : 1
        border.color: root.checked ? W.Global.effectiveAccentColor : W.Global.cupertinoBorder
        // Filter chips already communicate their state through the accent
        // fill and outline.  Raising a selected chip creates a dark halo on
        // light surfaces, especially after it receives the pointer focus.
        elevation: MD.Token.elevation.level0

        MD.Ripple {
            anchors.fill: parent
            radius: parent.radius
            pressX: root.pressX
            pressY: root.pressY
            pressed: root.pressed
            stateOpacity: root.mdState.stateLayerOpacity
            color: root.checked ? W.Global.effectiveAccentColor : MD.Token.color.on_surface_variant
        }

        MD.FocusIndicator {
            corners: MD.Util.corners(parent.radius)
            active: root.visualFocus
        }
    }
}
