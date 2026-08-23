pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtCore
import QtQuick
import QtQml
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Templates as T

import Qcm.Material as MD
import waywallen.ui as W

MD.ApplicationWindow {
    id: win
    MD.MProp.size.width: width
    MD.MProp.backgroundColor: W.App.frostedGlassAvailable ? "transparent" : W.Global.cupertinoCanvas
    MD.MProp.textColor: MD.MProp.color.on_surface

    color: "transparent"
    background: W.CupertinoSurface {
        // Keep the window backing clear on KWin so the independently tinted
        // sidebar and title bar can reveal its native blur.  The surface
        // automatically turns opaque white on compositors without blur.
        frosted: W.App.frostedGlassAvailable
        surfaceColor: W.Global.cupertinoCanvas
        glassOpacity: 0.0
        cornerRadius: 0
        borderOpacity: 0
        elevation: MD.Token.elevation.level0
    }
    visible: true
    height: 632
    width: 948
    title: "waywallen"

    readonly property alias popupPresenter: m_popup_presenter
    property var changelogPresentation: null
    property var pluginsPresentation: null
    property var settingsPresentation: null
    property var aboutPresentation: null
    // PageContainer starts with an empty placeholder and asynchronously
    // replaces it with the first real page.  Qcm normally applies its
    // replace transition to that operation, including a 0.92 -> 1.0 scale
    // animation which makes every wallpaper card appear to fly in.  Keep the
    // transition disabled until the first cached page has been installed;
    // later navigation retains Qcm's normal motion.
    property bool contentPageTransitionsEnabled: false

    function noteWindowResize() {
        if (!visible)
            return;
        W.Global.windowResizing = true;
        windowResizeSettleTimer.restart();
    }

    onWidthChanged: noteWindowResize()
    onHeightChanged: noteWindowResize()

    Timer {
        id: windowResizeSettleTimer

        interval: 96
        repeat: false
        onTriggered: W.Global.windowResizing = false
    }

    function presentPopup(source, properties) {
        const presentation = m_popup_presenter.present(source, properties || {});
        presentation.failed.connect(presentation, function (error) {
            W.Global.toastError(error);
        });
        if (presentation.status === MD.PopupPresentation.Error)
            W.Global.toastError(presentation.errorString);
        return presentation;
    }

    function showChangelog() {
        if (changelogPresentation?.active)
            return;
        changelogPresentation = presentPopup(changelogDialogComponent, {
            source: "qrc:/waywallen/ui/assets/waywallen-ui.releases.xml",
            title: qsTr("Changelog")
        });
    }

    function showPlugins() {
        if (pluginsPresentation?.active)
            return;
        pluginsPresentation = presentPopup('waywallen.ui/PagePopup', {
            source: 'waywallen.ui/PluginManagePage'
        });
    }

    function showSettings() {
        if (settingsPresentation?.active)
            return;
        settingsPresentation = presentPopup('waywallen.ui/PagePopup', {
            source: 'waywallen.ui/SettingsPage'
        });
    }

    function showAbout() {
        if (aboutPresentation?.active)
            return;
        aboutPresentation = presentPopup('waywallen.ui/PagePopup', {
            source: 'waywallen.ui/AboutPage'
        });
    }

    MD.PopupPresenter {
        id: m_popup_presenter
        host: win.contentItem
    }

    Component {
        id: changelogDialogComponent

        MD.ChangelogDialog {
            mdState.backgroundColor: W.Global.cupertinoCard
            mdState.elevation: MD.Token.elevation.level2
            background: W.CupertinoSurface {
                frosted: W.App.frostedGlassAvailable
                surfaceColor: W.Global.cupertinoCard
                glassOpacity: 0.98
                cornerRadius: 18
                borderOpacity: 0.10
                elevation: MD.Token.elevation.level2
            }
        }
    }

    // Persist the window size across runs. Wayland doesn't let clients
    // restore their own position, so only width/height are stored.
    Settings {
        category: "window"
        property alias width: win.width
        property alias height: win.height
    }

    W.HealthQuery {
        id: healthQuery
    }

    W.GlobalPauseToggleQuery {
        id: globalPauseToggleQuery
        onToggled: paused => W.Action.toast(paused ? qsTr("Paused") : qsTr("Resumed"))
    }

    Shortcut {
        sequence: "Ctrl+P"
        context: Qt.ApplicationShortcut
        enabled: W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready && !globalPauseToggleQuery.querying
        onActivated: globalPauseToggleQuery.reload()
    }

    Connections {
        target: W.Notify
        function onDaemonReady() {
            healthQuery.reload();
        }
    }

    property int currentPage: 0

    readonly property bool isCompact: MD.MProp.size.isCompact
    // In compact mode the glass field is intentionally taller than the
    // navigation controls and is anchored to the bottom edge.  The controls
    // retain BarItem's natural 56 px row height: stretching BarItem makes its
    // fixed-height selected indicator drift above its centred icon and label.
    readonly property real compactNavigationHeight: 88
    readonly property real compactNavigationRowHeight: 56
    readonly property real compactNavigationInset: isCompact ? compactNavigationHeight : 0
    readonly property real sidebarRequestedWidth: isCompact ? 0
                                                           : (W.Global.sidebarAutoExpand ? 240 : 76)
    // The live page is laid out at its final width once per sidebar change.
    // A clipped viewport then moves the existing scene while the sidebar
    // animates. This gives the desktop its complete, synchronous transition
    // without forcing every GridView delegate to reflow on every frame.
    property real sidebarLayoutWidth: 0
    property real sidebarVisualWidth: 0
    property bool sidebarInitialized: false
    property bool sidebarTransitionActive: false
    property bool sidebarImmediateGeometry: false
    property bool sidebarStateCommitInProgress: false
    property bool sidebarSnapshotPending: false
    property bool sidebarSnapshotImmediate: false
    property bool sidebarTransitionExpanded: true
    property int sidebarTransitionToken: 0
    property real sidebarSnapshotWidth: 0
    property real sidebarSnapshotHeight: 0
    property var sidebarSnapshotResult: null

    Behavior on sidebarVisualWidth {
        enabled: win.sidebarInitialized && !win.sidebarImmediateGeometry

        NumberAnimation {
            id: sidebarWidthAnimation

            duration: 220
            easing.type: Easing.OutCubic
            onRunningChanged: {
                if (!running && win.sidebarTransitionActive
                        && !win.sidebarSnapshotPending)
                    Qt.callLater(win.finishSidebarTransition);
            }
        }
    }

    onSidebarRequestedWidthChanged: {
        if (!sidebarInitialized || sidebarStateCommitInProgress)
            return;

        // The primary control is disabled while a transition is active. If
        // the stored setting is nevertheless changed externally, prefer a
        // clean settled shell over mixing two incompatible snapshots.
        if (sidebarTransitionActive) {
            // A state commit made by applySidebarTransition can reach this
            // binding after the synchronous assignment guard has unwound.
            // It is still our own target, so retain the active snapshot.
            if (Math.abs(sidebarRequestedWidth
                         - (sidebarTransitionExpanded ? 240 : 76)) < 0.5)
                return;
            resetSidebarGeometry();
            return;
        }
        if (isCompact) {
            resetSidebarGeometry();
            return;
        }
        beginSidebarTransition(W.Global.sidebarAutoExpand);
    }

    onCompactNavigationInsetChanged: {
        W.Global.compactNavigationInset = compactNavigationInset;
    }

    onIsCompactChanged: {
        if (sidebarInitialized)
            resetSidebarGeometry();
    }

    function requestSidebarToggle() {
        if (sidebarTransitionActive || isCompact)
            return;
        beginSidebarTransition(!W.Global.sidebarAutoExpand);
    }

    function beginSidebarTransition(expanded) {
        if (!sidebarInitialized || isCompact) {
            if (W.Global.sidebarAutoExpand !== expanded) {
                sidebarStateCommitInProgress = true;
                W.Global.sidebarAutoExpand = expanded;
                sidebarStateCommitInProgress = false;
            }
            resetSidebarGeometry();
            return;
        }

        const targetWidth = expanded ? 240 : 76;
        if (sidebarTransitionActive)
            return;
        if (Math.abs(sidebarLayoutWidth - targetWidth) < 0.5
                && Math.abs(sidebarVisualWidth - targetWidth) < 0.5) {
            if (W.Global.sidebarAutoExpand !== expanded) {
                sidebarStateCommitInProgress = true;
                W.Global.sidebarAutoExpand = expanded;
                sidebarStateCommitInProgress = false;
            }
            return;
        }

        sidebarTransitionActive = true;
        sidebarTransitionExpanded = expanded;
        sidebarSnapshotPending = true;
        W.Global.sidebarAnimating = true;

        const token = ++sidebarTransitionToken;
        const captureWidth = Math.max(0, desktopContent.width);
        const captureHeight = Math.max(0, desktopContent.height);
        sidebarSnapshotWidth = captureWidth;
        sidebarSnapshotHeight = captureHeight;

        if (captureWidth < 1 || captureHeight < 1 || !desktopContent.visible) {
            sidebarSnapshotPending = false;
            applySidebarTransition(expanded);
            return;
        }

        sidebarCaptureFallback.restart();
        try {
            desktopContent.grabToImage(function(result) {
                if (token !== win.sidebarTransitionToken
                        || !win.sidebarTransitionActive
                        || !win.sidebarSnapshotPending)
                    return;

                win.sidebarSnapshotPending = false;
                sidebarCaptureFallback.stop();
                if (result && result.url) {
                    win.sidebarSnapshotImmediate = true;
                    win.sidebarSnapshotResult = result;
                    contentTransitionSnapshot.source = result.url;
                    contentTransitionSnapshot.opacity = 1.0;
                    win.sidebarSnapshotImmediate = false;
                }
                win.applySidebarTransition(expanded);
            }, Qt.size(Math.ceil(captureWidth * Screen.devicePixelRatio),
                       Math.ceil(captureHeight * Screen.devicePixelRatio)));
        } catch (error) {
            sidebarSnapshotPending = false;
            sidebarCaptureFallback.stop();
            applySidebarTransition(expanded);
        }
    }

    function applySidebarTransition(expanded) {
        if (!sidebarTransitionActive)
            return;

        sidebarSnapshotPending = false;
        sidebarCaptureFallback.stop();
        if (W.Global.sidebarAutoExpand !== expanded) {
            sidebarStateCommitInProgress = true;
            W.Global.sidebarAutoExpand = expanded;
            sidebarStateCommitInProgress = false;
        }

        sidebarLayoutWidth = expanded ? 240 : 76;
        sidebarVisualWidth = sidebarLayoutWidth;
        if (contentTransitionSnapshot.visible)
            sidebarSnapshotFadeTimer.restart();

        // Behaviors do not run when a resize has already settled the value.
        Qt.callLater(function() {
            if (win.sidebarTransitionActive && !sidebarWidthAnimation.running)
                win.finishSidebarTransition();
        });
    }

    function finishSidebarTransition() {
        if (!sidebarTransitionActive || sidebarSnapshotPending)
            return;

        sidebarSnapshotFadeTimer.stop();
        sidebarSnapshotImmediate = true;
        contentTransitionSnapshot.opacity = 0.0;
        contentTransitionSnapshot.source = "";
        sidebarSnapshotResult = null;
        sidebarSnapshotImmediate = false;
        sidebarTransitionActive = false;
        W.Global.sidebarAnimating = false;
    }

    function resetSidebarGeometry() {
        ++sidebarTransitionToken;
        sidebarCaptureFallback.stop();
        sidebarSnapshotFadeTimer.stop();
        sidebarSnapshotPending = false;
        sidebarSnapshotImmediate = true;
        contentTransitionSnapshot.opacity = 0.0;
        contentTransitionSnapshot.source = "";
        sidebarSnapshotResult = null;
        sidebarSnapshotImmediate = false;
        sidebarTransitionActive = false;
        W.Global.sidebarAnimating = false;

        sidebarImmediateGeometry = true;
        sidebarLayoutWidth = sidebarRequestedWidth;
        sidebarVisualWidth = sidebarRequestedWidth;
        sidebarImmediateGeometry = false;
    }

    readonly property var pageModel: [
        {
            icon: MD.Token.icon.wallpaper,
            name: qsTr("Wallpapers"),
            tint: "#5C8FD0"
        },
        {
            icon: MD.Token.icon.explore,
            name: qsTr("Discover"),
            tint: "#55A2A8"
        },
        {
            icon: MD.Token.icon.monitor,
            name: qsTr("Displays"),
            tint: "#8877C7"
        },
        {
            icon: MD.Token.icon.monitor_heart,
            name: qsTr("Status"),
            tint: "#D39458"
        }
    ]

    readonly property var pageComponents: ["qrc:/waywallen/ui/qml/page/WallpaperPage.qml", "qrc:/waywallen/ui/qml/page/DiscoverPage.qml", "qrc:/waywallen/ui/qml/page/DisplaysPage.qml", "qrc:/waywallen/ui/qml/page/StatusPage.qml"]

    readonly property var pageCacheable: [true, true, false, false]

    onCurrentPageChanged: {
        m_content.switchTo(pageComponents[currentPage], {}, pageCacheable[currentPage]);
    }

    Component.onCompleted: {
        // Set the initial shell geometry without playing a startup resize
        // animation. Future preference changes use the snapshot transition.
        sidebarImmediateGeometry = true;
        sidebarLayoutWidth = sidebarRequestedWidth;
        sidebarVisualWidth = sidebarRequestedWidth;
        sidebarImmediateGeometry = false;
        sidebarInitialized = true;
        W.Global.compactNavigationInset = compactNavigationInset;
        currentPageChanged();
        // Level-check for the case where the daemon is already Ready
        // before this window finishes constructing (UI launched
        // standalone against a running daemon, page reload, etc.)
        // — `daemonReady` is edge-triggered and won't fire then.
        if (W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready) {
            healthQuery.reload();
        }
        if (W.Global.recordOpenedVersion(Qt.application.version))
            Qt.callLater(win.showChangelog);
    }

    Component.onDestruction: {
        changelogPresentation?.cancel();
        W.Global.sidebarAnimating = false;
        W.Global.windowResizing = false;
        W.Global.compactNavigationInset = 0;
    }

    MD.SnakeView {
        id: m_snake
        parent: T.Overlay.overlay
        anchors.fill: parent
        anchors.leftMargin: 24
        anchors.rightMargin: 24
    }

    Connections {
        target: W.Action
        function onToast(text, duration, flags, action) {
            m_snake.show(text, duration, flags, action);
        }
    }

    Connections {
        target: W.App
        function onErrorOccurred(error) {
            W.Global.toastError(error);
        }
    }

    // Global daemon-event toasts. Notify mirrors `GlobalEvent` from the
    // daemon; library additions surface here so the toast fires no
    // matter which page triggered the add (manual vs auto-detect).
    Connections {
        target: W.Notify
        function onLibrariesAdded(paths) {
            const n = paths.length;
            W.Action.toast(qsTr("%n library(s) added", "", n));
        }
        function onDisplayConnectionFailed(clientName, clientProtocolVersion, errorCode, reason) {
            const who = clientName.length > 0 ? clientName : qsTr("Display client");
            W.Global.toastError(qsTr("%1 connection failed: %2").arg(who).arg(reason));
        }
        function onPluginRestartFailed(pluginId, error) {
            const who = pluginId.length > 0 ? pluginId : qsTr("Plugin");
            W.Action.toast(qsTr("%1 renderer restart failed: %2").arg(who).arg(error), 6000, 1, null);
        }
    }

    W.DaemonNotRunDialog {}
    W.QrLoginDialog {}

    // The desktop shell deliberately stays small: Qcm keeps ownership of
    // pages, controls and transitions while these surfaces provide a calmer,
    // desktop-oriented hierarchy around them.
    ColumnLayout {
        anchors.fill: parent
        // The glass panels share a single desktop window.  Leave no exposed
        // transparent gutters between them: their opaque white edges provide
        // the intended separation without showing the desktop through a seam.
        anchors.margins: 0
        spacing: 0

        Item {
            id: desktopShell

            Layout.fillWidth: true
            Layout.fillHeight: true

            Loader {
                id: m_drawer_loader

                x: 0
                y: 0
                width: active ? win.sidebarVisualWidth : 0
                height: parent.height
                active: !win.isCompact
                visible: active
                z: 2

                sourceComponent: W.CupertinoSidebar {
                    model: win.pageModel
                    currentIndex: win.currentPage
                    collapsed: !W.Global.sidebarAutoExpand
                    transitioning: win.sidebarTransitionActive
                    onPageSelected: index => win.currentPage = index
                    onSidebarToggleRequested: win.requestSidebarToggle()
                    onPluginsRequested: win.showPlugins()
                    onSettingsRequested: win.showSettings()
                    onAboutRequested: win.showAbout()
                }
            }

            // The only vertical seam in the desktop shell.  It is opaque so
            // wallpaper cannot show through where the two glass regions meet.
            Rectangle {
                x: win.isCompact ? 0 : win.sidebarVisualWidth
                y: 0
                width: win.isCompact ? 0 : 1
                height: parent.height
                visible: !win.isCompact
                color: W.Global.cupertinoSeam
                z: 3
            }

            // This viewport moves every frame, but its child keeps a stable
            // final layout width. `clip` is a scene-graph scissor operation,
            // so the page slides with the sidebar without a GridView relayout
            // or a full-window texture layer on each animation frame.
            Item {
                id: contentViewport

                x: win.isCompact ? 0 : win.sidebarVisualWidth + 1
                y: 0
                width: Math.max(0, desktopShell.width - x)
                height: parent.height
                clip: true
                enabled: !win.sidebarTransitionActive
                z: 0

                Timer {
                    id: sidebarCaptureFallback

                    interval: 120
                    repeat: false
                    onTriggered: {
                        if (!win.sidebarTransitionActive || !win.sidebarSnapshotPending)
                            return;
                        win.sidebarSnapshotPending = false;
                        win.applySidebarTransition(win.sidebarTransitionExpanded);
                    }
                }

                Timer {
                    id: sidebarSnapshotFadeTimer

                    // Leave the old, full-resolution page visible through
                    // the first part of the width transition, then reveal the
                    // once-relayouted live page before the animation settles.
                    interval: 126
                    repeat: false
                    onTriggered: {
                        if (win.sidebarTransitionActive)
                            contentTransitionSnapshot.opacity = 0.0;
                    }
                }

                Image {
                    id: contentTransitionSnapshot

                    x: 0
                    y: 0
                    width: win.sidebarSnapshotWidth
                    height: win.sidebarSnapshotHeight
                    visible: source.toString().length > 0 && opacity > 0
                    z: 1
                    fillMode: Image.Stretch
                    cache: false
                    smooth: true
                    mipmap: false

                    Behavior on opacity {
                        enabled: !win.sidebarSnapshotImmediate

                        NumberAnimation {
                            duration: 94
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                ColumnLayout {
                    id: desktopContent

                    // The content is reflowed once at its target width, then
                    // translated inside the moving clipped viewport.
                    x: Math.max(0, win.sidebarLayoutWidth
                                 + (win.isCompact ? 0 : 1) - contentViewport.x)
                    y: 0
                    width: Math.max(0, desktopShell.width - win.sidebarLayoutWidth
                                    - (win.isCompact ? 0 : 1))
                    height: parent.height
                    spacing: 0
                    z: 0

                W.CupertinoSurface {
                    id: m_page_surface

                    Layout.fillWidth: true
                    Layout.preferredHeight: win.isCompact ? 48 : 52
                    // The content title bar is a clean white structural
                    // surface.  The visual glass hierarchy belongs to the
                    // sidebar and to local scrolling toolbars, not here.
                    frosted: false
                    surfaceColor: W.Global.cupertinoCard
                    glassOpacity: 1.0
                    // KWin's LightlyShaders effect owns the window outline.
                    // Keep the app shell rectangular so it does not create a
                    // second, mismatched set of client-side rounded corners.
                    cornerRadius: 0
                    borderOpacity: 0
                    elevation: MD.Token.elevation.level0

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: win.isCompact ? 12 : 16
                        anchors.rightMargin: win.isCompact ? 8 : 10
                        spacing: 10

                        Rectangle {
                            Layout.preferredWidth: 28
                            Layout.preferredHeight: 28
                            radius: 8
                            color: Qt.rgba(MD.MProp.color.on_surface.r,
                                           MD.MProp.color.on_surface.g,
                                           MD.MProp.color.on_surface.b,
                                           0.06)
                            border.width: 1
                            border.color: Qt.rgba(W.Global.cupertinoBorder.r,
                                                  W.Global.cupertinoBorder.g,
                                                  W.Global.cupertinoBorder.b,
                                                  0.50)

                            MD.Icon {
                                anchors.centerIn: parent
                                name: win.pageModel[win.currentPage].icon
                                size: 18
                                fill: true
                                color: win.pageModel[win.currentPage].tint
                            }
                        }

                        MD.Label {
                            Layout.fillWidth: true
                            text: win.pageModel[win.currentPage].name
                            typescale: MD.Token.typescale.title_medium
                            font.weight: Font.DemiBold
                            color: MD.MProp.color.on_surface
                        }

                        MD.StandardIconButton {
                            Layout.preferredWidth: 36
                            Layout.preferredHeight: 36
                            icon.name: MD.Token.icon.settings
                            backgroundRadius: 10
                            onClicked: win.showSettings()
                        }
                    }
                }

                // The matching horizontal seam between title bar and page.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: win.isCompact ? 0 : 1
                    visible: !win.isCompact
                    color: W.Global.cupertinoSeam
                }

                W.CupertinoSurface {
                    id: m_content_surface

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 0
                    frosted: W.App.frostedGlassAvailable && !win.isCompact
                    surfaceColor: W.Global.cupertinoCanvas
                    glassOpacity: 0.99
                    cornerRadius: 0
                    borderOpacity: 0
                    elevation: MD.Token.elevation.level0
                    clip: true

                    MD.PageContainer {
                        id: m_content
                        anchors.fill: parent
                        clip: true
                        initialItem: Item {}

                        replaceEnter: MD.FadeInThroughMotion {
                            enabled: win.contentPageTransitionsEnabled
                        }
                        replaceExit: MD.FadeOutThroughMotion {
                            enabled: win.contentPageTransitionsEnabled
                        }

                        onCurrentKeyChanged: {
                            if (!win.contentPageTransitionsEnabled
                                    && currentKey.length > 0)
                                initialPageTransitionGuard.restart();
                        }

                        MD.MProp.page: m_page_ctx

                        MD.PageContext {
                            id: m_page_ctx
                            showHeader: false
                            backgroundRadius: 0
                            showBackground: false
                        }
                    }

                    Timer {
                        id: initialPageTransitionGuard

                        // Wait through the transition which would have been
                        // selected for the initial replacement before arming
                        // animations for user-initiated navigation.
                        interval: MD.Token.duration.medium2 + 1
                        repeat: false
                        onTriggered: win.contentPageTransitionsEnabled = true
                    }
                }
            }

            // Compact navigation is an overlay so the page keeps its full
            // height and can flow beneath a local, live backdrop material.
            // It samples PageContainer (a descendant sibling branch), never
            // itself, which avoids a texture feedback loop while retaining
            // native-quality foreground text and icons.
            Loader {
                id: m_bar_loader

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: active ? win.compactNavigationHeight : 0
                active: win.isCompact
                visible: active
                z: 20

                sourceComponent: W.CupertinoFrostedBar {
                    anchors.fill: parent
                    blurSource: m_content
                    // Map into PageContainer's own coordinate space.  The
                    // actual content surface begins below the structural title
                    // bar, so omitting m_content_surface's offset samples past
                    // the lower edge and exposes the opaque fallback there.
                    blurSourceRect: Qt.rect(m_bar_loader.x - contentViewport.x
                                            - desktopContent.x - m_content_surface.x - m_content.x,
                                            m_bar_loader.y - contentViewport.y
                                            - desktopContent.y - m_content_surface.y - m_content.y,
                                            m_bar_loader.width,
                                            m_bar_loader.height)
                    surfaceColor: W.Global.cupertinoCanvas
                    // This remains distinctly white in light mode while the
                    // live colour field underneath communicates depth.
                    materialTint: W.Global.cupertinoDark ? "#1E1E20" : "#F5F5F7"
                    glassOpacity: W.Global.cupertinoDark ? 0.52 : 0.55
                    blurContentOpacity: 0.92
                    blurRadius: 72
                    separatorAtTop: true
                    // The compact material uses a clean separator; a dark
                    // inner shadow at its upper edge reads as a stray seam.
                    edgeShadowEnabled: false

                    RowLayout {
                        id: compactNavigationRow

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        anchors.bottomMargin: 8
                        height: win.compactNavigationRowHeight
                        // Keep BarItem at the height for which its indicator,
                        // glyph and text baseline are designed.  The larger
                        // parent remains the full-width frosted material.

                        Repeater {
                            model: win.pageModel

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                required property var modelData
                                required property int index

                                MD.BarItem {
                                    anchors.fill: parent
                                    icon.name: parent.modelData.icon
                                    text: parent.modelData.name
                                    checked: win.currentPage === parent.index
                                    onClicked: win.currentPage = parent.index
                                }
                            }
                        }
                    }
                }
            }
            }
        }
    }
}
