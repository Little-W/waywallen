import QtQuick
import QtQuick.Window
import QtQuick.Effects

import waywallen.ui as W

// A local, same-window material bar. KWin's BlurBehind only samples content
// behind the client window, while this item samples the scrollable content
// below it. The material chain mirrors the useful parts of macOS visual
// effects: a live backdrop, a broad efficient blur, restrained colour tuning,
// then a translucent tint and a separated foreground layer.
Item {
    id: root

    property Item blurSource: null
    property rect blurSourceRect: Qt.rect(0, 0, width, height)
    property bool contentBlurEnabled: blurSource !== null
                                      && blurSource.width > 0
                                      && blurSource.height > 0

    // `surfaceColor` remains the compatibility/fallback surface. Keeping tint
    // separate lets callers retain their existing palette while still choosing
    // a distinct material tint when necessary.
    property color surfaceColor: W.Global.cupertinoCard
    property color materialTint: W.Global.cupertinoDark ? "#1E1E20" : "#F5F5F7"
    property real glassOpacity: W.Global.cupertinoDark ? 0.55 : 0.68
    property real blurContentOpacity: 0.76

    // `blurRadius` is expressed in final screen pixels. MultiEffect's
    // `blurMax` is also measured in the final item's pixels, independently of
    // ShaderEffectSource.textureSize. Do not scale it by blurRenderScale: that
    // would silently turn a 72 px material blur into roughly 25 px.
    property real blurRadius: 72
    readonly property int effectiveBlurRadius: Math.round(Math.max(20,
                                                                     Math.min(72,
                                                                              blurRadius)))
    readonly property int shaderBlurRadius: Math.max(2, effectiveBlurRadius)
    property real blurAmount: 1.0
    // These aliases were part of the old Gaussian component API. Preserve them
    // for callers compiled against it; MultiEffect does not use kernels or
    // deviations directly.
    property int blurSamples: 0
    property real blurDeviation: 0

    // Qt Quick MultiEffect expresses these as deltas around the neutral 0.0.
    // The resulting saturation is approximately 1.24x in light mode and
    // 1.14x in dark mode, with just enough lift for colourful backdrops.
    property real materialSaturation: W.Global.cupertinoDark ? 0.14 : 0.24
    property real materialBrightness: W.Global.cupertinoDark ? -0.015 : 0.018
    property real materialContrast: W.Global.cupertinoDark ? 0.035 : 0.055
    property real materialColorization: W.Global.cupertinoDark ? 0.025 : 0.04
    property color materialColorizationColor: materialTint

    // The default is a top bar: its separator and internal shadow sit along
    // the lower edge. Set separatorAtTop for a compact bottom bar so it can
    // share the exact same live material while its edge faces upward.
    property bool separatorAtTop: false
    property real borderOpacity: W.Global.cupertinoDark ? 0.80 : 0.32
    property color materialBorderColor: W.Global.cupertinoDark
                                        ? Qt.rgba(1.0, 1.0, 1.0, 0.26)
                                        : Qt.rgba(1.0, 1.0, 1.0, 0.72)
    property bool edgeShadowEnabled: true
    property real edgeShadowOpacity: W.Global.cupertinoDark ? 0.30 : 0.12
    property int edgeShadowSize: 8
    property color edgeShadowColor: "black"

    // The backdrop itself is sampled at reduced resolution. Only this already
    // diffuse intermediate texture is downsampled; live wallpaper cards,
    // preview images, text and controls continue rendering at native quality.
    // The material is deliberately rendered below native screen resolution:
    // it is already diffuse and sits below the foreground controls, so this
    // saves fill-rate while preserving the apparent 72 px blur radius.
    property real blurRenderScale: 0.35
    readonly property int blurVerticalOverscan: effectiveBlurRadius + 8
    // A top bar needs source pixels below it, while a bottom bar needs source
    // pixels above it. Sampling only that useful guard band prevents an
    // out-of-bounds transparent strip from diluting the compact material.
    readonly property int snapshotY: separatorAtTop ? -blurVerticalOverscan : 0
    readonly property int snapshotHeight: height + blurVerticalOverscan

    default property alias content: contentLayer.data

    clip: true

    ShaderEffectSource {
        id: sourceSnapshot

        x: 0
        y: root.snapshotY
        width: parent.width
        height: root.snapshotHeight
        sourceItem: root.blurSource
        sourceRect: Qt.rect(root.blurSourceRect.x,
                            root.separatorAtTop
                                ? root.blurSourceRect.y - root.blurVerticalOverscan
                                : root.blurSourceRect.y,
                            width,
                            height)
        textureSize: Qt.size(Math.max(1, Math.ceil(width * Screen.devicePixelRatio
                                                    * root.blurRenderScale)),
                             Math.max(1, Math.ceil(height * Screen.devicePixelRatio
                                                     * root.blurRenderScale)))
        // This must stay live: scroll content should flow under both top and
        // bottom material bars rather than freezing at a timer cadence.
        live: root.visible && root.contentBlurEnabled
        hideSource: false
        recursive: false
        // Keep the FBO item in the scene graph. The opaque backing above it
        // prevents this raw snapshot from ever being shown, while avoiding a
        // compositor-dependent path where an invisible effect source does not
        // continuously produce a texture for MultiEffect.
        visible: root.contentBlurEnabled
        smooth: true
    }

    // Prevent sharp content below the overlay leaking around the sampled
    // backdrop. The processed source is subsequently drawn above this base.
    Rectangle {
        anchors.fill: parent
        z: 1
        color: root.surfaceColor
    }

    Item {
        id: materialViewport

        anchors.fill: parent
        z: 2
        clip: true

        MultiEffect {
            x: sourceSnapshot.x
            y: sourceSnapshot.y
            width: sourceSnapshot.width
            height: sourceSnapshot.height
            visible: root.contentBlurEnabled
            source: sourceSnapshot
            // Overscan and materialViewport clip the field explicitly. This
            // avoids MultiEffect allocating automatic padding around a narrow
            // toolbar while still giving the blur valid pixels at its edge.
            autoPaddingEnabled: false
            blurEnabled: true
            blur: root.blurAmount
            blurMax: root.shaderBlurRadius
            // blurMax already expresses the requested visual radius.  Keeping
            // the multiplier neutral prevents a nominal 72 px blur from
            // silently expanding to twice that radius.
            blurMultiplier: 0.0
            saturation: root.materialSaturation
            brightness: root.materialBrightness
            contrast: root.materialContrast
            colorization: root.materialColorization
            colorizationColor: root.materialColorizationColor
            opacity: root.blurContentOpacity
        }
    }

    // This is intentionally applied after backdrop colour tuning. A white
    // light-mode tint or charcoal dark-mode tint makes the material read as a
    // surface rather than the familiar "one blurred layer" appearance.
    Rectangle {
        anchors.fill: parent
        z: 3
        color: Qt.rgba(root.materialTint.r,
                       root.materialTint.g,
                       root.materialTint.b,
                       root.contentBlurEnabled ? root.glassOpacity : 1.0)
    }

    // A small internal shadow is more reliable than an external effect shadow
    // here: the bar is deliberately clipped so sampled pixels cannot bleed
    // into the rest of the page. Flip it together with the separator for a
    // bottom navigation bar.
    Rectangle {
        id: materialEdgeShadow

        anchors.left: parent.left
        anchors.right: parent.right
        y: root.separatorAtTop ? 0 : parent.height - height
        height: Math.min(parent.height, root.edgeShadowSize)
        visible: root.edgeShadowEnabled && root.contentBlurEnabled
        z: 4
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: root.separatorAtTop
                    ? Qt.rgba(root.edgeShadowColor.r,
                              root.edgeShadowColor.g,
                              root.edgeShadowColor.b,
                              root.edgeShadowOpacity)
                    : "transparent"
            }
            GradientStop {
                position: 1.0
                color: root.separatorAtTop
                    ? "transparent"
                    : Qt.rgba(root.edgeShadowColor.r,
                              root.edgeShadowColor.g,
                              root.edgeShadowColor.b,
                              root.edgeShadowOpacity)
            }
        }
    }

    Item {
        id: contentLayer

        anchors.fill: parent
        z: 5
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        y: root.separatorAtTop ? 0 : parent.height - height
        height: 1
        color: root.materialBorderColor
        opacity: root.borderOpacity
        z: 6
    }
}
