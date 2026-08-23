pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import QtCore
import Qcm.Material as MD
import waywallen.ui as W

W.CupertinoPage {
    id: root
    showBackground: false
    padding: MD.MProp.size.isCompact ? 0 : 12
    // Keep the live toolbar flush with the structural title bar in desktop
    // mode; a transparent outer padding strip reads as a visible seam.
    topPadding: 0
    // Meet the sidebar separator directly. The inherited desktop padding is
    // still used on the other edges, but must not create a white channel to
    // the left of the frosted toolbar.
    leftPadding: 0
    rightPadding: 0

    property bool detailOpen: false
    // Keep the selected row alive until the close animation completes. This
    // mirrors WallpaperPage and prevents the panel content disappearing
    // before its surface has slid out.
    readonly property var detailRow: detailStore.item
    property bool detailGridLayoutOpen: false
    property bool smoothDetailFocusPending: false
    property bool detailCloseAnchorActive: false
    property real detailPanelProgress: detailOpen ? 1.0 : 0.0
    readonly property bool detailLayoutFocusActive: detailRow !== null
                                                    && (detailPanelProgress > 0.001
                                                        || detailPanelAnimation.running)

    Behavior on detailPanelProgress {
        NumberAnimation {
            id: detailPanelAnimation

            duration: 220
            easing.type: root.detailOpen ? Easing.OutCubic : Easing.InCubic
            onRunningChanged: {
                if (running) {
                    W.Global.contentGeometryAnimating = true;
                    m_grid.previewAnimationsSettled = false;
                } else {
                    W.Global.contentGeometryAnimating = false;
                    discoverPreviewAnimationSettleTimer.restart();
                    if (root.detailPanelProgress <= 0.001 && !root.detailOpen) {
                        root.detailCloseAnchorActive = false;
                        detailsQuery.itemId = "";
                        detailStore.item = null;
                    }
                    root.scheduleCurrentItemFocus();
                }
            }
        }
    }

    onDetailOpenChanged: {
        detailCloseAnchorActive = !detailOpen && m_grid
                                  && m_grid.currentIndex >= 0;
        if (m_grid)
            m_grid.beginDetailLayout(detailOpen);
        else
            detailGridLayoutOpen = detailOpen;
        root.scheduleCurrentItemFocus();
    }

    function scheduleCurrentItemFocus() {
        if (!m_grid || m_grid.currentIndex < 0)
            return;
        if (root.detailCloseAnchorActive)
            return;
        if (!detailPanelAnimation.running)
            discoverDetailFocusTimer.restart();
    }

    function focusCurrentItem() {
        if (!m_grid || m_grid.currentIndex < 0 || !root.detailLayoutFocusActive)
            return;
        m_grid.forceLayout();
        if (root.smoothDetailFocusPending && m_grid.currentItem) {
            root.smoothDetailFocusPending = false;
            const item = m_grid.currentItem;
            const usableCenter = (m_grid.topMargin + m_grid.height
                                  - m_grid.bottomMargin) / 2;
            discoverDesktopWheel.scrollTo(item.y + item.height / 2
                                          - usableCenter);
            return;
        }
        root.smoothDetailFocusPending = false;
        m_grid.positionViewAtIndex(m_grid.currentIndex, GridView.Center);
    }

    property string sourceId: ""
    property var sortOptions: []
    property int sortIndex: 0
    property var discoverTweakSheet: null
    property var infoPresentation: null
    property var managePresentation: null
    readonly property var discoverTweakState: discoverTweakStateLoader.item
    readonly property bool previewPageActive: T.StackView.status === T.StackView.Active

    readonly property Settings discoverLayoutInheritanceSettings: Settings {
        category: "DiscoverLayoutInheritance"
        property string migratedSourcesJson: "[]"
        property string customizedSourcesJson: "[]"
    }

    Loader {
        id: discoverTweakStateLoader
        active: true
        property string settingsCategory: "DiscoverView"

        sourceComponent: Component {
            W.TweakState {
                settingsCategory: discoverTweakStateLoader.settingsCategory
            }
        }

        onLoaded: root.applyDiscoverLayoutBaseline(root.sourceId)
    }

    Connections {
        target: root.discoverTweakState
        function onUserChanged() {
            root.markDiscoverLayoutCustomized(root.sourceId);
        }
    }

    Connections {
        target: W.Global
        function onWallpaperGridTweakReadyChanged() {
            root.applyDiscoverLayoutBaseline(root.sourceId);
        }
        function onWallpaperGridItemSizeChanged() {
            root.applyDiscoverLayoutBaseline(root.sourceId);
        }
        function onWallpaperGridItemAspectRatioChanged() {
            root.applyDiscoverLayoutBaseline(root.sourceId);
        }
        function onWallpaperGridLayoutModeChanged() {
            root.applyDiscoverLayoutBaseline(root.sourceId);
        }
    }

    function layoutSourceList(json) {
        try {
            const value = JSON.parse(json);
            return Array.isArray(value) ? value.map(String) : [];
        } catch (error) {
            return [];
        }
    }

    function layoutSourceRecorded(json, id) {
        return layoutSourceList(json).indexOf(String(id)) >= 0;
    }

    function recordLayoutSource(settingName, id) {
        const source = String(id ?? "");
        if (source.length === 0)
            return;
        const current = root.discoverLayoutInheritanceSettings[settingName];
        const values = layoutSourceList(current);
        if (values.indexOf(source) >= 0)
            return;
        values.push(source);
        root.discoverLayoutInheritanceSettings[settingName] = JSON.stringify(values);
    }

    function markDiscoverLayoutCustomized(id) {
        recordLayoutSource("migratedSourcesJson", id);
        recordLayoutSource("customizedSourcesJson", id);
    }

    function applyDiscoverLayoutBaseline(id) {
        const source = String(id ?? "");
        const tweak = root.discoverTweakState;
        if (source.length === 0 || !tweak || !W.Global.wallpaperGridTweakReady)
            return;

        const state = root.discoverLayoutInheritanceSettings;
        let customized = layoutSourceRecorded(state.customizedSourcesJson,
                                               source);
        if (!layoutSourceRecorded(state.migratedSourcesJson, source)) {
            // Before this marker existed, 160/1/fill was the normalized
            // Discover default. Values distinguishable from it are retained as
            // legacy user choices; only the old default adopts Wallpapers.
            customized = tweak.itemSize !== 160
                         || Math.abs(tweak.itemAspectRatio - 1) >= 0.001
                         || tweak.layoutMode !== tweak.layoutFillCell;
            recordLayoutSource("migratedSourcesJson", source);
            if (customized)
                recordLayoutSource("customizedSourcesJson", source);
        }
        if (!customized) {
            tweak.applyLayout(W.Global.wallpaperGridItemSize,
                              W.Global.wallpaperGridItemAspectRatio,
                              W.Global.wallpaperGridLayoutMode);
        }
    }

    W.DiscoverState {
        id: discoverState
    }

    W.RemoteStoreItem {
        id: detailStore
    }

    function sourceInfo(id) {
        for (const s of availabilityQuery.sources) {
            if (s.id === id)
                return s;
        }
        return null;
    }

    function sourceName(id) {
        const s = sourceInfo(id);
        return s ? (s.displayName && s.displayName.length > 0 ? s.displayName : s.name) : "";
    }

    function sourceFilters(id) {
        const s = sourceInfo(id);
        return s && s.filters ? s.filters : [];
    }

    function sourceCapability(id) {
        const s = sourceInfo(id);
        return s ? Number(s.remoteCapability ?? 0) : 0;
    }

    function sourceRemoteHint(id) {
        const s = sourceInfo(id);
        return s ? String(s.remoteHint ?? "") : "";
    }

    function sameList(a, b) {
        const left = a ?? [];
        const right = b ?? [];
        if (left.length !== right.length)
            return false;
        for (let i = 0; i < left.length; ++i) {
            if (left[i] !== right[i])
                return false;
        }
        return true;
    }

    function pruneTags(tags, filters) {
        const allowed = {};
        for (const filter of filters ?? []) {
            for (const value of filter.values ?? [])
                allowed[String(value)] = true;
        }
        let out = [];
        for (const tag of tags ?? []) {
            const value = String(tag);
            if (allowed[value] === true)
                out.push(value);
        }
        return out;
    }

    function sortLabel() {
        if (sortOptions.length === 0)
            return qsTr("Sort");
        return sortOptions[Math.max(0, Math.min(sortIndex, sortOptions.length - 1))].label;
    }

    function tweakSettingsCategory(id) {
        const source = String(id ?? "");
        return source.length > 0 ? "DiscoverView/" + encodeURIComponent(source) + "/Tweak" : "DiscoverView";
    }

    function loadDiscoverTweakState(id) {
        const category = tweakSettingsCategory(id);
        if (discoverTweakStateLoader.item && discoverTweakStateLoader.settingsCategory === category)
            return;
        if (isSheetActive(discoverTweakSheet))
            discoverTweakSheet.close();
        discoverTweakStateLoader.active = false;
        discoverTweakStateLoader.settingsCategory = category;
        discoverTweakStateLoader.active = true;
    }

    function setSource(id) {
        const s = sourceInfo(id);
        if (!s)
            return;
        const sourceChanged = sourceId !== id;
        const currentSortKey = searchQuery.sortKey;
        sourceId = id;
        discoverState.setSelectedSourceId(id);
        if (sourceChanged)
            loadDiscoverTweakState(id);
        sortOptions = s.sorts ?? [];
        sortIndex = 0;
        if (!sourceChanged && currentSortKey.length > 0) {
            for (let i = 0; i < sortOptions.length; ++i) {
                if (sortOptions[i].key === currentSortKey) {
                    sortIndex = i;
                    break;
                }
            }
        }
        const canBrowse = currentSourceLoginAction() === null;
        searchQuery.browsingEnabled = canBrowse;
        const candidateTags = sourceChanged ? discoverState.filterValuesFor(id) : searchQuery.tags;
        const nextTags = pruneTags(candidateTags, s.filters ?? []);
        if (!sameList(searchQuery.tags, nextTags))
            searchQuery.tags = nextTags;
        discoverState.setFilterValuesFor(id, nextTags);
        searchQuery.sourceId = id;
        detailsQuery.sourceId = id;
        searchQuery.sortKey = sortOptions.length > 0 ? sortOptions[sortIndex].key : "";
        if (sourceChanged || !canBrowse) {
            root.closeDetail();
        }
    }

    function pickSort(idx) {
        if (idx < 0 || idx >= sortOptions.length)
            return;
        sortIndex = idx;
        searchQuery.sortKey = sortOptions[idx].key;
    }

    function selectItem(index) {
        const detailWasOpen = root.detailOpen;
        m_grid.currentIndex = index;
        root.smoothDetailFocusPending = detailWasOpen;
        detailStore.item = searchQuery.model.item(index);
        detailOpen = true;
        detailsQuery.sourceId = detailRow.sourceId;
        detailsQuery.itemId = detailRow.itemId;
        if (root.sourceCapability(detailRow.sourceId) === 2)
            refreshDetailSubscription();
        root.scheduleCurrentItemFocus();
    }

    function closeDetail() {
        detailOpen = false;
        if (!detailPanelAnimation.running && detailPanelProgress <= 0.001) {
            detailsQuery.itemId = "";
            detailStore.item = null;
        }
    }

    function openInfo() {
        if (!root.detailRow)
            return;
        if (root.infoPresentation?.active)
            return;
        root.infoPresentation = root.Window.window.presentPopup('waywallen.ui/PagePopup', {
            source: 'waywallen.ui/RemoteInfoPage',
            props: {
                itemStore: detailStore,
                details: detailsQuery,
                sourceName: root.sourceName(root.detailRow.sourceId),
                remoteCapability: root.sourceCapability(root.detailRow.sourceId),
                remoteHint: root.sourceRemoteHint(root.detailRow.sourceId)
            }
        });
    }

    function setDetailSubscription(subscribed) {
        if (!root.detailRow)
            return;
        const sourceId = root.detailRow.sourceId;
        const itemId = root.detailRow.itemId;
        subscriptionQuery.setSubscribed(sourceId, itemId, subscribed);
    }

    function refreshDetailSubscription() {
        if (!root.detailRow || root.sourceCapability(root.detailRow.sourceId) !== 2)
            return;
        if (root.currentSourceLoginAction() !== null)
            return;
        subscriptionQuery.refresh(root.detailRow.sourceId, root.detailRow.itemId);
    }

    function isSheetActive(sheet) {
        return !!sheet && (sheet.status === MD.PopupPresentation.Opening || sheet.status === MD.PopupPresentation.Open);
    }

    function ensureDiscoverTweakSheet() {
        if (!root.discoverTweakState)
            return null;
        if (root.discoverTweakSheet?.active)
            return root.discoverTweakSheet;

        const sheet = root.Window.window.presentPopup(discoverTweakSheetComponent);
        if (sheet.active) {
            root.discoverTweakSheet = sheet;
            sheet.activeChanged.connect(sheet, function () {
                if (!sheet.active)
                    root.releaseDiscoverTweakSheet(sheet);
            });
        }
        return sheet;
    }

    function releaseDiscoverTweakSheet(sheet) {
        if (root.discoverTweakSheet === sheet)
            root.discoverTweakSheet = null;
    }

    function toggleDiscoverTweakSheet() {
        if (root.discoverTweakSheet?.active) {
            root.discoverTweakSheet.close();
            return;
        }
        root.ensureDiscoverTweakSheet();
    }

    MD.Action {
        id: manageAction
        icon.name: MD.Token.icon.manage_accounts
        text: qsTr("Manage")
        enabled: root.currentSourceConfig() !== null
        onTriggered: root.openRemoteManagement()
    }

    MD.Action {
        id: tweakAction
        text: qsTr("Tweak")
        icon.name: MD.Token.icon.tune
        checked: root.isSheetActive(root.discoverTweakSheet)
        onTriggered: root.toggleDiscoverTweakSheet()
    }

    MD.Action {
        id: filterAction
        icon.name: MD.Token.icon.filter_list
        text: qsTr("Filters")
        enabled: m_filter_dialog.filters.length > 0
        checked: searchQuery.tags.length > 0
        onTriggered: m_filter_dialog.open()
    }

    MD.Action {
        id: refreshAction
        icon.name: MD.Token.icon.refresh
        text: qsTr("Refresh")
        enabled: searchQuery.browsingEnabled && !searchQuery.querying
        onTriggered: searchQuery.reload()
    }

    W.RemoteAvailabilityQuery {
        id: availabilityQuery
        onSourcesChanged: {
            if (sources.length === 0) {
                searchQuery.browsingEnabled = false;
                return;
            }
            let nextSourceId = root.sourceId;
            if (!root.sourceInfo(nextSourceId)) {
                const savedSourceId = discoverState.selectedSourceId();
                if (root.sourceInfo(savedSourceId))
                    nextSourceId = savedSourceId;
                else if (root.sourceInfo(defaultSourceId))
                    nextSourceId = defaultSourceId;
                else
                    nextSourceId = sources[0].id;
            }
            root.setSource(nextSourceId);
            root.refreshDetailSubscription();
        }
    }

    function currentSourceConfig() {
        const id = root.sourceId;
        const list = availabilityQuery.sources || [];
        for (let i = 0; i < list.length; ++i) {
            if (list[i].id === id)
                return list[i];
        }
        return null;
    }

    function currentSourceLoginAction() {
        const c = root.currentSourceConfig();
        const actions = c && c.actions ? c.actions : [];
        for (let i = 0; i < actions.length; ++i) {
            const kind = Number(actions[i].kind);
            if ((kind === 2 || kind === 3) && actions[i].requiredForBrowsing === true && (actions[i].visible === undefined || actions[i].visible))
                return actions[i];
        }
        return null;
    }

    function openRemoteManagement() {
        const c = root.currentSourceConfig();
        if (!c)
            return;
        if (root.managePresentation?.active)
            return;
        root.managePresentation = root.Window.window.presentPopup('waywallen.ui/PagePopup', {
            source: 'waywallen.ui/RemoteManagePage',
            props: {
                sourceId: c.id,
                displayName: (c.displayName && c.displayName.length > 0) ? c.displayName : (c.name || c.id)
            }
        });
    }

    W.RemoteSearchQuery {
        id: searchQuery
    }

    W.RemoteFilterDialog {
        id: m_filter_dialog
        parent: T.Overlay.overlay
        anchors.centerIn: parent
        popupWindow: root.Window.window
        filters: root.sourceFilters(root.sourceId)
        selectedValues: searchQuery.tags
        onApply: function (values) {
            searchQuery.tags = values;
            discoverState.setFilterValuesFor(root.sourceId, values);
        }
    }

    W.RemoteDetailsQuery {
        id: detailsQuery
    }

    W.RemoteDownloadQuery {
        id: dlQuery
        function onRemoved(sourceId, id) {
            W.Action.toast(qsTr("Removed"));
        }
        function onRemoveFailed(sourceId, id, error) {
            W.Action.toast(qsTr("Remove failed: ") + error);
        }
        function onRejected(sourceId, id, error) {
            W.Action.toast(qsTr("Download rejected: ") + error);
        }
    }

    W.RemoteSubscriptionQuery {
        id: subscriptionQuery
        forwardError: false
    }

    Connections {
        target: subscriptionQuery
        function onStateLoaded(sourceId, id, state, error) {
            if (error.length > 0)
                W.Action.toast(qsTr("Couldn't load subscription status: ") + error);
        }
        function onSetFinished(sourceId, id, subscribed, accepted, error) {
            if (accepted) {
                const message = subscribed ? qsTr("Subscription request accepted") : qsTr("Unsubscribe request accepted");
                const hint = root.sourceRemoteHint(sourceId);
                W.Action.toast(hint.length > 0 ? message + "\n" + hint : message);
            } else {
                W.Action.toast(qsTr("Subscription update failed: ") + error);
            }
        }
    }

    Connections {
        target: W.Notify
        function onRemoteDownloadProgress(sourceId, id, state, error) {
            if (state === 5 && error.length > 0)
                W.Action.toast(qsTr("Download failed: ") + error);
        }
    }

    function reloadAll() {
        availabilityQuery.reload();
    }

    Connections {
        target: W.Notify
        function onDaemonReady() {
            root.reloadAll();
        }
        function onSettingsChanged() {
            availabilityQuery.reload();
        }
        function onPluginStateChanged() {
            availabilityQuery.reload();
        }
    }

    Component.onCompleted: {
        if (W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready)
            reloadAll();
    }
    Component.onDestruction: W.Global.contentGeometryAnimating = false

    contentItem: Item {
        id: discoverSplitView

        // Use the same direct-geometry master/detail reveal as WallpaperPage.
        // Animating RowLayout preferred sizes triggers multiple layout passes
        // per frame and makes the grid change size before its topology does.
        readonly property real detailWidth: 280 * root.detailPanelProgress
        readonly property real detailGap: 12 * root.detailPanelProgress

        W.CupertinoPane {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.max(0, parent.width
                            - discoverSplitView.detailWidth
                            - discoverSplitView.detailGap)
            radius: root.MD.MProp.page.backgroundRadius
            padding: 0
            backgroundColor: W.Global.cupertinoCard
            showBackground: true

            contentItem: Item {
                id: discoverGridArea

                clip: true

                W.CupertinoFrostedBar {
                    id: discoverTopBar

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: discoverProgress.visible ? 60 : 52
                    z: 20
                    blurSource: m_grid
                    // Capture in the GridView viewport coordinate space.  Do
                    // not add contentY here: ShaderEffectSource renders the
                    // view itself, including its internal scroll transform.
                    // The explicit sibling/parent offsets keep the backdrop
                    // locked to this bar if either branch is later laid out
                    // with an offset.
                    blurSourceRect: Qt.rect(discoverTopBar.x
                                            - discoverGridViewport.x - m_grid.x,
                                            discoverTopBar.y
                                            - discoverGridViewport.y - m_grid.y,
                                            discoverTopBar.width,
                                            discoverTopBar.height)
                    surfaceColor: W.Global.cupertinoCard
                    glassOpacity: 0.60
                    // A dark 8 px internal shadow reads as a misplaced grey
                    // band below this otherwise light material header.
                    edgeShadowEnabled: false

                    RowLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        height: 52
                        spacing: 8

                    W.CupertinoEmbedChip {
                        id: sourceChip
                        visible: availabilityQuery.sources.length > 1
                        text: root.sourceName(root.sourceId)
                        trailingIconName: MD.Token.icon.arrow_drop_down
                        mdState.borderWidth: 1
                        onClicked: sourceMenu.open()

                        W.CupertinoMenu {
                            id: sourceMenu
                            parent: sourceChip
                            y: parent.height
                            model: availabilityQuery.sources
                            contentDelegate: MD.MenuItem {
                                required property var modelData
                                text: modelData.displayName && modelData.displayName.length > 0 ? modelData.displayName : modelData.name
                                icon.name: modelData.id === root.sourceId ? MD.Token.icon.check : ' '
                                onClicked: {
                                    root.setSource(modelData.id);
                                    sourceMenu.close();
                                }
                            }
                        }
                    }

                    W.CupertinoEmbedChip {
                        id: sortChip
                        visible: root.sortOptions.length > 0
                        text: root.sortLabel()
                        trailingIconName: MD.Token.icon.arrow_drop_down
                        mdState.borderWidth: 1
                        onClicked: sortMenu.open()

                        W.CupertinoMenu {
                            id: sortMenu
                            parent: sortChip
                            y: parent.height
                            model: root.sortOptions
                            contentDelegate: MD.MenuItem {
                                required property var modelData
                                required property int index
                                text: modelData.label
                                icon.name: index === root.sortIndex ? MD.Token.icon.check : ' '
                                onClicked: {
                                    root.pickSort(index);
                                    sortMenu.close();
                                }
                            }
                        }
                    }

                    W.SearchChip {
                        id: m_search_field
                        Layout.preferredWidth: 120
                        placeholderText: qsTr("Search")
                        onTextEdited: searchQuery.query = text
                    }

                    MD.ActionToolBar {
                        id: discoverActionToolBar

                        // Request the width needed by all icon delegates first.
                        // RowLayout may still shrink this item when the master
                        // pane is genuinely too narrow; only then does
                        // ActionToolBar move the trailing actions to overflow.
                        Layout.fillWidth: true
                        Layout.preferredWidth: maximumContentWidth
                        actions: [tweakAction, filterAction, manageAction,
                                  refreshAction]
                    }
                }

                    MD.LinearIndicator {
                        id: discoverProgress

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        anchors.bottomMargin: 4
                        visible: searchQuery.querying && searchQuery.model.count > 0
                        running: visible
                    }
                }

                Item {
                    id: discoverGridViewport

                    anchors.fill: parent

                    MD.VerticalGridView {
                        id: m_grid
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        // discoverGridViewport performs the animated clipping;
                        // keep GridView's own layout viewport at the final
                        // master/detail width throughout the transition.
                        clip: false
                        // Match the wallpaper library's native touchpad path.
                        // Qcm's touch-oriented synchronous drag turns the first
                        // pixel-delta sample into a jump.
                        synchronousDrag: false
                        pixelAligned: false
                        reuseItems: !(columnReflowActive
                                      || detailPanelAnimation.running)
                        // Preload just over one row.  Large display margins
                        // keep GIF delegates alive even though users cannot
                        // see them during a scroll.
                        cacheBuffer: columnReflowActive
                                     || detailPanelAnimation.running
                                     ? Math.max(height + cellHeight,
                                                Math.ceil(cellHeight * 1.25))
                                     : Math.max(96,
                                                Math.ceil(cellHeight * 1.25))
                        displayMarginBeginning: 0
                        displayMarginEnd: 0
                        currentIndex: -1
                        property bool previewAnimationsSettled: true
                        onContentYChanged: {
                            if (!moving && !flicking)
                                discoverBoundarySettleTimer.restart();
                        }
                        onMovementStarted: {
                            discoverDesktopWheel.cancel();
                            previewAnimationsSettled = false;
                            discoverPreviewAnimationSettleTimer.stop();
                        }
                        onMovementEnded: discoverPreviewAnimationSettleTimer.restart()
                        topMargin: discoverTopBar.height + 8
                        bottomMargin: Math.max(8, W.Global.compactNavigationInset)
                        leftMargin: 8
                        rightMargin: 8

                        W.DesktopWheelScroll {
                            id: discoverDesktopWheel

                            flickable: m_grid
                            onScrollingChanged: {
                                if (scrolling) {
                                    m_grid.previewAnimationsSettled = false;
                                    discoverPreviewAnimationSettleTimer.stop();
                                } else {
                                    discoverPreviewAnimationSettleTimer.restart();
                                }
                            }
                        }

                        // Keep the interactive scroll bar out of the compact
                        // navigation overlay while cards continue below the
                        // live frosted material.
                        T.ScrollBar.vertical: MD.ScrollBar {
                            id: discoverScrollBar
                            active: discoverDesktopWheel.scrolling
                                    || m_grid.moving || pressed
                            parent: discoverGridViewport
                            width: implicitWidth
                            x: Math.max(0, discoverGridViewport.width - width)
                            y: discoverTopBar.height + 8
                            height: Math.max(0,
                                             discoverGridViewport.height - y
                                             - W.Global.compactNavigationInset)
                            z: 21
                            onPressedChanged: {
                                if (pressed) {
                                    discoverDesktopWheel.cancel();
                                    m_grid.previewAnimationsSettled = false;
                                    discoverPreviewAnimationSettleTimer.stop();
                                } else if (!m_grid.moving && !m_grid.flicking) {
                                    discoverPreviewAnimationSettleTimer.restart();
                                }
                            }
                        }

                        // Match WallpaperPage's explicit master/detail layout:
                        // choose the destination topology once, while the pane
                        // merely clips the already-animating card surfaces.
                        visible: m_grid.count > 0 && _initialLayoutReady
                        readonly property real _targetViewportWidth: Math.max(
                            0,
                            discoverSplitView.width
                            - (root.detailGridLayoutOpen ? 292 : 0))
                        readonly property real _availableWidth: Math.max(
                            0,
                            _targetViewportWidth - leftMargin - rightMargin)
                        readonly property int _calculatedCols: Math.max(
                            1,
                            Math.floor(_availableWidth
                                       / root.discoverTweakState.itemSize))
                        property int _cols: 1
                        property bool _initialLayoutReady: false
                        property bool _columnLatchReady: false
                        property bool viewportResizeActive: false
                        property bool columnReflowActive: false
                        readonly property real _stretchedItemWidth: _availableWidth / _cols
                        readonly property bool _fillCell: root.discoverTweakState.layoutMode === root.discoverTweakState.layoutFillCell
                        readonly property real _displayItemWidth: _fillCell ? _stretchedItemWidth : Math.min(root.discoverTweakState.itemSize, _stretchedItemWidth)
                        readonly property real _displayItemHeight: _displayItemWidth / Math.max(root.discoverTweakState.itemAspectRatio, 0.1)
                        cellWidth: _stretchedItemWidth
                        cellHeight: _fillCell ? _displayItemHeight : root.discoverTweakState.itemHeight

                        function scheduleColumnSettle() {
                            if (!_columnLatchReady)
                                return;
                            viewportResizeActive = true;
                            discoverColumnSettleTimer.restart();
                        }

                        function forEachPreparedDelegate(callback) {
                            const children = contentItem?.children || [];
                            for (let i = 0; i < children.length; ++i) {
                                const delegate = children[i];
                                if (delegate
                                        && delegate.objectName
                                           === "discoverWallpaperCard")
                                    callback(delegate);
                            }
                        }

                        function prepareVisibleReflow() {
                            forEachPreparedDelegate(function (delegate) {
                                delegate.prepareReflow();
                            });
                        }

                        function startVisibleReflow() {
                            forEachPreparedDelegate(function (delegate) {
                                delegate.startPreparedReflow();
                            });
                        }

                        function beginDetailLayout(open) {
                            if (root.detailGridLayoutOpen === open)
                                return;

                            discoverColumnSettleTimer.stop();
                            discoverDetailContentYAnimation.stop();
                            viewportResizeActive = false;
                            if (!_initialLayoutReady) {
                                root.detailGridLayoutOpen = open;
                                _cols = _calculatedCols;
                                return;
                            }
                            const originalContentY = contentY;
                            columnReflowActive = false;
                            columnReflowActive = true;
                            prepareVisibleReflow();
                            root.detailGridLayoutOpen = open;
                            _cols = _calculatedCols;
                            if (currentIndex >= 0) {
                                discoverDesktopWheel.cancel();
                                forceLayout();
                                positionViewAtIndex(currentIndex,
                                                    GridView.Center);
                                const targetContentY = contentY;
                                contentY = originalContentY;
                                root.smoothDetailFocusPending = false;
                                discoverDetailContentYAnimation.from =
                                    originalContentY;
                                discoverDetailContentYAnimation.to =
                                    targetContentY;
                            }
                            forceLayout();
                            startVisibleReflow();
                            if (currentIndex >= 0
                                    && Math.abs(
                                        discoverDetailContentYAnimation.to
                                        - discoverDetailContentYAnimation.from)
                                       > 0.01)
                                discoverDetailContentYAnimation.restart();
                            discoverColumnReflowTimer.restart();
                        }

                        function applySettledColumns() {
                            viewportResizeActive = false;
                            const nextColumns = _calculatedCols;
                            if (nextColumns === _cols)
                                return;

                            columnReflowActive = true;
                            prepareVisibleReflow();
                            _cols = nextColumns;
                            forceLayout();
                            startVisibleReflow();
                            discoverColumnReflowTimer.restart();
                            if (root.detailLayoutFocusActive)
                                root.scheduleCurrentItemFocus();
                        }

                        on_AvailableWidthChanged: {
                            if (!_columnLatchReady) {
                                _cols = _calculatedCols;
                                discoverInitialColumnSettleTimer.restart();
                            } else {
                                scheduleColumnSettle();
                            }
                        }
                        Component.onCompleted: {
                            _cols = _calculatedCols;
                            discoverInitialColumnSettleTimer.restart();
                        }
                        onWidthChanged: {
                            if (root.detailLayoutFocusActive)
                                root.scheduleCurrentItemFocus();
                        }
                        onCellWidthChanged: {
                            if (root.detailLayoutFocusActive)
                                root.scheduleCurrentItemFocus();
                        }
                        onCellHeightChanged: {
                            if (root.detailLayoutFocusActive)
                                root.scheduleCurrentItemFocus();
                        }

                        model: searchQuery.model

                        delegate: RemoteCard {
                            remoteCapability: root.sourceCapability(root.sourceId)
                            current: index === m_grid.currentIndex
                            pageActive: root.previewPageActive
                            animationSettled: m_grid.previewAnimationsSettled
                            reflowTransitionActive: m_grid.columnReflowActive
                            reflowReverse: root.detailCloseAnchorActive
                                           && !root.detailOpen
                            itemWidth: m_grid._displayItemWidth
                            itemHeight: m_grid._displayItemHeight
                            onClicked: {
                                root.selectItem(index);
                            }
                        }

                        highlightFollowsCurrentItem: false
                        highlight: null
                    }

                    NumberAnimation {
                        id: discoverDetailContentYAnimation

                        target: m_grid
                        property: "contentY"
                        duration: 220
                        easing.type: root.detailOpen ? Easing.OutCubic
                                                     : Easing.InCubic
                    }

                    Timer {
                        id: discoverPreviewAnimationSettleTimer

                        interval: 140
                        repeat: false
                        onTriggered: {
                            if (!m_grid.moving && !m_grid.flicking)
                                m_grid.previewAnimationsSettled = true;
                        }
                    }

                    Timer {
                        id: discoverBoundarySettleTimer

                        interval: 180
                        repeat: false
                        onTriggered: {
                            if (!m_grid.moving && !m_grid.flicking)
                                m_grid.previewAnimationsSettled = true;
                        }
                    }

                    Timer {
                        id: discoverInitialColumnSettleTimer

                        interval: 72
                        repeat: false
                        onTriggered: {
                            m_grid._cols = m_grid._calculatedCols;
                            m_grid.forceLayout();
                            m_grid._columnLatchReady = true;
                            m_grid._initialLayoutReady = true;
                        }
                    }

                    Timer {
                        id: discoverColumnSettleTimer

                        interval: 72
                        repeat: false
                        onTriggered: m_grid.applySettledColumns()
                    }

                    Timer {
                        id: discoverColumnReflowTimer

                        interval: 220
                        repeat: false
                        onTriggered: m_grid.columnReflowActive = false
                    }

                    Timer {
                        id: discoverDetailFocusTimer

                        interval: 0
                        repeat: false
                        onTriggered: root.focusCurrentItem()
                    }

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 48, 420)
                        visible: m_grid.count === 0
                        spacing: 12

                        readonly property bool hasError: !searchQuery.querying && searchQuery.errorText.length > 0
                        readonly property var loginAction: root.currentSourceLoginAction()
                        readonly property bool needsLogin: loginAction !== null
                        readonly property string loginLabel: {
                            const label = loginAction ? String(loginAction.label ?? "").trim() : "";
                            return label.length > 0 ? label : qsTr("Log in to %1").arg(root.sourceName(root.sourceId));
                        }
                        readonly property string loginDescription: {
                            const browseDescription = loginAction ? String(loginAction.browseDescription ?? "").trim() : "";
                            if (browseDescription.length > 0)
                                return browseDescription;
                            const description = loginAction ? String(loginAction.description ?? "").trim() : "";
                            return description.length > 0 ? description : qsTr("Log in to start browsing.");
                        }
                        readonly property string loginButtonLabel: {
                            const label = loginAction ? String(loginAction.browseButtonLabel ?? "").trim() : "";
                            return label.length > 0 ? label : qsTr("Log in");
                        }

                        MD.BusyIndicator {
                            Layout.alignment: Qt.AlignHCenter
                            running: searchQuery.querying
                            visible: running
                        }

                        MD.Icon {
                            Layout.alignment: Qt.AlignHCenter
                            visible: parent.needsLogin
                            name: MD.Token.icon.person
                            size: 40
                            color: MD.Token.color.on_surface_variant
                        }
                        MD.Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            visible: parent.needsLogin || parent.hasError
                            text: parent.needsLogin ? parent.loginLabel : qsTr("Couldn't load this source")
                            typescale: MD.Token.typescale.title_medium
                            color: MD.Token.color.on_surface
                            wrapMode: Text.WordWrap
                        }
                        MD.Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            visible: parent.needsLogin || parent.hasError
                            text: parent.needsLogin ? parent.loginDescription : searchQuery.errorText
                            typescale: MD.Token.typescale.body_medium
                            color: MD.Token.color.on_surface_variant
                            font.capitalization: Font.MixedCase
                            wrapMode: Text.WordWrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                        }
                        MD.Button {
                            Layout.alignment: Qt.AlignHCenter
                            visible: parent.needsLogin
                            text: parent.loginButtonLabel
                            mdState.type: MD.Enum.BtFilledTonal
                            onClicked: root.openRemoteManagement()
                        }

                        MD.Label {
                            Layout.alignment: Qt.AlignHCenter
                            visible: !searchQuery.querying && !parent.needsLogin && searchQuery.errorText.length === 0
                            text: qsTr("No wallpapers found")
                            typescale: MD.Token.typescale.body_large
                            color: MD.Token.color.on_surface_variant
                        }
                    }
                }
            }
        }

        Item {
            id: discoverDetailPanelContainer

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: discoverSplitView.detailWidth
            visible: root.detailOpen || root.detailPanelProgress > 0.001
            clip: true

            W.CupertinoPane {
                width: 280
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                radius: root.MD.MProp.page.backgroundRadius
                padding: 0
                backgroundColor: W.Global.cupertinoCard
                showBackground: true
                opacity: Math.min(1, root.detailPanelProgress * 1.35)
                enabled: root.detailPanelProgress > 0.98

                transform: Translate {
                    x: (1 - root.detailPanelProgress) * 18
                }

                contentItem: RemoteDetailPanel {
                    item: root.detailRow
                    details: detailsQuery
                    remoteCapability: root.detailRow ? root.sourceCapability(root.detailRow.sourceId) : 0
                    remoteHint: root.detailRow ? root.sourceRemoteHint(root.detailRow.sourceId) : ""
                    downloadState: Number(root.detailRow?.acquisitionState ?? 0)
                    subscriptionState: Number(root.detailRow?.acquisitionState ?? 0)

                    onBack: root.closeDetail()
                    onShowInfo: root.openInfo()
                    onDownloadRequested: {
                        if (!root.detailRow)
                            return;
                        dlQuery.start(root.detailRow.sourceId, root.detailRow.itemId);
                    }
                    onRemoveRequested: {
                        if (root.detailRow)
                            dlQuery.remove(root.detailRow.sourceId, root.detailRow.itemId);
                    }
                    onSubscriptionRefreshRequested: root.refreshDetailSubscription()
                    onSubscriptionChangeRequested: subscribed => root.setDetailSubscription(subscribed)
                }
            }
        }
    }

    Component {
        id: discoverTweakSheetComponent

        W.TweakSheet {
            popupParent: root
            blurSource: root.contentItem
            tweak: root.discoverTweakState
        }
    }
}
