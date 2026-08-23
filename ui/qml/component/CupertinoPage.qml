import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// A Page-compatible wrapper keeps the Qcm page context, stack transitions and
// action handling intact while giving every secondary page the same header and
// cool-white content background.
MD.Page {
    id: root

    backgroundColor: W.Global.cupertinoCanvas

    header: W.CupertinoAppBar {
        title: root.title
        leadingAction: root.leadingAction
        actions: root.actions
        radius: root.backgroundRadius
        visible: root.MD.MProp.page.showHeader
    }

    // Every page whose direct content is scrollable shares the native C++
    // wheel trajectory. Plain-layout and split-view pages leave this inert;
    // their nested views attach the same helper themselves.
    W.DesktopWheelScroll {
        parent: root.contentItem
        flickable: root.contentItem instanceof Flickable ? root.contentItem : null
    }
}
