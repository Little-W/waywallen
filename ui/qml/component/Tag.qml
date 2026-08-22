pragma ComponentBehavior: Bound
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

// Compact pill-shaped label chip.  Neutral by default; callers still override
// it for GPU vendors and semantic status states where color conveys meaning.
Rectangle {
    id: root

    property alias text: tagText.text
    property alias textItem: tagText
    property color bgColor: W.Global.cupertinoControlFill
    property color fgColor: MD.Token.color.on_surface_variant

    implicitWidth: tagText.implicitWidth + 16
    implicitHeight: tagText.implicitHeight + 6
    radius: height / 2
    color: root.bgColor

    MD.Text {
        id: tagText
        anchors.centerIn: parent
        typescale: MD.Token.typescale.label_small
        color: root.fgColor
    }
}
