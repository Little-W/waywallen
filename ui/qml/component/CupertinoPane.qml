import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// Page-level white cards retain MD.Pane's padding/content contract while
// gaining a light outline on the cool-white canvas.  This keeps cards visible
// without the heavy Material elevation that previously made the hierarchy
// feel warm and bulky.
MD.Pane {
    id: root

    property bool frosted: W.App.frostedGlassAvailable
    property real glassOpacity: 0.99

    background: W.CupertinoSurface {
        frosted: root.frosted
        surfaceColor: root.backgroundColor
        glassOpacity: root.glassOpacity
        cornerRadius: root.radius
        borderOpacity: 0.10
        elevation: root.elevation
    }
}
