import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// Preserve Qcm's keyboard, focus and menu-item behaviour while giving every
// explicit contextual menu the same quiet white surface as dialogs and sheets.
MD.Menu {
    id: root

    property int cornerRadius: 12

    mdState.backgroundColor: W.Global.cupertinoCard
    mdState.elevation: MD.Token.elevation.level2

    background: W.CupertinoSurface {
        implicitWidth: 200
        implicitHeight: 48
        frosted: W.App.frostedGlassAvailable
        surfaceColor: root.mdState.backgroundColor
        glassOpacity: 0.98
        cornerRadius: root.cornerRadius
        borderOpacity: 0.10
        elevation: root.mdState.elevation
    }
}
