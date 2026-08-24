pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

// Wallpaper thumbnail view.
//
// When `source` (a preview path or URL) is set, it normally renders directly
// so animated formats (GIF/APNG/WebP) can animate.  Grid delegates can opt
// into a cached first-frame poster: it remains visible while an animation is
// paused or loading, which keeps flicking independent from GIF decoding.
// When `source` is empty (typically video wallpapers), fall back to
// `W.ThumbnailRequest` which extracts a still frame from `resource`.
Item {
    id: root

    property string source
    property string resource
    property string wpType
    property int    fillMode: Image.PreserveAspectFit
    property real   radius: MD.Token.shape.corner.extra_small
    // Cap the decoded image/animated-frame texture rather than only scaling
    // it during painting.  The default is intentionally below the historic
    // x-large (512 px) cache: wallpaper grids typically render much smaller
    // cards, and retaining 4K/1080p source textures made scrolling needlessly
    // expensive.  Grid delegates use their own lower, fixed cap below.
    //
    // Keep this independent from width/height.  A live size binding would
    // reload every image while the sidebar changes the page geometry.
    property int maximumSourceSize: 384
    // Disk-generated thumbnails may serve views other than the live image
    // above.  Keep the historic 512 px default for detail/video previews,
    // while dense grid delegates opt into the matching 256 px cache tier.
    property int thumbnailCacheEdge: 512
    // Grid delegates set this while Flickable is moving.  Pausing animated
    // previews then is much cheaper than trying to redraw dozens of GIF
    // frames while their cards are being translated by the scene graph.
    property bool motionActive: false
    property bool animationEnabled: true
    // Local grid previews use this to produce a background-thread, cached
    // first frame.  It deliberately defaults to false so the detail page
    // keeps its immediate full-animation behavior.
    property bool staticPosterEnabled: false
    // The grid enables poster work only after it has settled around the
    // viewport.  It prevents a fast flick across a cold library from queuing
    // a disk conversion for every GIF that merely passes through the cache.
    property bool posterRequestAllowed: true
    // Keep an already-ready animation paused through a short flick/settle
    // window.  This avoids synchronously destroying a full visible row on
    // the first scroll frame; newly entered cards still never create one
    // until the grid has settled.
    property bool retainPausedAnimation: false
    // `AnimatedImage.cache` maps to QMovie::CacheAll.  It is useful for the
    // one full-size detail preview, but causes large frame caches when a grid
    // has many GIFs.  Grid callers disable it without changing detail pages.
    property bool cacheAnimatedFrames: true

    readonly property bool _useDirect: root.source.length > 0
    readonly property url _directUrl: _useDirect
                                      ? (/^[a-z][a-z0-9+.-]*:/i.test(root.source)
                                         ? root.source
                                         : Qt.url("file://" + root.source))
                                      : ""
    readonly property string _sourceName: String(_directUrl).split(/[?#]/)[0].toLowerCase()
    readonly property bool _hasAnimatedSuffix: _useDirect
                                               && /\.(gif|webp|apng|mng)$/.test(_sourceName)
    // ThumbnailRequest takes a local filesystem path.  Do not pass URL
    // previews (notably Discover's https posters) through QFileInfo.
    readonly property bool _isFileUrl: /^file:/i.test(root.source)
    readonly property bool _isLocalDirect: _useDirect
                                           && (!/^[a-z][a-z0-9+.-]*:/i.test(root.source)
                                               || root._isFileUrl)
    readonly property string _localSourcePath: !root._isLocalDirect
                                               ? ""
                                               : (root._isFileUrl
                                                  ? decodeURIComponent(String(root.source)
                                                                       .replace(/^file:\/\/(?:localhost)?/i,
                                                                                ""))
                                                  : root.source)
    readonly property bool _needsRemoteTypeProbe: root.staticPosterEnabled
                                                   && root._useDirect
                                                   && !root._isLocalDirect
                                                   && !root._hasAnimatedSuffix
    readonly property bool _isAnimated: root._hasAnimatedSuffix
                                      || (root._needsRemoteTypeProbe
                                          && req.remoteTypeResolved
                                          && req.remoteAnimated)
    readonly property bool posterSupported: root.staticPosterEnabled
                                           && root._isAnimated
                                           && root._isLocalDirect
    // Discover previews are remote and cannot use the local thumbnail worker
    // to determine whether animation frame zero is an empty/black lead. Guard
    // that frame only for poster-enabled remote cards; full-size remote
    // previews retain the source's complete animation.
    readonly property bool _guardRemoteLeadFrame: root.staticPosterEnabled
                                                  && root._isAnimated
                                                  && !root._isLocalDirect
    readonly property bool canRequestPoster: root.posterSupported
                                             && root.posterRequestAllowed
    property string _posterSource: ""
    property bool _posterAttempted: false
    property string _loadedAnimationSource: ""
    readonly property bool _posterReady: root.posterSupported
                                         && req.state === W.ThumbnailRequest.Ready
                                         && String(req.cachePath).length > 0
    // While a local poster is cold, keep a live decoder as a correctness
    // fallback even during motion. Delegates are created inside GridView's
    // cache buffer, so the decoder normally reaches a usable frame before the
    // card enters the viewport. Once the poster is ready the normal
    // motion/visibility policy takes over again.
    readonly property bool _coldPosterFallback: root.posterSupported
                                                && root.posterRequestAllowed
                                                && req.state !== W.ThumbnailRequest.Ready
                                                && req.state !== W.ThumbnailRequest.Failed
    // An extensionless remote animation has no worker-generated poster. Keep
    // its one decoder resident for active, non-pooled Discover delegates so a
    // wheel start can reuse the already-advanced representative frame instead
    // of falling back to the source's black frame zero.
    readonly property bool _keepRemoteAnimationReady: root._guardRemoteLeadFrame
                                                       && root.posterRequestAllowed
    // Keep a direct decode attached during a cache miss. This gives
    // retainWhileLoading a source to carry across delegate reuse and prevents
    // fast cold-cache sweeps from exposing the white card background. The
    // synchronous cold AnimatedImage loader below advances black lead frames
    // before this temporary underlay is composited.
    readonly property url _displayUrl: _useDirect
                                        ? (root._posterReady
                                           ? req.cachePath : root._directUrl)
                                        : req.cachePath
    readonly property bool _hasDisplaySize: width > 0 && height > 0
    readonly property size _requestedSourceSize: maximumSourceSize > 0
                                                ? Qt.size(maximumSourceSize, maximumSourceSize)
                                                : Qt.size(-1, -1)
    // Only the settled, near-viewport delegates get an AnimatedImage.  All
    // cards use the static poster while a GridView flicks, so a reused
    // delegate cannot create a GIF decoder or upload a frame mid-scroll.
    readonly property bool _showAnimated: root._isAnimated
                                          && root._hasDisplaySize
                                          && (root._keepRemoteAnimationReady
                                              || root._coldPosterFallback
                                              || (root.animationEnabled
                                                  && !root.motionActive))
    // Keep the normal detail-preview path as a single AnimatedImage.  A
    // static source exists permanently only for grid posters, or temporarily
    // while a non-poster animation is paused/offscreen.
    readonly property bool _staticLayerNeeded: !root._isAnimated
                                               || root.staticPosterEnabled
                                               || root.motionActive
                                               || !root.animationEnabled
    readonly property bool _retainLoadedAnimation: root._isAnimated
                                                   && root.retainPausedAnimation
                                                   && root._loadedAnimationSource
                                                      === String(root._directUrl)
    // Retaining a ready animation means it can stay as the visible, paused
    // texture during motion.  Switching every visible card to a separately
    // scaled first-frame poster at wheel-start introduced a one-frame sampling
    // jump and made live window resizing look unstable.  Newly entered cards
    // still use the cheap poster because they have no retained overlay.
    readonly property bool _animatedOverlayRequested: root._keepRemoteAnimationReady
                                                      || root._coldPosterFallback
                                                      || (root.animationEnabled
                                                          && !root.motionActive)
                                                      || root._retainLoadedAnimation
    // Animated previews occasionally contain a deliberately empty frame 0
    // (Steam's pjsk-晓山瑞希 preview is one example). Keep the representative
    // poster visible until the decoder advances to a real animation frame,
    // and reveal it again if a paused loop lands on frame 0.
    readonly property bool _animatedFrameUsable: (!root.posterSupported
                                                   && !root._guardRemoteLeadFrame)
                                                  || (root._posterReady
                                                      && !req.firstFrameBlank)
                                                  || (m_animated_loader.item
                                                      && m_animated_loader.item.currentFrame > 0)
    readonly property bool _animatedOverlayVisible: root._animatedOverlayRequested
                                                    && root._animatedFrameUsable
    readonly property bool _animatedLayerReady: m_animated_loader.item
                                                && m_animated_loader.item.visible
                                                && m_animated_loader.item.status === Image.Ready
    // Do not tear down a cached poster's rounded layer just because the
    // settled animation is painted above it.  Recreating an FBO for every
    // visible card on the first flick frame causes a much more noticeable
    // hitch than keeping each immutable poster surface warm.
    readonly property bool _staticLayerVisible: root._staticLayerNeeded
                                               && !root._animatedLayerReady

    readonly property int    state    : _useDirect ? W.ThumbnailRequest.Ready : req.state
    readonly property url    cachePath: _displayUrl

    readonly property var _presentedImage: root._animatedLayerReady
                                          ? m_animated_loader.item
                                          : m_static_image
    readonly property real paintedWidth: _presentedImage ? _presentedImage.paintedWidth : 0
    readonly property real paintedHeight: _presentedImage ? _presentedImage.paintedHeight : 0
    readonly property int status: _presentedImage ? _presentedImage.status : Image.Null
    readonly property size sourceSize: _presentedImage
                                       ? _presentedImage.sourceSize
                                       : Qt.size(0, 0)
    property int verticalAlignment: Image.AlignVCenter

    W.ThumbnailRequest {
        id: req
        // A source preview is normally direct.  Only explicitly opted-in,
        // local animated cards request the PNG poster; remote URLs stay on
        // the direct path because ThumbnailRequest intentionally handles
        // filesystem sources only.
        source  : root._posterSource
        remoteTypeSource: root._needsRemoteTypeProbe ? root.source : ""
        resource: root._useDirect ? "" : root.resource
        wpType  : root._useDirect ? "" : root.wpType
        maximumEdge: root.thumbnailCacheEdge
    }

    function _requestPosterWhenUseful() {
        if (!root.canRequestPoster || root._posterSource === root._localSourcePath)
            return;
        root._posterSource = root._localSourcePath;
        root._posterAttempted = true;
    }

    onSourceChanged: {
        // A pooled delegate may receive a new model while the GridView is
        // moving.  Drop its old subscription immediately; a new poster is
        // only requested after that model becomes close to a settled viewport.
        root._posterSource = "";
        root._posterAttempted = false;
        root._loadedAnimationSource = "";
        root._requestPosterWhenUseful();
    }
    onPosterRequestAllowedChanged: {
        // Do not keep a cold cache conversion subscribed after the card has
        // left the settled viewport.  Ready posters stay attached and are
        // reused immediately on the next flick; only in-flight work detaches.
        if (!root.posterRequestAllowed && req.state === W.ThumbnailRequest.Loading) {
            root._posterSource = "";
            root._posterAttempted = false;
        }
        root._requestPosterWhenUseful();
    }
    onCanRequestPosterChanged: root._requestPosterWhenUseful()
    Component.onCompleted: root._requestPosterWhenUseful()

    // Grid posters are persistent underlays rather than Loader alternatives.
    // An AnimatedImage is placed over an already-ready still after scrolling
    // stops, so it never exposes a blank card while it decodes.
    Image {
        id: m_static_image

        anchors.fill: parent
        sourceSize: root._requestedSourceSize
        source: root._staticLayerNeeded ? root._displayUrl : ""
        fillMode: root.fillMode
        verticalAlignment: root.verticalAlignment
        asynchronous: true
        retainWhileLoading: true
        cache: true
        smooth: true
        // Keep this in the scene graph while an animation overlays it.  An
        // opacity-zero cached layer retains the already-rendered rounded
        // texture, so scrolling can reveal it without an FBO allocation or
        // redraw across the full visible row.
        visible: root._staticLayerNeeded
        opacity: root._staticLayerVisible ? 1.0 : 0.0
        // Keep the established rounded visual.  With a static source the
        // layer is cached and moves as one texture while the grid scrolls.
        // Once the animated overlay is ready this source remains decoded and
        // its cached surface stays warm for a no-hitch return to scrolling.
        // The FBO follows card geometry and DPR, but only the bounded visible
        // delegate set retains one: a deliberate VRAM trade for smooth flick
        // starts.
        layer.enabled: root.radius > 0 && root._staticLayerNeeded
        // Keep rounded-thumbnail FBO allocation independent from live card
        // geometry. Without an explicit texture size, every Wayland configure
        // reallocates one off-screen target per visible card and stalls the
        // render thread before the new buffer can reach KWin.
        layer.textureSize: Qt.size(Math.max(1, root.maximumSourceSize),
                                   Math.max(1, root.maximumSourceSize))
        // Item layers default to nearest-neighbour sampling. These cached
        // rounded textures are commonly shown larger than their fixed FBO
        // during responsive layout, so nearest filtering produced visible
        // square pixels even though Image.smooth itself was enabled.
        layer.smooth: true
        layer.effect: MD.RoundClip {
            corners: MD.Util.corners(root.radius)
            size: Qt.vector2d(root.width, root.height)
        }
    }

    Component {
        id: m_animated_image_component

        AnimatedImage {
            id: animatedImage

            anchors.fill: parent
            sourceSize: root._requestedSourceSize
            // Always animate the original source.  `_displayUrl` may be the
            // PNG poster once it reaches the disk cache.
            source: root._directUrl
            fillMode: root.fillMode
            verticalAlignment: root.verticalAlignment
            // The Loader and its first small decoded frame are synchronous
            // only for a cold poster miss. This lets skipEmptyLeadFrame()
            // advance frame zero before the direct static underlay can expose
            // it; all hot-cache and normal animation decoding remains async.
            asynchronous: !root._coldPosterFallback
            retainWhileLoading: true
            cache: root.cacheAnimatedFrames
            smooth: true
            visible: root._animatedOverlayVisible
            // A cold decoder must be allowed to advance away from frame zero
            // even if the GridView is already moving. It is paused again as
            // soon as the representative poster has reached the cache.
            paused: !root._coldPosterFallback
                    && (root.motionActive || !root.animationEnabled || !root.visible)
            function skipEmptyLeadFrame() {
                // Before the worker answers, skip frame zero for every local
                // poster source. This prevents a known-black frame from ever
                // reaching the scene graph on a cold-cache render. Once the
                // worker confirms a normal frame zero, later loops retain it.
                if (status === Image.Ready && frameCount > 1
                        && currentFrame === 0
                        && (root._coldPosterFallback || req.firstFrameBlank
                            || root._guardRemoteLeadFrame))
                    currentFrame = 1;
            }
            function restartFinishedAnimation() {
                // Some Workshop previews declare a finite GIF loop count.
                // Discover is a live preview surface, so restart after the
                // source-defined final loop whenever the card is active.
                if (status !== Image.Ready || frameCount <= 1 || playing
                        || paused || !root._animatedOverlayRequested)
                    return;
                currentFrame = (req.firstFrameBlank
                                || root._guardRemoteLeadFrame) ? 1 : 0;
                playing = true;
            }
            onStatusChanged: {
                if (status === Image.Ready) {
                    root._loadedAnimationSource = String(root._directUrl);
                    skipEmptyLeadFrame();
                    // Do not bind `playing` permanently to true: Qt updates
                    // the property when a finite source loop ends, and the
                    // replay handler below must be able to observe that edge.
                    if (!paused)
                        playing = true;
                }
            }
            onCurrentFrameChanged: {
                // QMovie loops back through frame zero. For sources whose
                // worker-confirmed lead frame is blank, skip it on every loop
                // instead of briefly painting black over the poster.
                if ((req.firstFrameBlank || root._guardRemoteLeadFrame)
                        && frameCount > 1 && currentFrame === 0)
                    currentFrame = 1;
            }
            onPlayingChanged: {
                if (!playing)
                    replayTimer.restart();
            }
            onPausedChanged: {
                if (!paused && !playing)
                    replayTimer.restart();
            }
            Timer {
                id: replayTimer

                interval: 0
                repeat: false
                onTriggered: animatedImage.restartFinishedAnimation()
            }
            Connections {
                target: req
                function onFirstFrameBlankChanged() {
                    animatedImage.skipEmptyLeadFrame();
                }
            }
            layer.enabled: root.radius > 0 && visible
            layer.textureSize: Qt.size(Math.max(1, root.maximumSourceSize),
                                       Math.max(1, root.maximumSourceSize))
            layer.smooth: true
            layer.effect: MD.RoundClip {
                corners: MD.Util.corners(root.radius)
                size: Qt.vector2d(root.width, root.height)
            }
        }
    }

    Loader {
        id: m_animated_loader

        anchors.fill: parent
        // A ready overlay survives the current flick only while its delegate
        // still represents the same model.  It is paused, not redrawn; newly
        // entered or pooled cards cannot create a decoder until they settle.
        active: root._showAnimated || root._retainLoadedAnimation
        // Cold delegates must construct their decoder in this event turn. An
        // asynchronous Loader can be starved by rapid GridView reuse, leaving
        // dozens of cards white even though image decoding itself is async.
        asynchronous: !root._coldPosterFallback
        sourceComponent: m_animated_image_component
        onActiveChanged: {
            if (!active)
                root._loadedAnimationSource = "";
        }
    }
}
