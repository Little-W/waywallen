import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// Retains Qcm's dialog behaviour, focus handling and transitions while
// replacing only the accent-tinted Material sheet with a neutral glass card.
MD.Dialog {
    id: root

    mdState.backgroundColor: W.Global.cupertinoCard
    mdState.elevation: MD.Token.elevation.level2
    MD.MProp.backgroundColor: W.Global.cupertinoCard

    background: W.CupertinoSurface {
        frosted: W.App.frostedGlassAvailable
        surfaceColor: W.Global.cupertinoCard
        glassOpacity: 0.98
        cornerRadius: 18
        borderOpacity: 0.10
        elevation: root.mdState.elevation
    }

    W.DesktopWheelScroll {
        parent: root.contentItem
        flickable: root.contentItem instanceof Flickable ? root.contentItem : null
    }
}
