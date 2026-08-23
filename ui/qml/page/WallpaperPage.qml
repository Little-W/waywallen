pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtQuick
import QtQml as Qml
import QtQuick.Layouts
import QtQuick.Templates as T
import Qcm.Material as MD
import waywallen.control as WC
import waywallen.ui as W

W.CupertinoPage {
    id: root
    objectName: "wallpaperPage"

    // PageContainer caches this page.  Expose its active state to delegates
    // so leaving Wallpapers cannot leave GIF decoders ticking behind another
    // page.
    readonly property bool previewPageActive: T.StackView.status === T.StackView.Active

    W.WallpaperListQuery {
        id: wallpaperQuery
    }

    W.WallpaperSelectStorage {
        id: userWallpaperSelect
        model: wallpaperQuery.data
        property list<MD.Action> actions: [removeSelectionAction, createPlaylistFromSelectionAction, addToPlaylistAction]
    }

    W.WallpaperSelectStorage {
        id: playlistWallpaperSelect
        model: wallpaperQuery.data
        property list<MD.Action> actions: [applyPlaylistSelectionAction, createPlaylistFromSelectionAction, addToPlaylistAction]
    }

    W.WallpaperScanQuery {
        id: scanQuery
    }

    W.WallpaperRemoveQuery {
        id: selectionRemoveQuery
        forwardError: false
        onRemovedMany: function (wallpaperIds, removedCount) {
            wallpaperQuery.reload();
            root.clearWallpaperSelection();
            W.Action.toast(qsTr("Removed %1").arg(removedCount));
        }
        onStatusChanged: {
            if (selectionRemoveQuery.status === 3) {
                const message = selectionRemoveQuery.error && selectionRemoveQuery.error.length > 0 ? selectionRemoveQuery.error : qsTr("Remove failed");
                W.Action.toast(message, 6000, 1, null);
            }
        }
    }

    W.PlaylistListQuery {
        id: playlistListQuery
    }

    property bool playlistListReady: false
    property string playlistMutationSuccessMessage: ""
    property string playlistMutationPendingMessage: ""
    readonly property int defaultPlaylistIntervalSecs: 300
    readonly property bool playlistListLoading: playlistListQuery.querying && !root.playlistListReady

    Connections {
        target: playlistListQuery
        function onPlaylistsChanged() {
            root.playlistListReady = true;
        }
        function onStatusChanged(status) {
            if (status !== 1)
                root.playlistListReady = true;
        }
    }

    W.PlaylistMutationQuery {
        id: playlistMutation
        forwardError: false
        onDone: {
            if (playlistMutation.status === 3) {
                root.playlistMutationSuccessMessage = "";
                root.playlistMutationPendingMessage = "";
                playlistMutationCleanupTimer.stop();
                W.Action.toast(qsTr("Playlist update failed"));
                return;
            }
            root.playlistMutationPendingMessage = root.playlistMutationSuccessMessage.length > 0 ? root.playlistMutationSuccessMessage : qsTr("Playlist updated");
            root.playlistMutationSuccessMessage = "";
            playlistMutationCleanupTimer.restart();
        }
    }

    W.PlaylistMutationQuery {
        id: playlistDetailMutation
        onDone: {
            playlistListQuery.reload();
        }
    }

    W.PlaylistMutationQuery {
        id: playlistSheetCreateMutation
        forwardError: false
        onDone: {
            if (playlistSheetCreateMutation.status === 3)
                W.Action.toast(qsTr("Playlist creation failed"));
            else
                W.Action.toast(qsTr("Playlist created"));
        }
    }

    W.PlaylistMutationQuery {
        id: playlistPlaybackMutation
        forwardError: false
        onDone: {
            if (playlistPlaybackMutation.status === 3)
                W.Action.toast(qsTr("Playlist playback failed"));
        }
    }

    W.TweakState {
        id: wallpaperTweakState
        settingsCategory: "WallpaperView"
    }

    W.PlaylistListSheetState {
        id: playlistListSheetState
        page: root
        playlistListQuery: playlistListQuery
        playlistMutation: playlistMutation
        playlistCreateMutation: playlistSheetCreateMutation
        playlistPlaybackMutation: playlistPlaybackMutation
    }

    W.SelectSheetContentState {
        id: selectSheetContentState
        page: root
        playlistListQuery: playlistListQuery
        playlistMutation: playlistMutation
    }

    Qml.Timer {
        id: playlistMutationCleanupTimer
        interval: MD.Token.duration.short4 + 16
        repeat: false
        onTriggered: {
            const message = root.playlistMutationPendingMessage;
            root.playlistMutationPendingMessage = "";
            playlistListQuery.reload();
            root.clearWallpaperSelection();
            if (message.length > 0)
                W.Action.toast(message);
        }
    }

    QtObject {
        id: wallpaperSelectSheetRelay

        property var activeAction: null
        property Component activeComponent: null
        property Component defaultComponent: null
        readonly property Component currentComponent: activeComponent ? activeComponent : defaultComponent

        signal newPlaylistRequested
        signal addToPlaylistRequested

        function reset() {
            activeAction = null;
            activeComponent = null;
            defaultComponent = null;
        }

        function restoreDefault() {
            activeAction = null;
            activeComponent = null;
        }

        function toggle(action, component) {
            if (activeAction === action) {
                restoreDefault();
                return false;
            }
            activeAction = action;
            activeComponent = component;
            return true;
        }

        function requestNewPlaylist() {
            if (toggle(createPlaylistFromSelectionAction, newPlaylistSheetComponent))
                newPlaylistRequested();
        }

        function requestAddToPlaylist() {
            if (toggle(addToPlaylistAction, addToPlaylistSheetComponent)) {
                playlistListQuery.reload();
                addToPlaylistRequested();
            }
        }
    }

    // Daemon-driven syncs (manual click, LibraryAdd/Remove, startup)
    // all reach the UI through `Notify` (mirrors the daemon's
    // `GlobalEvent` broadcasts). Toast UX is handled here via
    // `Action.toast`; Notify itself is intentionally toast-free.
    Connections {
        target: W.Notify
        function onWallpaperSyncFinished(count, error) {
            if (error && error.length > 0) {
                W.Action.toast(qsTr("Sync failed: %1").arg(error));
            } else {
                W.Action.toast(qsTr("Scanned %n wallpaper(s)", "", count));
            }
            wallpaperQuery.reload();
        }
        function onDaemonReady() {
            root.reloadAll();
        }
        function onPlaylistChanged() {
            playlistListQuery.reload();
        }
        function onPluginChanged() {
            pluginQuery.reload();
        }
    }

    function reloadAll() {
        pluginQuery.reload();
        playlistListQuery.reload();
        filterSettingsGet.reload();
    }

    Component.onCompleted: {
        publishWallpaperTweak();
        applySort();
        if (W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready)
            reloadAll();
    }

    MD.Action {
        id: createPlaylistFromSelectionAction
        text: qsTr("New playlist")
        icon.name: MD.Token.icon.playlist_add
        busy: playlistMutation.querying
        checked: wallpaperSelectSheetRelay.activeAction === createPlaylistFromSelectionAction
        enabled: root.selectedWallpaperCount > 0
        onTriggered: wallpaperSelectSheetRelay.requestNewPlaylist()
    }

    MD.Action {
        id: addToPlaylistAction
        text: qsTr("Add to playlist")
        icon.name: MD.Token.icon.playlist_add
        checked: wallpaperSelectSheetRelay.activeAction === addToPlaylistAction
        enabled: root.selectedWallpaperCount > 0 && (playlistListQuery.playlists || []).length > 0 && !playlistMutation.querying
        onTriggered: wallpaperSelectSheetRelay.requestAddToPlaylist()
    }

    MD.Action {
        id: applyPlaylistSelectionAction
        text: qsTr("Apply")
        icon.name: MD.Token.icon.check
        busy: playlistMutation.querying
        enabled: playlistWallpaperSelect.playlistEditTargetId > 0 && !playlistMutation.querying
        onTriggered: root.applyPlaylistSelection()
    }

    MD.Action {
        id: removeSelectionAction
        text: qsTr("Remove %1").arg(root.removableSelectedWallpaperCount)
        icon.name: MD.Token.icon.delete
        busy: selectionRemoveQuery.querying
        enabled: root.removableSelectedWallpaperCount > 0 && !selectionRemoveQuery.querying
        onTriggered: root.removeSelectedWallpapers()
    }

    MD.Action {
        id: playlistListAction
        text: qsTr("Playlists")
        icon.name: MD.Token.icon.playlist_play
        checked: W.App.displayManager.hasActivePlaylistDisplays
        onTriggered: root.togglePlaylistListSheet()
    }

    MD.Action {
        id: tweakAction
        text: qsTr("Tweak")
        icon.name: MD.Token.icon.tune
        checked: root.isSheetActive(root.wallpaperTweakSheet)
        onTriggered: root.toggleWallpaperTweakSheet()
    }

    MD.Action {
        id: filterAction
        icon.name: MD.Token.icon.filter_list
        text: qsTr("Filters")
        checked: wallpaperQuery.hasActiveFilters
        onTriggered: {
            if (root.filterPresentation?.active)
                return;
            root.filterPresentation = root.Window.window.presentPopup(filterDialogComponent);
        }
    }

    MD.Action {
        id: sourcesAction
        icon.name: MD.Token.icon.hard_drive
        text: qsTr("Library Manager")
        property var presentation: null
        onTriggered: {
            if (presentation?.active)
                return;
            presentation = root.Window.window.presentPopup('waywallen.ui/PagePopup', {
                source: 'waywallen.ui/SourceManagePage'
            });
        }
    }

    MD.Action {
        id: refreshAction
        icon.name: MD.Token.icon.refresh
        text: qsTr("Refresh")
        enabled: !W.Notify.scanInProgress
        onTriggered: scanQuery.reload()
    }

    W.RendererPluginListQuery {
        id: pluginQuery
    }

    W.LibraryAutoDetectQuery {
        id: autoDetectQuery
    }

    // Quick filters (skip-types, tag filter) are seeded from settings
    // once; after that the local selection is authoritative. Re-adopting
    // them on every settings echo would revert a just-applied toggle
    // whenever the round-trip lags.
    property bool _quickFiltersSeeded: false
    property bool _filterStateSeeded: false

    W.SettingsGetQuery {
        id: filterSettingsGet
        onGlobalChanged: {
            // Restore sort first so the filter pipeline below doesn't
            // dispatch a list reload with the stale sort.
            root.restoreSortFromSettings(global.wallpaperSorts || []);
            if (!root._quickFiltersSeeded) {
                wallpaperQuery.skipTypes = global.wallpaperSkipTypes || [];
                wallpaperQuery.filterTags = global.wallpaperFilterTags || [];
                wallpaperQuery.skipContentRatings = global.wallpaperSkipContentRatings || [];
                root._quickFiltersSeeded = true;
            }
            const filters = global.wallpaperFilters || [];
            const logics = global.wallpaperFilterLogics || [];
            const filterStateChanged = wallpaperQuery.replaceFilterState(filters, logics);
            if (filterStateChanged || !root._filterStateSeeded) {
                wallpaperFilterModel.replaceState(filters, logics);
                root._filterStateSeeded = true;
            }
        }
    }

    W.SettingsSetQuery {
        id: filterSettingsSet
    }

    W.WallpaperFilterRuleModel {
        id: wallpaperFilterModel

        function doQuery() {
            if (!wallpaperQuery.replaceFilterState(items(), filterLogics))
                wallpaperQuery.reload();
        }

        onApply: {
            doQuery();
            root._persistGlobalChange(g => {
                g.wallpaperFilters = items();
                g.wallpaperFilterLogics = filterLogics;
            });
        }

        onReset: {
            replaceState(filterSettingsGet.global.wallpaperFilters || [], filterSettingsGet.global.wallpaperFilterLogics || []);
            doQuery();
        }
    }

    Component {
        id: filterDialogComponent

        W.WallpaperFilterDialog {
            popupWindow: root.Window.window
            model: wallpaperFilterModel
            supportedTypes: pluginQuery.supportedTypes || []
            skipTypes: wallpaperQuery.skipTypes
            onToggleSkip: function (ty) {
                const next = (wallpaperQuery.skipTypes || []).slice();
                const i = next.indexOf(ty);
                if (i >= 0)
                    next.splice(i, 1);
                else
                    next.push(ty);
                wallpaperQuery.skipTypes = next;
                root._persistGlobalChange(g => {
                    g.wallpaperSkipTypes = next;
                });
            }
            filterTags: wallpaperQuery.filterTags
            onApplyFilterTags: function (tags) {
                wallpaperQuery.filterTags = tags;
                root._persistGlobalChange(g => {
                    g.wallpaperFilterTags = tags;
                });
            }
            skipContentRatings: wallpaperQuery.skipContentRatings
            onToggleSkipRating: function (rating) {
                const next = (wallpaperQuery.skipContentRatings || []).slice();
                const i = next.indexOf(rating);
                if (i >= 0)
                    next.splice(i, 1);
                else
                    next.push(rating);
                wallpaperQuery.skipContentRatings = next;
                root._persistGlobalChange(g => {
                    g.wallpaperSkipContentRatings = next;
                });
            }
        }
    }

    Connections {
        target: W.Notify
        function onSettingsChanged() {
            filterSettingsGet.reload();
        }
    }

    readonly property var sortOptions: [
        {
            name: qsTr("Name"),
            key: WC.WallpaperSortKey.WALLPAPER_SORT_KEY_NAME
        },
        {
            name: qsTr("Size"),
            key: WC.WallpaperSortKey.WALLPAPER_SORT_KEY_SIZE
        },
        {
            name: qsTr("Last modified"),
            key: WC.WallpaperSortKey.WALLPAPER_SORT_KEY_LAST_MODIFIED
        }
    ]
    property int sortIndex: 0
    property bool sortAsc: true
    property WC.wallpaperSortRule emptySortRule

    Connections {
        target: wallpaperTweakState
        function onItemSizeChanged() {
            root.publishWallpaperTweak();
            root.forceWallpaperGridLayout();
        }
        function onItemAspectRatioChanged() {
            root.publishWallpaperTweak();
            root.forceWallpaperGridLayout();
        }
        function onLayoutModeChanged() {
            root.publishWallpaperTweak();
            root.forceWallpaperGridLayout();
        }
    }

    function publishWallpaperTweak() {
        W.Global.wallpaperGridItemSize = wallpaperTweakState.itemSize;
        W.Global.wallpaperGridItemAspectRatio = wallpaperTweakState.itemAspectRatio;
        W.Global.wallpaperGridLayoutMode = wallpaperTweakState.layoutMode;
        W.Global.wallpaperGridTweakReady = true;
    }

    function _buildSortRule() {
        const rule = emptySortRule;
        rule.key = sortOptions[sortIndex].key;
        rule.direction = sortAsc ? WC.SortDirection.SORT_DIRECTION_ASC : WC.SortDirection.SORT_DIRECTION_DESC;
        return rule;
    }
    function applySort() {
        wallpaperQuery.sorts = [_buildSortRule()];
    }
    // Guard: don't overwrite daemon state with proto defaults when the
    // local mirror of settings hasn't been populated yet. Without this,
    // a click that lands before filterSettingsGet's first response
    // ships a SettingsSet with only the touched field; the daemon then
    // resets target_extent to 0 and clears the filter on commit.
    function _persistGlobalChange(mutator) {
        if (Object.keys(filterSettingsGet.global).length === 0)
            return;
        const nextGlobal = Object.assign({}, filterSettingsGet.global);
        mutator(nextGlobal);
        filterSettingsSet.global = nextGlobal;
        filterSettingsSet.plugins = filterSettingsGet.plugins;
        filterSettingsSet.reload();
    }
    function pickSort(idx) {
        if (idx === sortIndex) {
            sortAsc = !sortAsc;
        } else {
            // Switching key keeps the current asc/desc order.
            sortIndex = idx;
        }
        applySort();
        _persistGlobalChange(g => {
            g.wallpaperSorts = [_buildSortRule()];
        });
    }
    function restoreSortFromSettings(rules) {
        if (!rules || rules.length === 0) {
            // No persisted sort yet — keep whatever defaults are in place
            // and push them down so the list query has at least one rule.
            applySort();
            return;
        }
        const r = rules[0];
        const idx = sortOptions.findIndex(o => o.key === r.key);
        if (idx >= 0)
            sortIndex = idx;
        sortAsc = r.direction !== WC.SortDirection.SORT_DIRECTION_DESC;
        applySort();
    }

    function forceWallpaperGridLayout() {
        if (m_grid_view)
            m_grid_view.forceLayout();
    }

    property var selectedWallpaper: null
    // Keep the panel's previous model alive until its close transition has
    // finished. Clearing it at click time made the panel contents disappear
    // before the panel itself could animate out.
    property var detailWallpaper: null
    readonly property bool detailPanelOpen: root.selectedWallpaper !== null
                                                    && !root.selectionActive
    // Adopt the destination grid topology at the start of the split-panel
    // transition. Card surfaces then move from their captured scene positions
    // instead of disappearing behind a white fade.
    property bool detailGridLayoutOpen: false
    property real detailPanelProgress: root.detailPanelOpen ? 1.0 : 0.0
    property bool detailFocusPending: false
    property bool smoothDetailFocusPending: false
    // Closing the detail pane expands the grid back to its full-width
    // topology. Keep the selected card as a visual anchor until that reflow
    // has finished; detailWallpaper itself is deliberately cleared at the
    // end of the panel animation and therefore cannot represent this state.
    property bool restoreDetailFocusPending: false
    property bool detailCloseAnchorActive: false
    // Exposed only so the opt-in, focus-free validation hook can distinguish
    // a rejected scroll target from a later GridView layout override.
    property real detailRestoreFocusTargetY: NaN
    property bool detailRestoreFocusScrollAccepted: false
    readonly property bool detailLayoutFocusActive: root.detailWallpaper !== null
                                                    && (root.detailPanelProgress > 0.001
                                                        || detailPanelAnimation.running)

    Behavior on detailPanelProgress {
        NumberAnimation {
            id: detailPanelAnimation

            duration: 220
            // Playing the same curve backwards makes close the temporal
            // inverse of open instead of a second, unrelated retreat.
            easing.type: root.detailPanelOpen ? Easing.OutCubic : Easing.InCubic
            onRunningChanged: {
                if (running) {
                    // Keep the high-frequency split animation transform-only
                    // where possible. Repeated forceLayout() plus
                    // positionViewAtIndex() on every progress tick was the
                    // source of the preview's visible size/position jitter.
                    W.Global.contentGeometryAnimating = true;
                    m_grid_view.previewAnimationsSettled = false;
                    root.detailFocusPending = true;
                } else {
                    W.Global.contentGeometryAnimating = false;
                    previewAnimationSettleTimer.restart();
                    if (root.detailPanelProgress <= 0.001
                            && root.selectedWallpaper === null) {
                        root.detailCloseAnchorActive = false;
                        root.detailWallpaper = null;
                    }
                    root.detailFocusPending = false;
                    root.scheduleCurrentWallpaperFocus();
                }
            }
        }
    }

    onSelectedWallpaperChanged: {
        if (selectedWallpaper !== null) {
            detailWallpaper = selectedWallpaper;
            restoreDetailFocusPending = false;
            detailCloseAnchorActive = false;
        } else if (!root.selectionActive && detailWallpaper !== null
                   && m_grid_view && m_grid_view.currentIndex >= 0) {
            // The selected model stays represented by GridView.currentIndex
            // after the panel closes. Restore it smoothly once the expanded
            // column layout is final instead of letting it reflow offscreen.
            restoreDetailFocusPending = true;
            smoothDetailFocusPending = true;
            detailCloseAnchorActive = true;
        }
        const layoutOpen = selectedWallpaper !== null && !root.selectionActive;
        if (m_grid_view)
            m_grid_view.beginDetailLayout(layoutOpen);
        else
            detailGridLayoutOpen = layoutOpen;
        root.scheduleCurrentWallpaperFocus();
    }
    function scheduleCurrentWallpaperFocus() {
        if (!m_grid_view || m_grid_view.currentIndex < 0)
            return;
        if (root.detailCloseAnchorActive)
            return;
        if (detailPanelAnimation.running) {
            detailFocusPending = true;
            return;
        }
        detailFocusTimer.restart();
    }

    function focusCurrentWallpaper() {
        if (!m_grid_view || m_grid_view.currentIndex < 0
                || (!root.detailLayoutFocusActive
                    && !root.restoreDetailFocusPending))
            return;
        m_grid_view.forceLayout();
        if (root.restoreDetailFocusPending) {
            // onSelectedWallpaperChanged can run just before Behavior marks
            // its NumberAnimation as running. The progress value is the
            // reliable guard against sampling the pre-close column here.
            if (root.detailPanelProgress > 0.001
                    || detailPanelAnimation.running) {
                root.detailFocusPending = true;
                return;
            }
            // forceLayout() schedules the delegate-position polish. Reading
            // currentItem.y in this same turn still returns the old column in
            // Qt 6, so defer the coordinate read by a few render frames.
            detailRestoreFocusTimer.restart();
            return;
        }
        if (root.smoothDetailFocusPending && m_grid_view.currentItem) {
            root.smoothDetailFocusPending = false;
            const item = m_grid_view.currentItem;
            const usableCenter = (m_grid_view.topMargin + m_grid_view.height
                                  - m_grid_view.bottomMargin) / 2;
            wallpaperDesktopWheel.scrollTo(item.y + item.height / 2
                                           - usableCenter);
            return;
        }
        root.smoothDetailFocusPending = false;
        // Qt explicitly recommends positionViewAtIndex() instead of writing
        // contentY for index positioning. Centering on every coalesced layout
        // frame makes the selected wallpaper the stable visual anchor while
        // the detail panel changes the number of grid columns.
        m_grid_view.positionViewAtIndex(m_grid_view.currentIndex, GridView.Center);
    }
    property var currentWallpaperSelect: null
    property var wallpaperSelectSheet: null
    property var wallpaperTweakSheet: null
    property var playlistListSheet: null
    property var filterPresentation: null
    Component.onDestruction: {
        root.filterPresentation?.cancel();
        W.Global.contentGeometryAnimating = false;
    }
    readonly property int selectionSheetReserve: wallpaperSelectSheetRelay.currentComponent ? 360 : 160
    readonly property int selectedWallpaperCount: root.currentWallpaperSelect ? root.currentWallpaperSelect.selectedCount : 0
    readonly property int removableSelectedWallpaperCount: root.currentWallpaperSelect ? root.currentWallpaperSelect.removableSelectedCount : 0
    readonly property bool selectionActive: root.currentWallpaperSelect ? root.currentWallpaperSelect.active : false
    readonly property bool selectionActionSheetActive: root.selectionActive && root.currentWallpaperSelect && (root.currentWallpaperSelect.actions || []).length > 0

    onSelectionActiveChanged: {
        if (selectionActive) {
            restoreDetailFocusPending = false;
            smoothDetailFocusPending = false;
            selectedWallpaper = null;
            if (m_grid_view)
                m_grid_view.currentIndex = -1;
        } else {
            wallpaperSelectSheetRelay.reset();
        }
        root.syncWallpaperSelectSheet();
    }

    Connections {
        target: W.Action
        function onWallpaperSelectEntered(storage) {
            root.adoptWallpaperSelect(storage);
        }
    }

    Connections {
        target: root.currentWallpaperSelect
        function onActiveChanged() {
            root.syncWallpaperSelectSheet();
        }
    }

    function ensureWallpaperSelectSheet() {
        if (root.wallpaperSelectSheet?.active)
            return root.wallpaperSelectSheet;

        const sheet = root.Window.window.presentPopup(wallpaperSelectSheetComponent);
        if (sheet.active) {
            root.wallpaperSelectSheet = sheet;
            sheet.activeChanged.connect(sheet, function () {
                if (!sheet.active) {
                    root.releaseWallpaperSelectSheet(sheet);
                    if (root.selectionActionSheetActive)
                        root.syncWallpaperSelectSheet();
                }
            });
        }
        return sheet;
    }

    function releaseWallpaperSelectSheet(sheet) {
        const target = sheet || root.wallpaperSelectSheet;
        if (!target)
            return;
        if (root.wallpaperSelectSheet === target)
            root.wallpaperSelectSheet = null;
    }

    function isSheetActive(sheet) {
        return !!sheet && (sheet.status === MD.PopupPresentation.Opening || sheet.status === MD.PopupPresentation.Open);
    }

    function ensureWallpaperTweakSheet() {
        if (root.wallpaperTweakSheet?.active)
            return root.wallpaperTweakSheet;

        const sheet = root.Window.window.presentPopup(wallpaperTweakSheetComponent);
        if (sheet.active) {
            root.wallpaperTweakSheet = sheet;
            sheet.activeChanged.connect(sheet, function () {
                if (!sheet.active)
                    root.releaseWallpaperTweakSheet(sheet);
            });
        }
        return sheet;
    }

    function releaseWallpaperTweakSheet(sheet) {
        if (root.wallpaperTweakSheet === sheet)
            root.wallpaperTweakSheet = null;
    }

    function ensurePlaylistListSheet() {
        if (root.playlistListSheet?.active)
            return root.playlistListSheet;

        const sheet = root.Window.window.presentPopup(playlistListSheetComponent);
        if (sheet.active) {
            root.playlistListSheet = sheet;
            sheet.activeChanged.connect(sheet, function () {
                if (!sheet.active)
                    root.releasePlaylistListSheet(sheet);
            });
        }
        return sheet;
    }

    function releasePlaylistListSheet(sheet) {
        if (root.playlistListSheet === sheet)
            root.playlistListSheet = null;
    }

    function syncWallpaperSelectSheet() {
        root.configureWallpaperSelectSheetDefault();

        if (root.selectionActionSheetActive) {
            root.ensureWallpaperSelectSheet();
            return;
        }

        if (root.wallpaperSelectSheet?.active)
            root.wallpaperSelectSheet.close();
    }

    function adoptWallpaperSelect(storage) {
        if (storage !== userWallpaperSelect && storage !== playlistWallpaperSelect)
            return;
        if (root.currentWallpaperSelect !== storage) {
            if (root.currentWallpaperSelect)
                root.currentWallpaperSelect.clear();
            root.currentWallpaperSelect = storage;
            wallpaperSelectSheetRelay.reset();
        }
        root.configureWallpaperSelectSheetDefault();
        root.syncWallpaperSelectSheet();
    }

    function configureWallpaperSelectSheetDefault() {
        wallpaperSelectSheetRelay.defaultComponent = root.currentWallpaperSelect === playlistWallpaperSelect ? playlistSelectDetailComponent : null;
    }

    function enterWallpaperSelect(storage) {
        if (!storage)
            return;
        root.adoptWallpaperSelect(storage);
        W.Action.enterWallpaperSelect(storage);
    }

    function interactionWallpaperSelect() {
        return root.currentWallpaperSelect && root.currentWallpaperSelect.active ? root.currentWallpaperSelect : userWallpaperSelect;
    }

    function beginWallpaperSelection(index) {
        root.enterWallpaperSelect(userWallpaperSelect);
        const row = index === undefined ? -1 : Number(index);
        if (!userWallpaperSelect.begin(row))
            return;

        root.selectedWallpaper = null;
        if (m_grid_view)
            m_grid_view.currentIndex = -1;
        if (m_grid_view)
            m_grid_view.forceActiveFocus();
        root.syncWallpaperSelectSheet();
    }

    function clearWallpaperSelection() {
        if (root.currentWallpaperSelect)
            root.currentWallpaperSelect.clear();
        root.currentWallpaperSelect = null;
        wallpaperSelectSheetRelay.reset();
        root.syncWallpaperSelectSheet();
    }

    function selectedWallpaperIds() {
        return root.currentWallpaperSelect ? root.currentWallpaperSelect.selectedWallpaperIds() : [];
    }

    property var playlistPlayDisplayId: null
    readonly property var playlistPlayDisplays: {
        const targets = [];
        const lockscreenKeys = new Set();
        for (const canvas of W.App.displayManager.canvases || []) {
            const displayIds = [];
            for (const member of canvas.members || []) {
                for (const displayId of member.displayIds || [])
                    displayIds.push(displayId);
            }
            if (displayIds.length > 0) {
                targets.push({
                    targetId: "canvas:" + canvas.id,
                    targetLabel: canvas.name || qsTr("Unnamed canvas"),
                    targetIcon: MD.Token.icon.dashboard,
                    target: { canvasId: canvas.id },
                    displayIds: displayIds
                });
            }
        }
        const displays = [...(W.App.displayManager.displays || [])]
            .sort((a, b) => Number(!!a.isLockscreen) - Number(!!b.isLockscreen));
        for (const display of displays) {
            if (!display.selectableTarget)
                continue;
            const settingsKey = String(display.settingsKey || "");
            if (display.isLockscreen && settingsKey.length) {
                if (lockscreenKeys.has(settingsKey))
                    continue;
                lockscreenKeys.add(settingsKey);
                const ids = (W.App.displayManager.displays || [])
                    .filter(item => item.isLockscreen && item.settingsKey === settingsKey
                            && item.selectableTarget)
                    .map(item => item.id);
                targets.push({
                    targetId: "display-key:" + settingsKey,
                    targetLabel: root.rawDisplayLabel(display),
                    targetIcon: MD.Token.icon.monitor,
                    displayIds: ids
                });
                continue;
            }
            targets.push({
                targetId: "display:" + display.id,
                targetLabel: root.rawDisplayLabel(display),
                targetIcon: MD.Token.icon.monitor,
                displayIds: [display.id]
            });
        }
        return targets;
    }

    onPlaylistPlayDisplaysChanged: {
        if (playlistPlayDisplays.length === 0) {
            playlistPlayDisplayId = null;
            return;
        }
        if (!root.displayById(playlistPlayDisplayId))
            playlistPlayDisplayId = playlistPlayDisplays[0].targetId;
    }

    function displayById(id) {
        if (id === null || id === undefined)
            return null;
        const key = String(id);
        const displays = root.playlistPlayDisplays || [];
        for (let i = 0; i < displays.length; ++i) {
            if (String(displays[i].targetId) === key)
                return displays[i];
        }
        return null;
    }

    function displayLabel(display) {
        if (!display)
            return qsTr("Display");
        if ((display.targetLabel || "").length)
            return display.targetLabel;
        return root.rawDisplayLabel(display);
    }

    function rawDisplayLabel(display) {
        if ((display.displayLabel || "").length)
            return display.displayLabel;
        let base = display.alias || "";
        if (!base.length)
            base = (display.name || "").replace(/^waywallen-[a-z]+-[a-z]+-/, "");
        if (!base.length)
            return qsTr("Display #%1").arg(display.id);
        return base + " (#" + display.id + ")";
    }

    function selectedPlaylistDisplay() {
        const displays = root.playlistPlayDisplays || [];
        if (displays.length === 0)
            return null;
        return root.displayById(root.playlistPlayDisplayId) || displays[0];
    }

    function selectedPlaylistDisplayId() {
        const display = root.selectedPlaylistDisplay();
        const ids = display?.displayIds || [];
        return ids.length > 0 ? ids[0] : null;
    }

    function playlistDisplayStatuses(playlist) {
        if (!playlist)
            return [];
        const playlistId = String(playlist.id);
        const statuses = W.App.displayManager.displays || [];
        const out = [];
        for (let i = 0; i < statuses.length; ++i) {
            if (String(statuses[i].activePlaylistId) === playlistId)
                out.push(statuses[i]);
        }
        return out;
    }

    function playlistDisplayLabels(playlist) {
        const out = [];
        const playlistId = String(playlist?.id || "");
        for (const target of root.playlistPlayDisplays || []) {
            const ids = target.displayIds || [];
            const active = ids.some(id => {
                const display = W.App.displayManager.get(id);
                return display && String(display.activePlaylistId) === playlistId;
            });
            if (active)
                out.push(root.displayLabel(target));
        }
        return out;
    }

    function playlistIsPlayingOnSelectedDisplay(playlist) {
        const target = root.selectedPlaylistDisplay();
        if (!playlist || !target)
            return false;
        const playlistId = String(playlist.id);
        const ids = target.displayIds || [];
        return ids.length > 0 && ids.every(id => {
            const display = W.App.displayManager.get(id);
            return display && String(display.activePlaylistId) === playlistId;
        });
    }

    function playlistIsSharedActive(playlist) {
        const displays = W.App.displayManager.displays || [];
        if (!playlist || displays.length === 0)
            return false;
        return root.playlistDisplayStatuses(playlist).length === displays.length;
    }

    function togglePlaylistPlayback(playlist, shareAllDisplays) {
        if (!playlist || playlistPlaybackMutation.querying)
            return;

        if (shareAllDisplays) {
            if (root.playlistPlayDisplays.length === 0)
                return;
            if (root.playlistIsSharedActive(playlist))
                playlistPlaybackMutation.deactivate([], playlist.id);
            else
                playlistPlaybackMutation.activate(playlist.id, [], true);
            return;
        }

        const display = root.selectedPlaylistDisplay();
        if (!display)
            return;
        const targets = display.target
            ? [display.target]
            : (display.displayIds || []).map(id => ({ displayId: id }));
        if (root.playlistIsPlayingOnSelectedDisplay(playlist))
            playlistPlaybackMutation.deactivate(targets, 0);
        else
            playlistPlaybackMutation.activate(playlist.id, targets, false);
    }

    function togglePlaylistListSheet() {
        if (root.playlistListSheet?.active) {
            root.playlistListSheet.close();
            return;
        }
        if (root.wallpaperTweakSheet?.active)
            root.wallpaperTweakSheet.close();
        playlistListQuery.reload();
        root.ensurePlaylistListSheet();
    }

    function toggleWallpaperTweakSheet() {
        if (root.wallpaperTweakSheet?.active) {
            root.wallpaperTweakSheet.close();
            return;
        }
        if (root.playlistListSheet?.active)
            root.playlistListSheet.close();
        root.ensureWallpaperTweakSheet();
    }

    function isEditingPlaylist(playlist) {
        return playlistWallpaperSelect.isEditingPlaylist(playlist);
    }

    function editPlaylistSelection(playlist) {
        if (!playlist)
            return;

        root.enterWallpaperSelect(playlistWallpaperSelect);
        playlistWallpaperSelect.editPlaylistSelection(playlist);
        root.selectedWallpaper = null;
        if (m_grid_view)
            m_grid_view.currentIndex = -1;
        if (root.isSheetActive(root.playlistListSheet))
            root.playlistListSheet.close();
        if (m_grid_view)
            m_grid_view.forceActiveFocus();
        root.syncWallpaperSelectSheet();
    }

    function confirmPlaylistSelection(playlist) {
        if (!root.isEditingPlaylist(playlist) || playlistMutation.querying)
            return;
        playlistMutation.setItems(playlist.id, playlistWallpaperSelect.selectedWallpaperIds());
    }

    function applyPlaylistSelection() {
        root.confirmPlaylistSelection(playlistWallpaperSelect.playlistEditTarget);
    }

    function handleWallpaperClick(index, modifiers) {
        const model = wallpaperQuery.data;
        if (!model)
            return;

        if ((modifiers & Qt.ShiftModifier) !== 0) {
            const select = root.interactionWallpaperSelect();
            root.enterWallpaperSelect(select);
            const anchor = select.anchorIndex >= 0 ? select.anchorIndex : (m_grid_view.currentIndex >= 0 ? m_grid_view.currentIndex : index);
            select.selectRange(anchor, index, true);
            select.selectionMode = true;
            select.anchorIndex = anchor;
            root.selectedWallpaper = null;
            root.syncWallpaperSelectSheet();
            return;
        }

        if (root.selectionActive || (modifiers & Qt.ControlModifier) !== 0) {
            const select = root.interactionWallpaperSelect();
            root.enterWallpaperSelect(select);
            select.toggleSelected(index);
            root.selectedWallpaper = null;
            root.syncWallpaperSelectSheet();
            return;
        }

        // Once the detail pane is open, focus the next card with the same
        // C++ spring trajectory used by high-refresh wheel scrolling. The
        // initial detail opening still centres before its topology change.
        const detailWasOpen = root.detailPanelOpen;
        m_grid_view.currentIndex = index;
        root.smoothDetailFocusPending = detailWasOpen;
        m_grid_view.forceActiveFocus();
        userWallpaperSelect.anchorIndex = index;
        root.selectedWallpaper = model.item(index);
    }

    function requestWallpaperSelection(index) {
        const model = wallpaperQuery.data;
        if (!model)
            return;

        root.beginWallpaperSelection(index);
    }

    function createPlaylistFromSelection(name) {
        const ids = root.selectedWallpaperIds();
        if (ids.length === 0 || playlistMutation.querying)
            return;

        const title = String(name || "").trim();
        playlistMutation.create(title.length > 0 ? title : qsTr("New playlist"), WC.PlaylistMode.SEQUENTIAL, root.defaultPlaylistIntervalSecs, ids);
    }

    function createEmptyPlaylist() {
        if (playlistSheetCreateMutation.querying)
            return;

        playlistSheetCreateMutation.create(qsTr("New playlist"), WC.PlaylistMode.SEQUENTIAL, root.defaultPlaylistIntervalSecs, []);
    }

    function addSelectionToPlaylist(playlist) {
        const ids = root.selectedWallpaperIds();
        if (ids.length === 0 || !playlist || playlistMutation.querying)
            return;

        const merged = (playlist.entryIds || []).slice();
        const seen = {};
        for (let i = 0; i < merged.length; ++i)
            seen[String(merged[i])] = true;
        for (let j = 0; j < ids.length; ++j) {
            const key = String(ids[j]);
            if (seen[key] !== true) {
                merged.push(ids[j]);
                seen[key] = true;
            }
        }
        root.playlistMutationSuccessMessage = qsTr("Added to playlist");
        playlistMutation.setItems(playlist.id, merged);
    }

    function removeSelectedWallpapers() {
        const select = root.currentWallpaperSelect;
        if (!select || selectionRemoveQuery.querying)
            return;

        const ids = select.removableSelectedWallpaperIds();
        if (ids.length === 0)
            return;

        selectionRemoveQuery.remove(ids);
    }

    function deletePlaylist(playlist) {
        if (!playlist || playlistMutation.querying)
            return;

        root.playlistMutationSuccessMessage = qsTr("Playlist deleted");
        playlistMutation.remove(playlist.id);
    }

    showBackground: false
    padding: MD.MProp.size.isCompact ? 0 : 12
    // The collection toolbar is a continuation of the structural title bar,
    // not a floating card.  Keep their junction fully covered in desktop
    // mode instead of exposing the page's transparent top padding.
    topPadding: 0
    // The page already starts at Window's one-pixel structural separator.
    // A second 12 px transparent inset exposed the opaque page background as
    // a visible gap between the sidebar and this frosted toolbar.
    leftPadding: 0
    // Match DiscoverPage's full-width content geometry. Leaving the inherited
    // 12 px desktop padding here exposed a white strip beside the toolbar and
    // made both pages calculate their startup grids from different widths.
    rightPadding: 0

    contentItem: Item {
        id: wallpaperSplitView

        // Use direct scene geometry for the animated split. Qt Quick Layouts
        // can perform several negotiation passes for each fractional preferred
        // width, which made the preview resize unevenly even though
        // detailPanelProgress itself was smooth.
        readonly property real detailWidth: 280 * root.detailPanelProgress
        readonly property real detailGap: 12 * root.detailPanelProgress

        // --- Left: wallpaper grid ---
        W.CupertinoPane {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.max(0, parent.width
                            - wallpaperSplitView.detailWidth
                            - wallpaperSplitView.detailGap)
            radius: root.MD.MProp.page.backgroundRadius
            padding: 0
            backgroundColor: W.Global.cupertinoCard
            showBackground: true

            contentItem: Item {
                id: wallpaperGridArea

                clip: true

                // Keep the grid as the base layer.  The toolbar below samples
                // only its own strip so thumbnails can scroll behind a real,
                // low-transparency frosted header without an expensive
                // full-page blur effect.
                MD.VerticalGridView {
                    id: m_grid_view
                    // Only used by the opt-in C++ scroll telemetry probe.
                    // It carries no handlers or work during normal launches.
                    objectName: "wallpaperPreviewGrid"

                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    // Lay out at the destination width immediately; the pane
                    // above is the animated clip. If GridView itself follows
                    // the pane width, Qt keeps the old physical column count
                    // until a threshold is crossed and then rewraps a row in
                    // one frame near the end of the transition.
                    width: _targetViewportWidth
                    clip: false
                    focus: true
                    focusPolicy: Qt.StrongFocus
                    keyNavigationEnabled: true
                    keyNavigationWraps: true
                    currentIndex: -1
                    highlightRangeMode: GridView.NoHighlightRange
                    // Qcm's shared GridView enables synchronousDrag for a
                    // direct, touch-first feel.  A pixel-delta touchpad then
                    // applies its drag threshold as one initial jump.  Keep
                    // this dense desktop grid on Qt's normal path so its
                    // content position advances continuously instead.
                    synchronousDrag: false
                    // Preserve fractional contentY while scrolling.  Integer
                    // snapping makes low-speed motion visibly step on a
                    // high-refresh display; false is Qt's animation-quality
                    // default and is stated explicitly to protect it from
                    // shared-style changes.
                    pixelAligned: false
                    // Qcm enables delegate reuse by default. During a topology
                    // FLIP that can rebind a prepared card object to another
                    // model index between capture and playback, producing
                    // crossed identities and white holes. Keep stable delegate
                    // identity only for this short transition.
                    reuseItems: !(columnReflowActive
                                  || detailPanelAnimation.running)

                    // Pixel-delta touchpads stay on Flickable's native path;
                    // discrete wheel steps use the frame-synchronized helper
                    // below so motion follows the scene graph refresh clock.
                    // Keep one decoded row ready without activating a large
                    // ring of off-screen animated previews.
                    cacheBuffer: columnReflowActive || detailPanelAnimation.running
                                 ? Math.max(height + cellHeight,
                                            Math.ceil(cellHeight * 1.25))
                                 : Math.max(96, Math.ceil(cellHeight * 1.25))
                    // A short settle period prevents a whole visible row of
                    // GIFs being constructed on the exact frame a flick ends.
                    // The static posters stay in place during this interval.
                    property bool previewAnimationsSettled: true
                    onContentYChanged: {
                        if (!moving && !flicking)
                            previewBoundarySettleTimer.restart();
                    }
                    onMovementStarted: {
                        wallpaperDesktopWheel.cancel();
                        previewAnimationsSettled = false;
                        previewAnimationSettleTimer.stop();
                    }
                    onMovementEnded: previewAnimationSettleTimer.restart()
                    displayMarginBeginning: 0
                    displayMarginEnd: 0
                    topMargin: wallpaperTopBar.height + 8
                    bottomMargin: Math.max(root.selectionActionSheetActive
                                           ? root.selectionSheetReserve : 8,
                                           W.Global.compactNavigationInset)
                    leftMargin: 8
                    rightMargin: 8

                    W.DesktopWheelScroll {
                        id: wallpaperDesktopWheel

                        flickable: m_grid_view
                        onScrollingChanged: {
                            if (scrolling) {
                                m_grid_view.previewAnimationsSettled = false;
                                previewAnimationSettleTimer.stop();
                            } else {
                                previewAnimationSettleTimer.restart();
                            }
                        }
                    }

                    // The grid flows under the compact glass navigation, but
                    // its scroll bar stops at the mask's upper edge so the
                    // handle stays reachable at the end of the list.
                    T.ScrollBar.vertical: MD.ScrollBar {
                        id: wallpaperScrollBar
                        objectName: "wallpaperPreviewScrollBar"
                        active: wallpaperDesktopWheel.scrolling
                                || m_grid_view.moving || pressed

                        // An attached ScrollBar already derives its position
                        // and size from the Flickable. Anchoring it back to
                        // that same Flickable creates a vertical geometry
                        // cycle in Qt 6. Reparent only the visual overlay and
                        // give it independent geometry so it cannot take the
                        // grid out of layout while still tracking the
                        // attached control's size/position values.
                        parent: wallpaperGridArea
                        width: implicitWidth
                        x: Math.max(0, wallpaperGridArea.width - width)
                        y: wallpaperTopBar.height + 8
                        height: Math.max(0,
                                         wallpaperGridArea.height - y
                                         - Math.max(W.Global.compactNavigationInset,
                                                    root.selectionActionSheetActive
                                                    ? root.selectionSheetReserve : 0))
                        z: 21
                        onPressedChanged: {
                            if (pressed) {
                                // ScrollBar owns contentY while pressed. Drop
                                // any in-flight wheel destination immediately
                                // so it cannot pull the view back on release.
                                wallpaperDesktopWheel.cancel();
                                m_grid_view.previewAnimationsSettled = false;
                                previewAnimationSettleTimer.stop();
                            } else if (!m_grid_view.moving && !m_grid_view.flicking) {
                                previewAnimationSettleTimer.restart();
                            }
                        }
                    }

                    // Do not expose delegates while the asynchronous page is
                    // still receiving its first real width.  Otherwise the
                    // initial one-column 932 px cards become visible and then
                    // animate down to the final five-column size.
                    visible: m_grid_view.count > 0 && _initialLayoutReady

                    // Test-only override remains negative in production. It
                    // lets the validation harness drive this exact layout at
                    // 165 Hz without waiting for a top-level Wayland configure
                    // round-trip on whichever physical screen opened the
                    // non-focused test window.
                    property real _diagnosticAvailableWidthOverride: -1
                    // The C++ verification harness toggles this together
                    // with its width override so the test exercises exactly
                    // the same cheap scene state as a real top-level resize.
                    property bool _diagnosticResizeActive: false
                    on_DiagnosticResizeActiveChanged: {
                        W.Global.windowResizing = _diagnosticResizeActive;
                    }

                    // During a detail transition the pane's clip width moves,
                    // while the grid lays out directly at the destination
                    // width. This gives the card FLIP one stable destination
                    // rather than changing its topology on every panel frame.
                    readonly property real _targetViewportWidth: Math.max(
                        0,
                        wallpaperSplitView.width
                        - (root.detailGridLayoutOpen ? 292 : 0))
                    readonly property real _availableWidth: _diagnosticAvailableWidthOverride >= 0
                                                               ? _diagnosticAvailableWidthOverride
                                                               : Math.max(0,
                                                                          _targetViewportWidth
                                                                          - leftMargin
                                                                          - rightMargin)
                    readonly property int _calculatedCols: Math.max(1, Math.floor(_availableWidth / wallpaperTweakState.itemSize))
                    // Keep the current column topology while configure events
                    // are streaming in. Otherwise crossing an integer column
                    // boundary makes a shrinking window grow every card in a
                    // single frame (for example 160.5 -> 191.8 px at 6 -> 5).
                    // Cell geometry still follows the viewport immediately,
                    // so this does not leave the stale-width white strip that
                    // a Behavior on cellWidth produced.
                    property int _cols: 1
                    property bool _initialLayoutReady: false
                    property bool _columnLatchReady: false
                    property bool viewportResizeActive: false
                    property bool columnReflowActive: false
                    readonly property real _stretchedItemWidth: _availableWidth / _cols
                    readonly property bool _fillCell: wallpaperTweakState.layoutMode === wallpaperTweakState.layoutFillCell
                    readonly property real _displayItemWidth: _fillCell
                                                               ? _stretchedItemWidth
                                                               : Math.min(wallpaperTweakState.itemSize,
                                                                          _stretchedItemWidth)
                    readonly property real _displayItemHeight: _displayItemWidth
                                                               / Math.max(wallpaperTweakState.itemAspectRatio,
                                                                          0.1)
                    cellWidth: _stretchedItemWidth
                    cellHeight: _fillCell
                                ? _displayItemHeight
                                : wallpaperTweakState.itemHeight

                    function scheduleColumnSettle() {
                        if (!_columnLatchReady)
                            return;
                        viewportResizeActive = true;
                        columnSettleTimer.restart();
                    }

                    function forEachPreparedDelegate(callback) {
                        const children = contentItem?.children || [];
                        for (let i = 0; i < children.length; ++i) {
                            const delegate = children[i];
                            if (delegate && delegate.objectName === "wallpaperCard")
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

                        // Capture the delegates' current scene positions and
                        // rendered sizes before switching to the known target.
                        // WallpaperCard performs one FLIP move/resize over the
                        // same duration as the panel reveal.
                        columnSettleTimer.stop();
                        detailContentYAnimation.stop();
                        viewportResizeActive = false;
                        if (!_initialLayoutReady) {
                            root.detailGridLayoutOpen = open;
                            _cols = _calculatedCols;
                            return;
                        }
                        const anchoredClose = !open
                                              && root.detailCloseAnchorActive
                                              && currentIndex >= 0;
                        const originalContentY = contentY;
                        columnReflowActive = false;
                        columnReflowActive = true;
                        prepareVisibleReflow();
                        root.detailGridLayoutOpen = open;
                        _cols = _calculatedCols;
                        if (currentIndex >= 0) {
                            wallpaperDesktopWheel.cancel();
                            forceLayout();
                            positionViewAtIndex(currentIndex, GridView.Center);
                            const anchored = contentY;
                            contentY = originalContentY;
                            if (anchoredClose) {
                                root.detailRestoreFocusTargetY = anchored;
                                root.detailRestoreFocusScrollAccepted = true;
                                root.restoreDetailFocusPending = false;
                            }
                            root.smoothDetailFocusPending = false;
                            detailContentYAnimation.from = originalContentY;
                            detailContentYAnimation.to = anchored;
                        }
                        forceLayout();
                        startVisibleReflow();
                        if (currentIndex >= 0
                                && Math.abs(detailContentYAnimation.to
                                            - detailContentYAnimation.from) > 0.01)
                            detailContentYAnimation.restart();
                        columnReflowTimer.restart();
                    }

                    function applySettledColumns() {
                        viewportResizeActive = false;
                        const nextColumns = _calculatedCols;
                        if (nextColumns === _cols)
                            return;

                        // Arm delegates before changing the GridView topology.
                        // Their visual geometry then moves once, after the
                        // high-frequency resize stream has stopped.
                        columnReflowActive = true;
                        prepareVisibleReflow();
                        _cols = nextColumns;
                        forceLayout();
                        startVisibleReflow();
                        columnReflowTimer.restart();
                        if (root.detailLayoutFocusActive)
                            root.scheduleCurrentWallpaperFocus();
                    }

                    // Drive the settle guard from every effective width
                    // sample, not only from the rare sample that crosses a
                    // column threshold.  A one-edge drag can remain inside
                    // the new column band for many frames; restarting here
                    // prevents an early reflow while that drag is still live.
                    on_AvailableWidthChanged: {
                        if (!_columnLatchReady) {
                            // Initial layout is not a user-visible reflow.
                            // Track it directly behind the hidden grid and
                            // arm normal resize latching only after it settles.
                            _cols = _calculatedCols;
                            initialColumnSettleTimer.restart();
                        } else {
                            scheduleColumnSettle();
                        }
                    }
                    Component.onCompleted: {
                        _cols = _calculatedCols;
                        initialColumnSettleTimer.restart();
                    }
                    Component.onDestruction: {
                        if (_diagnosticResizeActive)
                            W.Global.windowResizing = false;
                    }
                    onWidthChanged: {
                        if (root.detailLayoutFocusActive)
                            root.scheduleCurrentWallpaperFocus();
                    }
                    onCellWidthChanged: {
                        if (root.detailLayoutFocusActive)
                            root.scheduleCurrentWallpaperFocus();
                    }
                    onCellHeightChanged: {
                        if (root.detailLayoutFocusActive)
                            root.scheduleCurrentWallpaperFocus();
                    }

                    model: wallpaperQuery.data

                    delegate: WallpaperCard {
                        selected: model.selected ?? false
                        current: index === m_grid_view.currentIndex
                        pageActive: root.previewPageActive
                        animationSettled: m_grid_view.previewAnimationsSettled
                        reflowTransitionActive: m_grid_view.columnReflowActive
                        reflowReverse: root.detailCloseAnchorActive
                                       && !root.detailPanelOpen
                        itemWidth: m_grid_view._displayItemWidth
                        itemHeight: m_grid_view._displayItemHeight
                        onClicked: modifiers => root.handleWallpaperClick(index, modifiers)
                        onSelectionRequested: modifiers => root.requestWallpaperSelection(index)
                    }

                    Keys.onEscapePressed: event => {
                        if (root.selectionActive) {
                            root.clearWallpaperSelection();
                            event.accepted = true;
                        }
                    }

                    // Selection is painted by each card and cross-fades
                    // between delegates. GridView's separate highlight item
                    // can be recreated at the destination, which looks like
                    // an instantaneous focus teleport.
                    highlightFollowsCurrentItem: false
                    highlight: null
                }

                NumberAnimation {
                    id: detailContentYAnimation

                    target: m_grid_view
                    property: "contentY"
                    duration: 220
                    easing.type: root.detailPanelOpen ? Easing.OutCubic
                                                      : Easing.InCubic
                }

                Qml.Timer {
                    id: previewAnimationSettleTimer

                    interval: 140
                    repeat: false
                    onTriggered: {
                        if (!m_grid_view.moving && !m_grid_view.flicking)
                            m_grid_view.previewAnimationsSettled = true;
                    }
                }

                // A wheel animation can finish exactly at Flickable's extent
                // without producing another movement-ended edge. Recover the
                // thumbnail decoder state after contentY itself has stayed
                // quiet, independently of the scroll helper's boundary state.
                Qml.Timer {
                    id: previewBoundarySettleTimer

                    interval: 180
                    repeat: false
                    onTriggered: {
                        if (!m_grid_view.moving && !m_grid_view.flicking)
                            m_grid_view.previewAnimationsSettled = true;
                    }
                }

                Qml.Timer {
                    id: initialColumnSettleTimer

                    interval: 72
                    repeat: false
                    onTriggered: {
                        // Re-read after the final startup layout pass, then
                        // reveal already-correct delegates without a Behavior.
                        m_grid_view._cols = m_grid_view._calculatedCols;
                        m_grid_view.forceLayout();
                        m_grid_view._columnLatchReady = true;
                        m_grid_view._initialLayoutReady = true;
                    }
                }

                Qml.Timer {
                    id: columnSettleTimer

                    // A little over eleven 165 Hz frames: long enough to
                    // identify an active border drag, short enough for the
                    // final responsive reflow to feel immediate.
                    interval: 72
                    repeat: false
                    onTriggered: m_grid_view.applySettledColumns()
                }

                Qml.Timer {
                    id: columnReflowTimer

                    interval: 220
                    repeat: false
                    onTriggered: m_grid_view.columnReflowActive = false
                }

                Qml.Timer {
                    id: detailFocusTimer

                    // Coalesce panel progress, GridView width and animated
                    // cell-size changes into one layout/focus update per
                    // event-loop turn.
                    interval: 0
                    repeat: false
                    onTriggered: root.focusCurrentWallpaper()
                }

                Qml.Timer {
                    id: detailRestoreFocusTimer

                    // Let GridView publish delegate coordinates for the
                    // expanded column topology before deriving a smooth
                    // scroll target. This is short enough to be imperceptible
                    // at 60 Hz and spans several frames at 165 Hz.
                    interval: 24
                    repeat: false
                    onTriggered: {
                        if (!root.restoreDetailFocusPending || !m_grid_view
                                || m_grid_view.currentIndex < 0
                                || !m_grid_view.currentItem)
                            return;
                        m_grid_view.forceLayout();
                        const item = m_grid_view.currentItem;
                        const usableCenter = (m_grid_view.topMargin
                                              + m_grid_view.height
                                              - m_grid_view.bottomMargin) / 2;
                        const target = item.y + item.height / 2 - usableCenter;
                        root.smoothDetailFocusPending = false;
                        root.restoreDetailFocusPending = false;
                        root.detailRestoreFocusTargetY = target;
                        root.detailRestoreFocusScrollAccepted =
                            wallpaperDesktopWheel.scrollTo(target);
                    }
                }

                W.CupertinoFrostedBar {
                    id: wallpaperTopBar

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: scanProgress.visible ? 60 : 52
                    z: 20
                    blurSource: m_grid_view
                    // ShaderEffectSource consumes the GridView viewport, not
                    // its moving contentItem.  Keep this mapping in viewport
                    // coordinates so scrolling does not apply contentY a
                    // second time and geometry changes cannot shift the
                    // material vertically.
                    blurSourceRect: Qt.rect(wallpaperTopBar.x - m_grid_view.x,
                                            wallpaperTopBar.y - m_grid_view.y,
                                            wallpaperTopBar.width,
                                            wallpaperTopBar.height)
                    surfaceColor: W.Global.cupertinoCard
                    glassOpacity: 0.60
                    edgeShadowEnabled: false

                    // Toolbar
                    RowLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        height: 52
                        spacing: 8

                        W.CupertinoEmbedChip {
                            id: sortChip
                            text: root.sortOptions[root.sortIndex].name
                            trailingIconName: root.sortAsc ? MD.Token.icon.arrow_downward : MD.Token.icon.arrow_upward
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
                                    text: modelData.name
                                    icon.name: index === root.sortIndex ? (root.sortAsc ? MD.Token.icon.arrow_downward : MD.Token.icon.arrow_upward) : ' '
                                    onClicked: {
                                        root.pickSort(index);
                                        sortMenu.close();
                                    }
                                }
                            }
                        }

                        // Free-text search → wallpaperQuery.searchText.
                        // SearchChip debounces internally so this fires
                        // 1s after the user stops typing. Daemon-side
                        // the value becomes an extra `name CONTAINS`
                        // filter rule in its own group.
                        W.SearchChip {
                            id: m_search_field
                            Layout.preferredWidth: 120
                            placeholderText: qsTr("Search")
                            onTextEdited: wallpaperQuery.searchText = text
                        }

                        MD.ActionToolBar {
                            id: wallpaperActionToolBar
                            Layout.fillWidth: true
                            actions: [playlistListAction, tweakAction, filterAction, sourcesAction, refreshAction]
                        }
                    }

                    // Horizontal scan-progress strip below the toolbar.
                    // Only shown when the grid has wallpapers to display
                    // (the empty-state path uses the centered BusyIndicator).
                    MD.LinearIndicator {
                        id: scanProgress

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        anchors.bottomMargin: 4
                        visible: m_grid_view.count > 0 && W.Notify.scanInProgress
                        running: visible
                    }
                }

                MD.Button {
                    id: cancelSelectionButton

                    anchors.left: parent.left
                    anchors.top: wallpaperTopBar.bottom
                    anchors.leftMargin: 16
                    anchors.topMargin: 12
                    z: 21
                    visible: root.selectionActive
                    checked: true
                    text: String(root.selectedWallpaperCount)
                    icon.name: MD.Token.icon.close
                    mdState.type: MD.Enum.BtElevated
                    onClicked: root.clearWallpaperSelection()
                }

                MD.Loader {
                    anchors.centerIn: parent
                    active: m_grid_view.count === 0
                    sourceComponent: m_load_comp
                }

                Component {
                    id: m_load_comp

                        ColumnLayout {
                            spacing: 16
                            readonly property bool showLibraryHint: !wallpaperQuery.querying && !wallpaperQuery.hasActiveFilters && wallpaperQuery.searchText.trim().length === 0 && W.App.libraryManager.count === 0
                            readonly property int libraryHintSize: 22
                            readonly property string libraryHintIcon: '<font face="' + MD.Token.font.icon_family + '" style="font-size: ' + libraryHintSize + 'px;">' + sourcesAction.icon.name + '</font>'

                            MD.BusyIndicator {
                                Layout.alignment: Qt.AlignHCenter
                                running: wallpaperQuery.querying
                            }

                            MD.Text {
                                Layout.alignment: Qt.AlignHCenter
                                visible: !wallpaperQuery.querying
                                text: qsTr("No wallpapers found")
                                typescale: MD.Token.typescale.body_large
                                color: MD.Token.color.on_surface_variant
                            }

                            MD.Text {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: Math.max(0, Math.min(420, m_grid_view.width - 32))
                                visible: parent.showLibraryHint
                                text: qsTr("Click the %1 button in the top right to add a library.").arg(parent.libraryHintIcon)
                                textFormat: Text.RichText
                                typescale: MD.Token.typescale.body_medium
                                color: MD.Token.color.on_surface_variant
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                            }

                            MD.BusyButton {
                                Layout.alignment: Qt.AlignHCenter
                                // Only offer auto-detect when the empty grid is
                                // genuinely "fresh user, nothing configured" —
                                // not when filters are excluding existing rows
                                // and not when libraries are already registered
                                // (in that case the user wants Refresh, not a
                                // second round of auto-detection).
                                visible: parent.showLibraryHint
                                text: qsTr("Auto detect libraries")
                                busy: autoDetectQuery.querying
                                mdState.type: MD.Enum.BtFilledTonal
                                onClicked: {
                                    if (!busy)
                                        autoDetectQuery.reload();
                                }
                            }
                        }
                    }
                }
            }

        // --- Right: wallpaper detail panel ---
        Item {
            id: detailPanelContainer

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: wallpaperSplitView.detailWidth
            visible: root.detailPanelOpen || root.detailPanelProgress > 0.001
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

                contentItem: WallpaperDetailPanel {
                    objectName: "wallpaperDetailPanel"
                    wallpaperId: root.detailWallpaper?.id_proto ?? ""
                    fallbackWallpaper: root.detailWallpaper
                    showApply: true
                    onBack: root.selectedWallpaper = null
                }
            }
        }
    }

    Component {
        id: wallpaperSelectSheetComponent

        W.SelectSheet {
            popupParent: root
            blurSource: root.contentItem
            relay: wallpaperSelectSheetRelay
            currentWallpaperSelect: root.currentWallpaperSelect
        }
    }

    Component {
        id: wallpaperTweakSheetComponent

        W.TweakSheet {
            popupParent: root
            blurSource: root.contentItem
            tweak: wallpaperTweakState
        }
    }

    Component {
        id: playlistListSheetComponent

        W.PlaylistListSheet {
            popupParent: root
            blurSource: root.contentItem
            sheetState: playlistListSheetState
        }
    }

    Component {
        id: playlistSelectDetailComponent

        PlaylistDetailPanel {
            width: parent ? parent.width : implicitWidth
            playlist: playlistWallpaperSelect.playlistEditTarget
            mutation: playlistDetailMutation
        }
    }

    Component {
        id: newPlaylistSheetComponent

        W.NewPlaylistSheetContent {
            sheetState: selectSheetContentState
        }
    }

    Component {
        id: addToPlaylistSheetComponent

        W.AddToPlaylistSheetContent {
            sheetState: selectSheetContentState
        }
    }
}
