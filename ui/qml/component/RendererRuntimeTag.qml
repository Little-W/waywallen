pragma ComponentBehavior: Bound
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

Tag {
    id: root

    required property var runtimeTag

    readonly property string fullText: runtimeTag
        ? String(runtimeTag.key) + ": " + String(runtimeTag.value)
        : ""

    implicitWidth: Math.min(textItem.implicitWidth + 16, 160)
    text: fullText
    bgColor: W.Global.cupertinoControlFill
    fgColor: MD.Token.color.on_surface_variant

    textItem.width: Math.max(0, root.width - 16)
    textItem.elide: Text.ElideRight
    textItem.maximumLineCount: 1

    HoverHandler {
        id: hover
    }

    MD.ToolTip.visible: hover.hovered && root.textItem.truncated
    MD.ToolTip.delay: 300
    MD.ToolTip.text: root.fullText
}
