import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// A small, compositing-aware surface used by the desktop shell and popups.
// The opacity only becomes visible when the window manager has enabled
// blur-behind; otherwise this remains a fully opaque, readable Qcm surface.
MD.ElevationRectangle {
    id: root

    property bool frosted: false
    property color surfaceColor: W.Global.cupertinoCard
    property real glassOpacity: 0.96
    property real borderOpacity: 0.10
    property int cornerRadius: 16

    color: Qt.rgba(surfaceColor.r, surfaceColor.g, surfaceColor.b,
                   frosted ? glassOpacity : 1.0)
    radius: cornerRadius
    elevation: MD.Token.elevation.level0
    antialiasing: true

    // Surface borders remain subtle.  The desktop shell draws its two real
    // structural seams separately, so nested cards never gain a bright white
    // outline or a second rounded boundary.
    border.width: borderOpacity > 0 ? 1 : 0
    border.color: Qt.rgba(W.Global.cupertinoBorder.r,
                          W.Global.cupertinoBorder.g,
                          W.Global.cupertinoBorder.b,
                          borderOpacity)
}
