pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

// Wallpaper thumbnail view.
//
// When `source` (a preview path or URL) is set, render it directly
// so animated formats (GIF/APNG/WebP) actually animate — the thumbnail
// pipeline transcodes to a single-frame PNG and would kill animation.
// When `source` is empty (typically video wallpapers), fall back to
// `W.ThumbnailRequest` which extracts a still frame from `resource`.
Item {
    id: root

    property string source
    property string resource
    property string wpType
    property int    fillMode: Image.PreserveAspectFit
    property int    radius: MD.Token.shape.corner.extra_small
    // Cap the decoded image/animated-frame texture rather than only scaling
    // it during painting.  The default is intentionally below the historic
    // x-large (512 px) cache: wallpaper grids typically render much smaller
    // cards, and retaining 4K/1080p source textures made scrolling needlessly
    // expensive.  Grid delegates use their own lower, fixed cap below.
    //
    // Keep this independent from width/height.  A live size binding would
    // reload every image while the sidebar changes the page geometry.
    property int maximumSourceSize: 384
    // Grid delegates set this while Flickable is moving.  Pausing animated
    // previews then is much cheaper than trying to redraw dozens of GIF
    // frames while their cards are being translated by the scene graph.
    property bool motionActive: false
    property bool animationEnabled: true

    readonly property bool _useDirect: root.source.length > 0
    readonly property url  _displayUrl: _useDirect
                                        ? (/^[a-z][a-z0-9+.-]*:/i.test(root.source)
                                           ? root.source
                                           : Qt.url("file://" + root.source))
                                        : req.cachePath
    readonly property string _sourceName: String(_displayUrl).split(/[?#]/)[0].toLowerCase()
    readonly property bool _isAnimated: _useDirect
                                      && /\.(gif|webp|apng|mng)$/.test(_sourceName)
    readonly property bool _hasDisplaySize: width > 0 && height > 0
    readonly property size _requestedSourceSize: maximumSourceSize > 0
                                                ? Qt.size(maximumSourceSize, maximumSourceSize)
                                                : Qt.size(-1, -1)

    readonly property int    state    : _useDirect ? W.ThumbnailRequest.Ready : req.state
    readonly property url    cachePath: _displayUrl

    readonly property real paintedWidth: m_image_loader.item ? m_image_loader.item.paintedWidth : 0
    readonly property real paintedHeight: m_image_loader.item ? m_image_loader.item.paintedHeight : 0
    readonly property int status: m_image_loader.item ? m_image_loader.item.status : Image.Null
    readonly property size sourceSize: m_image_loader.item
                                       ? m_image_loader.item.sourceSize
                                       : Qt.size(0, 0)
    property int verticalAlignment: Image.AlignVCenter

    W.ThumbnailRequest {
        id: req
        source  : ""
        resource: root._useDirect ? "" : root.resource
        wpType  : root._useDirect ? "" : root.wpType
    }

    Component {
        id: m_static_image_component

        Image {
            anchors.fill: parent
            sourceSize: root._requestedSourceSize
            source: root._displayUrl
            fillMode: root.fillMode
            verticalAlignment: root.verticalAlignment
            asynchronous: true
            retainWhileLoading: true
            cache: true
            smooth: true
            // Keep the established rounded visual.  With a static source the
            // layer is cached and moves as one texture while the grid scrolls.
            layer.enabled: root.radius > 0
            layer.effect: MD.RoundClip {
                corners: MD.Util.corners(root.radius)
                size: Qt.vector2d(root.width, root.height)
            }
        }
    }

    Component {
        id: m_animated_image_component

        AnimatedImage {
            anchors.fill: parent
            sourceSize: root._requestedSourceSize
            source: root._displayUrl
            fillMode: root.fillMode
            verticalAlignment: root.verticalAlignment
            asynchronous: true
            retainWhileLoading: true
            cache: true
            smooth: true
            playing: true
            paused: root.motionActive || !root.animationEnabled || !root.visible
            layer.enabled: root.radius > 0
            layer.effect: MD.RoundClip {
                corners: MD.Util.corners(root.radius)
                size: Qt.vector2d(root.width, root.height)
            }
        }
    }

    Loader {
        id: m_image_loader

        anchors.fill: parent
        active: root._hasDisplaySize && String(root._displayUrl).length > 0
        asynchronous: true
        sourceComponent: root._isAnimated
                         ? m_animated_image_component
                         : m_static_image_component
    }
}
