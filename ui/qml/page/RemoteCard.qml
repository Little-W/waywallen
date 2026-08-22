pragma ComponentBehavior: Bound
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    required property int index
    required property string itemId
    required property string title
    required property string previewUrl
    required property string author
    required property int acquisitionState
    required property int remoteCapability
    property real itemWidth: width
    property real itemHeight: height

    signal clicked()

    width: GridView.view ? GridView.view.cellWidth : 0
    height: GridView.view ? GridView.view.cellHeight : 0

    readonly property int _radius: 12
    readonly property real cardWidth: Math.min(root.itemWidth, root.width)
    readonly property real cardHeight: Math.min(root.itemHeight, root.height)
    readonly property bool gridMoving: GridView.view
                                            ? (GridView.view.moving || GridView.view.flicking)
                                            : false
    // During the shell's snapshot transition the live grid is obscured.
    // Pausing animated decoders avoids needless upload work without reducing
    // the resolution of any still image or text.
    readonly property bool sceneMoving: gridMoving || W.Global.sidebarAnimating
    // Cache-buffer delegates are useful for image reuse but should not keep
    // off-screen GIFs decoding.  Do not bind to contentY during a flick: all
    // animations are paused then, and the expression only needs reevaluation
    // once motion settles.
    readonly property bool animationEnabled: !sceneMoving && GridView.view
                                            ? root.y + root.height
                                                > GridView.view.contentY
                                                  - Math.max(48, GridView.view.cellHeight * 0.35)
                                              && root.y
                                                 < GridView.view.contentY + GridView.view.height
                                                   + Math.max(48, GridView.view.cellHeight * 0.35)
                                            : false

    Item {
        id: m_card
        width: root.cardWidth
        height: root.cardHeight
        anchors.centerIn: parent

        Item {
            id: m_cell
            anchors.fill: parent
            anchors.margins: 6

            W.ThumbnailImage {
                id: m_thumb
                anchors.fill: parent
                source: root.previewUrl
                resource: ""
                wpType: ""
                fillMode: Image.PreserveAspectCrop
                radius: root._radius
                // Keep browse thumbnails compact in GPU memory and avoid a
                // source reload when the responsive grid changes width.
                maximumSourceSize: 256
                motionActive: root.sceneMoving
                animationEnabled: root.animationEnabled
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(0, parent.height - m_title.y)
                visible: height > 0
                radius: root._radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.65) }
                }
            }

            MD.Text {
                id: m_title
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 6
                text: root.title.length > 0 ? root.title : qsTr("Untitled")
                typescale: MD.Token.typescale.title_small
                color: "white"
                font.weight: Font.DemiBold
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.62)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 2
                leftPadding: 8
                rightPadding: 8
            }

            Rectangle {
                visible: (root.remoteCapability === 1 && root.acquisitionState === 3)
                    || (root.remoteCapability === 2 && root.acquisitionState === 2)
                anchors { top: parent.top; right: parent.right; margins: 6 }
                width: m_badge.implicitWidth + 12
                height: m_badge.implicitHeight + 6
                radius: height / 2
                color: W.Global.effectiveAccentColor

                MD.Label {
                    id: m_badge
                    anchors.centerIn: parent
                    text: root.remoteCapability === 2 ? qsTr("Subscribed") : qsTr("Downloaded")
                    typescale: MD.Token.typescale.label_small
                    color: MD.Token.color.on_primary
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clicked()
            }
        }
    }
}
