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
}
