pragma ValueTypeBehavior: Assertable
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root
    objectName: "wallpaperCard"

    required property var model
    required property int index
    property var wallpaper: model
    property bool selected: false
    property bool current: false
    // The grid supplies these states so cached delegates never keep a GIF
    // decoder running while the page is moving or being reflowed.
    property bool pageActive: true
    property bool animationSettled: true
    property bool reflowTransitionActive: false
    property bool reflowReverse: false
    property point _reflowSceneOrigin: Qt.point(0, 0)
    property real itemWidth: width
    property real itemHeight: height

    width: GridView.view ? GridView.view.cellWidth : 0
    height: GridView.view ? GridView.view.cellHeight : 0

    focusPolicy: Qt.StrongFocus

    signal clicked(int modifiers)
    signal selectionRequested(int modifiers)

    property bool _reflowPrepared: false
    property bool _pooled: false

    // FLIP keeps a single, stable card surface moving when GridView changes
    // column topology.  It avoids exposing an intermediate row layout during
    // a detail-panel transition or after a resize has settled.
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

    readonly property int _baseRadius: MD.Token.shape.corner.extra_small
    readonly property int _selectedRadius: MD.Token.shape.corner.large
    readonly property int _radius: root.selected ? root._selectedRadius : root._baseRadius
    readonly property real _selectedInset: root._selectedRadius / 2
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

    Rectangle {
        anchors.fill: parent
        visible: root.selected
        color: MD.Token.color.primary_container
    }

    Item {
        id: m_card
        width: root.cardWidth
        height: root.cardHeight
        anchors.centerIn: parent
        z: (root.selected || root.current) ? 1 : 0
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
            anchors.margins: 6 + (root.selected ? root._selectedInset : 0)

            W.ThumbnailImage {
                id: m_thumb
                anchors.fill: parent
                source  : root.wallpaper?.preview ?? ""
                resource: root.wallpaper?.resource ?? ""
                wpType  : root.wallpaper?.wpType ?? ""
                fillMode: Image.PreserveAspectCrop
                radius: root._radius
                // Keep card textures bounded and reuse an asynchronously
                // generated poster while the grid is translating.
                maximumSourceSize: 512
                thumbnailCacheEdge: 512
                motionActive: root.sceneMoving
                animationEnabled: root.animationEnabled
                staticPosterEnabled: true
                posterRequestAllowed: !root._pooled && root.pageActive
                retainPausedAnimation: root.retainPausedAnimation
                cacheAnimatedFrames: false
            }

            // Scrim aligns to the image control's bounds; spans the
            // title-top → image-bottom overlap.
            Rectangle {
                anchors.left  : m_thumb.left
                anchors.right : m_thumb.right
                anchors.bottom: m_thumb.bottom
                height: Math.max(0, m_thumb.height - m_title.y)
                visible: height > 0
                radius: root._radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
                }
            }

            MD.Text {
                id: m_title
                anchors.left  : parent.left
                anchors.right : parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 6
                text: root.wallpaper?.name || qsTr("Untitled")
                typescale: MD.Token.typescale.title_small
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 2
                leftPadding: 8
                rightPadding: 8
            }

            MouseArea {
                property bool selectionRequestedByHold: false

                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onPressed: selectionRequestedByHold = false
                onCanceled: selectionRequestedByHold = false
                onPressAndHold: mouse => {
                    if (mouse.button !== Qt.LeftButton)
                        return;
                    selectionRequestedByHold = true;
                    root.selectionRequested(mouse.modifiers);
                }
                onClicked: mouse => {
                    if (selectionRequestedByHold) {
                        selectionRequestedByHold = false;
                        return;
                    }
                    if (mouse.button === Qt.RightButton) {
                        root.selectionRequested(mouse.modifiers);
                        return;
                    }
                    root.clicked(mouse.modifiers);
                }
            }
        }
    }

    Rectangle {
        anchors.top: m_card.top
        anchors.left: m_card.left
        anchors.margins: 8
        width: 32
        height: 32
        radius: width / 2
        visible: root.selected
        color: MD.Token.color.primary
        border.color: MD.Token.color.primary_container
        border.width: 3

        MD.Icon {
            anchors.centerIn: parent
            name: MD.Token.icon.check
            size: 20
            color: MD.Token.color.on_primary
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
