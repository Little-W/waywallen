import QtQuick

import Qcm.Material as MD
import waywallen.ui as W

// Retain Qcm's title, action overflow and navigation behaviour, but keep the
// structural page header clean white.  Scrollable collection toolbars use the
// dedicated CupertinoFrostedBar instead, where same-window blur is real.
MD.AppBar {
    id: root

    property bool frosted: false
    property color surfaceColor: W.Global.cupertinoCard
    property real glassOpacity: 1.0

    showBackground: true

    background: Rectangle {
        implicitHeight: 56
        color: Qt.rgba(root.surfaceColor.r,
                       root.surfaceColor.g,
                       root.surfaceColor.b,
                       root.frosted ? root.glassOpacity : 1.0)
        topLeftRadius: root.radius
        topRightRadius: root.radius
        bottomLeftRadius: 0
        bottomRightRadius: 0

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Qt.rgba(W.Global.cupertinoBorder.r,
                           W.Global.cupertinoBorder.g,
                           W.Global.cupertinoBorder.b,
                           0.35)
        }
    }
}
