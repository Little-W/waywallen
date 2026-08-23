pragma ValueTypeBehavior: Assertable
import QtQuick
import QtQuick.Effects
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
    // Cached PageContainer entries stay constructed after navigating away.
    // Keep their poster, but never leave an animation decoder active.
    property bool pageActive: true
    // WallpaperPage flips this only once scrolling has stayed still briefly.
    // It prevents a visible row of decoders from starting on the flick-end
    // frame while retaining all poster textures.
    property bool animationSettled: true
    // Set only for the one topology change after a live viewport resize has
    // settled. Per-frame size changes bypass these animations entirely.
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
        if (!reflowTransitionActive) {
            _reflowPrepared = false;
            reflowXAnimation.stop();
            reflowYAnimation.stop();
            m_reflowTranslate.x = 0;
            m_reflowTranslate.y = 0;
            return;
        }
        // The GridView explicitly completes this FLIP in the same event-loop
        // turn as forceLayout().  Deferring it with Qt.callLater exposed one
        // fully-relayouted frame, perceived as a flash on a 165 Hz output.
        root.prepareReflow();
    }

    // Content cards keep their own modest rounding; the window outline is
    // handled by KWin/LightlyShaders and is intentionally unrelated.
    readonly property real _radius: 12
    readonly property real _cellInset: 6
    readonly property real cardWidth: Math.min(root.itemWidth, root.width)
    readonly property real cardHeight: Math.min(root.itemHeight, root.height)
    readonly property bool selectionHighlighted: root.selected || root.current
    property bool _pooled: false
    readonly property bool gridMoving: GridView.view
                                            ? (GridView.view.moving || GridView.view.flicking)
                                            : false
    // The shell shows a full-resolution snapshot while its width changes.
    // Suspend animated thumbnail decoding underneath it; static previews and
    // their source resolution are untouched.
    readonly property bool sceneMoving: root._pooled
                                       || !root.pageActive
                                       || !root.animationSettled
                                       || root.reflowTransitionActive
                                       || gridMoving
                                       || W.Global.windowResizing
                                       || W.Global.contentGeometryAnimating
                                       || W.Global.sidebarAnimating
    // Retain only a decoder that was already ready before the gesture.  This
    // keeps the scroll-start frame light without allowing cache-buffer or
    // cached-page delegates to remain animated.
    readonly property bool retainPausedAnimation: !root._pooled
                                                  && root.pageActive
                                                  && !W.Global.sidebarAnimating
                                                  && (root.reflowTransitionActive
                                                      || gridMoving
                                                      || W.Global.windowResizing
                                                      || W.Global.contentGeometryAnimating
                                                      || !root.animationSettled)
    // Keep preloaded GIF delegates quiet.  `cacheBuffer` intentionally retains
    // a little more than one row for smooth image hand-off, but those cards
    // are not on screen and should not decode or upload animation frames.
    // During motion the condition short-circuits before subscribing to
    // contentY, so a flick does not add a per-frame binding cost per card.
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
        // Raise the active card above its neighbours so its soft selection
        // shadow stays continuous at every edge of the grid cell.
        z: root.selectionHighlighted ? 1 : 0
        transform: Translate {
            id: m_reflowTranslate
        }

        // Animate rendered card geometry only for the settled column reflow.
        // GridView.cellWidth itself always matches the viewport immediately,
        // so no stale-width strip can appear at the page edge.
        Behavior on width {
            enabled: root.reflowTransitionActive
            NumberAnimation {
                duration: 220
                easing.type: root.reflowReverse ? Easing.InCubic
                                                : Easing.OutCubic
            }
        }
        Behavior on height {
            enabled: root.reflowTransitionActive
            NumberAnimation {
                duration: 220
                easing.type: root.reflowReverse ? Easing.InCubic
                                                : Easing.OutCubic
            }
        }

        Item {
            id: m_cell
            anchors.fill: parent
            anchors.margins: root._cellInset

            W.ThumbnailImage {
                id: m_thumb
                anchors.fill: parent
                source  : root.wallpaper?.preview ?? ""
                resource: root.wallpaper?.resource ?? ""
                wpType  : root.wallpaper?.wpType ?? ""
                fillMode: Image.PreserveAspectCrop
                radius: root._radius
                // Fixed rather than geometry-bound so sidebar transitions do
                // not cause every visible image to be decoded again. 512 px
                // preserves detail on high-DPI and wide-card layouts without
                // returning to full-resolution Workshop textures.
                maximumSourceSize: 512
                // Keep generated fallbacks in the same stable tier so layout
                // animation never reloads or upscales an undersized poster.
                thumbnailCacheEdge: 512
                motionActive: root.sceneMoving
                animationEnabled: root.animationEnabled
                staticPosterEnabled: true
                // Keep poster generation subscribed while this page owns the
                // delegate. Tying it to `animationEnabled` cancelled every
                // cold request at wheel-start and left newly visible cards
                // without either a poster or an animated fallback.
                posterRequestAllowed: !root._pooled && root.pageActive
                retainPausedAnimation: root.retainPausedAnimation
                cacheAnimatedFrames: false
            }

            // Render only a soft aura behind the preview. MultiEffect also
            // composited its border-shaped source, which read as a second
            // outline instead of light fading away from the selection frame.
            RectangularShadow {
                anchors.fill: m_thumb
                visible: opacity > 0.001
                opacity: root.selectionHighlighted ? 0.62 : 0.0
                z: -1
                color: W.Global.effectiveAccentColor
                blur: 18
                spread: 1
                radius: root._radius
                offset: Qt.vector2d(0, 0)

                Behavior on opacity {
                    NumberAnimation {
                        duration: 160
                        easing.type: Easing.OutCubic
                    }
                }
            }

            // Keep one crisp accent outline above the soft aura.
            Rectangle {
                anchors.fill: m_thumb
                visible: opacity > 0.001
                opacity: root.selectionHighlighted ? 1.0 : 0.0
                color: "transparent"
                radius: root._radius
                border.width: 4
                border.color: W.Global.effectiveAccentColor
                z: 2

                Behavior on opacity {
                    NumberAnimation {
                        duration: 160
                        easing.type: Easing.OutCubic
                    }
                }

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
                font.weight: Font.DemiBold
                // The title remains regular vector text above the thumbnail;
                // this outline improves contrast without ever reducing glyph
                // resolution through the image cache.
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.58)
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

    Rectangle {
        anchors.top: m_card.top
        anchors.left: m_card.left
        anchors.margins: 8
        width: 32
        height: 32
        radius: width / 2
        visible: root.selected
        color: W.Global.effectiveAccentColor
        border.color: W.Global.cupertinoCard
        border.width: 3

        MD.Icon {
            anchors.centerIn: parent
            name: MD.Token.icon.check
            size: 20
            color: MD.Token.color.on_primary
        }
    }

    // GridView's reuse pool retains the delegate object.  Releasing only the
    // animated overlay here avoids carrying GIF frame maps between unrelated
    // models while the persistent poster makes the next use immediate.
    GridView.onPooled: root._pooled = true
    GridView.onReused: root._pooled = false
}
