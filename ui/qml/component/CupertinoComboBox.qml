import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// MD.ComboBox already provides the mature input, keyboard and selection
// behaviour we need.  Only its hard-coded Material popup is replaced.
MD.ComboBox {
    id: root

    popup: W.CupertinoMenu {
        y: root.editable ? root.height - 5 : 0
        height: root.popupMaximumHeight > 0
            ? Math.min(implicitHeight, root.popupMaximumHeight)
            : implicitHeight
        width: root.width
        transformOrigin: Item.Top
        modal: false
        focus: false
        model: root.delegateModel
        topMargin: 12
        bottomMargin: 12
        verticalPadding: 8
        currentIndex: root.currentIndex
    }
}
