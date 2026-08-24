pragma ComponentBehavior: Bound
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root
    objectName: "discoverWallpaperCard"

    required property int index
    required property string itemId
    required property string title
    required property string previewUrl
    required property string author
    required property int acquisitionState
    required property int remoteCapability
    property bool current: false
    property bool pageActive: true
    property bool animationSettled: true
    property bool reflowTransitionActive: false
    property bool reflowReverse: false
    property point _reflowSceneOrigin: Qt.point(0, 0)
    property real itemWidth: width
    property real itemHeight: height

    signal clicked()

    property bool _reflowPrepared: false
    property bool _pooled: false

    function prepareReflow() {
        if (!reflowTransitionActive)
            return;
        reflowXAnimation.stop();
        reflowYAnimation.stop();
        m_reflowTranslate.x = 0;
        m_reflowTranslate.y = 0;
        _reflowSceneOrigin = m_card.mapToItem(null, 0, 0);
        _reflowPrepared = true;
    }

    function startPreparedReflow() {
        if (!reflowTransitionActive || !_reflowPrepared)
            return;
        const currentOrigin = m_card.mapToItem(null, 0, 0);
        m_reflowTranslate.x = _reflowSceneOrigin.x - currentOrigin.x;
        m_reflowTranslate.y = _reflowSceneOrigin.y - currentOrigin.y;
        _reflowPrepared = false;
        reflowXAnimation.restart();
        reflowYAnimation.restart();
    }

    onReflowTransitionActiveChanged: {
        if (reflowTransitionActive) {
            root.prepareReflow();
            return;
        }
        _reflowPrepared = false;
        reflowXAnimation.stop();
        reflowYAnimation.stop();
        m_reflowTranslate.x = 0;
        m_reflowTranslate.y = 0;
    }

    width: GridView.view ? GridView.view.cellWidth : 0
    height: GridView.view ? GridView.view.cellHeight : 0

    readonly property int _radius: MD.Token.shape.corner.extra_small
    readonly property real cardWidth: Math.min(root.itemWidth, root.width)
    readonly property real cardHeight: Math.min(root.itemHeight, root.height)
    readonly property bool gridMoving: GridView.view
                                      ? (GridView.view.moving || GridView.view.flicking)
                                      : false
    readonly property bool sceneMoving: root._pooled
                                       || !root.pageActive
                                       || !root.animationSettled
                                       || root.reflowTransitionActive
                                       || root.gridMoving
    readonly property bool retainPausedAnimation: !root._pooled
                                                  && root.pageActive
                                                  && (root.reflowTransitionActive
                                                      || root.gridMoving
                                                      || !root.animationSettled)
    readonly property bool animationEnabled: !root.sceneMoving && GridView.view
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
        z: root.current ? 1 : 0
        transform: Translate {
            id: m_reflowTranslate
        }

        Behavior on width {
            enabled: root.reflowTransitionActive
            NumberAnimation {
                duration: 220
                easing.type: root.reflowReverse ? Easing.InCubic : Easing.OutCubic
            }
        }
        Behavior on height {
            enabled: root.reflowTransitionActive
            NumberAnimation {
                duration: 220
                easing.type: root.reflowReverse ? Easing.InCubic : Easing.OutCubic
            }
        }

        Item {
            id: m_cell
            anchors.fill: parent
            anchors.margins: 6
            clip: true

            W.ThumbnailImage {
                id: m_thumb
                anchors.fill: parent
                source: root.previewUrl
                resource: ""
                wpType: ""
                fillMode: Image.PreserveAspectCrop
                radius: root._radius
                maximumSourceSize: 512
                motionActive: root.sceneMoving
                animationEnabled: root.animationEnabled
                // Remote GIF/WebP previews keep their original decoder when
                // settled and are replayed after finite source loops.
                staticPosterEnabled: true
                posterRequestAllowed: !root._pooled && root.pageActive
                retainPausedAnimation: root.retainPausedAnimation
                cacheAnimatedFrames: true
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
                color: MD.Token.color.primary

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

    NumberAnimation {
        id: reflowXAnimation
        target: m_reflowTranslate
        property: "x"
        to: 0
        duration: 220
        easing.type: root.reflowReverse ? Easing.InCubic : Easing.OutCubic
    }

    NumberAnimation {
        id: reflowYAnimation
        target: m_reflowTranslate
        property: "y"
        to: 0
        duration: 220
        easing.type: root.reflowReverse ? Easing.InCubic : Easing.OutCubic
    }

    GridView.onPooled: root._pooled = true
    GridView.onReused: root._pooled = false
}
