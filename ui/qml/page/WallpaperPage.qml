pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtQuick
import QtQml as Qml
import QtQuick.Layouts
import QtQuick.Templates as T
import Qcm.Material as MD
import waywallen.control as WC
import waywallen.ui as W

MD.Page {
    id: root

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
            root.forceWallpaperGridLayout();
        }
        function onItemAspectRatioChanged() {
            root.forceWallpaperGridLayout();
        }
        function onLayoutModeChanged() {
            root.forceWallpaperGridLayout();
        }
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

    function prepareDetailClose() {
        if (root.selectionActive || root.detailWallpaper === null
                || m_grid_view.currentIndex < 0)
            return;
        root.restoreDetailFocusPending = true;
        root.smoothDetailFocusPending = true;
        root.detailCloseAnchorActive = true;
    }

    function synchronizeDetailGridLayout() {
        if (m_grid_view)
            m_grid_view.beginDetailLayout(root.detailPanelOpen);
    }

    function closeWallpaperDetail() {
        root.prepareDetailClose();
        root.selectedWallpaper = null;
        // Signal delivery normally performs the same update.  Keep this
        // explicit reconciliation for the detail panel's reverse transition:
        // its grid target must never remain in the narrow detail topology
        // after the panel itself has closed.
        root.synchronizeDetailGridLayout();
    }

    property var selectedWallpaper: null
    // Retain the outgoing model while the split view closes; otherwise the
    // detail surface would turn blank before its reverse transition finishes.
    property var detailWallpaper: null
    readonly property bool detailPanelOpen: root.selectedWallpaper !== null
                                          && !root.selectionActive
    property bool detailGridLayoutOpen: false
    property real detailPanelProgress: root.detailPanelOpen ? 1.0 : 0.0
    property bool smoothDetailFocusPending: false
    property bool restoreDetailFocusPending: false
    property bool detailCloseAnchorActive: false
    readonly property bool detailLayoutFocusActive: root.detailWallpaper !== null
                                                    && (root.detailPanelProgress > 0.001
                                                        || detailPanelAnimation.running)
    readonly property bool previewPageActive: T.StackView.status === T.StackView.Active

    Behavior on detailPanelProgress {
        NumberAnimation {
            id: detailPanelAnimation
            duration: 220
            easing.type: root.detailPanelOpen ? Easing.OutCubic : Easing.InCubic
            onRunningChanged: {
                if (running) {
                    m_grid_view.previewAnimationsSettled = false;
                    previewAnimationSettleTimer.stop();
                } else {
                    previewAnimationSettleTimer.restart();
                    root.synchronizeDetailGridLayout();
                    if (root.detailPanelProgress <= 0.001
                            && root.selectedWallpaper === null) {
                        root.detailCloseAnchorActive = false;
                        root.detailWallpaper = null;
                    }
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
        } else {
            // GridView retains currentIndex after the detail closes.  Keep
            // that card on a nearest visible row while the columns expand.
            root.prepareDetailClose();
        }
        root.synchronizeDetailGridLayout();
        root.scheduleCurrentWallpaperFocus();
    }

    onDetailPanelOpenChanged: root.synchronizeDetailGridLayout()

    function scheduleCurrentWallpaperFocus() {
        if (m_grid_view.currentIndex < 0 || root.detailCloseAnchorActive)
            return;
        if (detailPanelAnimation.running)
            return;
        detailFocusTimer.restart();
    }

    function focusCurrentWallpaper() {
        if (m_grid_view.currentIndex < 0
                || (!root.detailLayoutFocusActive
                    && !root.restoreDetailFocusPending))
            return;
        m_grid_view.forceLayout();
        if (!m_grid_view.currentItem)
            return;
        const target = m_grid_view.nearestVisibleContentY(
            m_grid_view.currentItem, NaN);
        root.smoothDetailFocusPending = false;
        root.restoreDetailFocusPending = false;
        if (Math.abs(target - m_grid_view.contentY) > 0.5)
            wallpaperDesktopWheel.scrollTo(target);
    }
    property var currentWallpaperSelect: null
    property var wallpaperSelectSheet: null
    property var wallpaperTweakSheet: null
    property var playlistListSheet: null
    property var filterPresentation: null
    Component.onDestruction: root.filterPresentation?.cancel()
    readonly property int selectionSheetReserve: wallpaperSelectSheetRelay.currentComponent ? 360 : 160
    readonly property int selectedWallpaperCount: root.currentWallpaperSelect ? root.currentWallpaperSelect.selectedCount : 0
    readonly property int removableSelectedWallpaperCount: root.currentWallpaperSelect ? root.currentWallpaperSelect.removableSelectedCount : 0
    readonly property bool selectionActive: root.currentWallpaperSelect ? root.currentWallpaperSelect.active : false
    readonly property bool selectionActionSheetActive: root.selectionActive && root.currentWallpaperSelect && (root.currentWallpaperSelect.actions || []).length > 0

    onSelectionActiveChanged: {
        if (selectionActive) {
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
        for (const display of W.App.displayManager.displays || []) {
            if (display.selectableTarget) {
                targets.push({
                    targetId: "display:" + display.id,
                    targetLabel: root.rawDisplayLabel(display),
                    targetIcon: MD.Token.icon.monitor,
                    target: { displayId: display.id },
                    displayIds: [display.id]
                });
            }
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
        const targets = [display.target];
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

        m_grid_view.currentIndex = index;
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

    contentItem: Item {
        id: wallpaperSplitView

        // Drive the master/detail geometry directly.  RowLayout performs
        // several preferred-size negotiations for every fractional width,
        // which makes a dense GridView visibly rewrap more than once.
        readonly property real detailWidth: 280 * root.detailPanelProgress
        readonly property real detailGap: 12 * root.detailPanelProgress

        // --- Left: wallpaper grid ---
        MD.Pane {
            id: wallpaperMasterPane
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.max(0, parent.width
                            - wallpaperSplitView.detailWidth
                            - wallpaperSplitView.detailGap)
            radius: root.MD.MProp.page.backgroundRadius
            padding: 0
            showBackground: true

            contentItem: ColumnLayout {
                spacing: 0

                // Toolbar
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 4
                    spacing: 8

                    MD.EmbedChip {
                        id: sortChip
                        text: root.sortOptions[root.sortIndex].name
                        trailingIconName: root.sortAsc ? MD.Token.icon.arrow_downward : MD.Token.icon.arrow_upward
                        mdState.borderWidth: 1
                        onClicked: sortMenu.open()

                        MD.Menu {
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
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.topMargin: 4
                    visible: m_grid_view.count > 0 && W.Notify.scanInProgress
                    running: visible
                }

                // Grid + centered empty-state overlay
                Item {
                    id: wallpaperGridArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    MD.VerticalGridView {
                        id: m_grid_view
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        // Use the destination width for the one grid reflow;
                        // the master pane above clips the animated surface.
                        width: _targetViewportWidth
                        clip: false
                        focus: true
                        focusPolicy: Qt.StrongFocus
                        keyNavigationEnabled: true
                        keyNavigationWraps: true
                        currentIndex: -1
                        highlightRangeMode: GridView.NoHighlightRange
                        synchronousDrag: false
                        pixelAligned: false
                        reuseItems: !columnReflowActive
                        cacheBuffer: columnReflowActive || detailPanelAnimation.running
                                     ? Math.max(height + cellHeight,
                                                Math.ceil(cellHeight * 1.25))
                                     : Math.max(96, Math.ceil(cellHeight * 1.25))
                        displayMarginBeginning: 0
                        displayMarginEnd: 0
                        topMargin: 2
                        bottomMargin: root.selectionActionSheetActive ? root.selectionSheetReserve : 8
                        leftMargin: 8
                        rightMargin: 8
                        visible: m_grid_view.count > 0 && _initialLayoutReady

                        property bool previewAnimationsSettled: true
                        property int _cols: 1
                        property bool _initialLayoutReady: false
                        property bool _columnLatchReady: false
                        property bool columnReflowActive: false
                        readonly property real _targetViewportWidth: Math.max(
                            0, wallpaperSplitView.width
                            - (root.detailGridLayoutOpen ? 292 : 0))
                        readonly property real _availableWidth: Math.max(
                            0, _targetViewportWidth - leftMargin - rightMargin)
                        readonly property int _calculatedCols: Math.max(
                            1, Math.floor(_availableWidth / wallpaperTweakState.itemSize))
                        readonly property real _stretchedItemWidth: _availableWidth / _cols
                        readonly property bool _fillCell: wallpaperTweakState.layoutMode === wallpaperTweakState.layoutFillCell
                        readonly property real _displayItemWidth: _fillCell ? _stretchedItemWidth : Math.min(wallpaperTweakState.itemSize, _stretchedItemWidth)
                        readonly property real _displayItemHeight: _displayItemWidth / Math.max(wallpaperTweakState.itemAspectRatio, 0.1)
                        cellWidth: _stretchedItemWidth
                        cellHeight: _fillCell ? _displayItemHeight : wallpaperTweakState.itemHeight

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

                        function forEachPreparedDelegate(callback) {
                            const children = contentItem?.children || [];
                            for (let i = 0; i < children.length; ++i) {
                                const delegate = children[i];
                                if (delegate && delegate.objectName === "wallpaperCard")
                                    callback(delegate);
                            }
                        }

                        function cardSceneCenter(item) {
                            if (!item)
                                return NaN;
                            const cardHeight = Math.min(item.itemHeight,
                                                        item.height);
                            return item.y + (item.height - cardHeight) / 2
                                   - contentY + cardHeight / 2;
                        }

                        function nearestVisibleContentY(item, preferredSceneCenter) {
                            if (!item)
                                return contentY;
                            const cardHeight = Math.min(item.itemHeight, item.height);
                            const visibleTop = topMargin;
                            const visibleBottom = Math.max(visibleTop, height - bottomMargin);
                            const latestTop = Math.max(visibleTop, visibleBottom - cardHeight);
                            const currentCenter = item.y + (item.height - cardHeight) / 2
                                                - contentY + cardHeight / 2;
                            const requestedCenter = Number.isFinite(preferredSceneCenter)
                                                  ? preferredSceneCenter : currentCenter;
                            const sceneTop = Math.max(visibleTop, Math.min(
                                latestTop, requestedCenter - cardHeight / 2));
                            const target = item.y + (item.height - cardHeight) / 2 - sceneTop;
                            const minimum = originY - topMargin;
                            const maximum = Math.max(minimum,
                                originY + contentHeight + bottomMargin - height);
                            return Math.max(minimum, Math.min(maximum, target));
                        }

                        function reflowTo(columns) {
                            if (columns === _cols)
                                return;
                            columnReflowActive = true;
                            forEachPreparedDelegate(function (delegate) {
                                delegate.prepareReflow();
                            });
                            _cols = columns;
                            forceLayout();
                            forEachPreparedDelegate(function (delegate) {
                                delegate.startPreparedReflow();
                            });
                            columnReflowTimer.restart();
                        }

                        function beginDetailLayout(open) {
                            if (root.detailGridLayoutOpen === open)
                                return;
                            columnSettleTimer.stop();
                            if (!_initialLayoutReady) {
                                root.detailGridLayoutOpen = open;
                                _cols = _calculatedCols;
                                return;
                            }

                            // Capture every visible card before changing the
                            // grid topology. The reflow then starts from the
                            // card's current scene position instead of the
                            // destination cell, which keeps the detail pane
                            // transition anchored just like the main branch.
                            const anchoredClose = !open
                                                  && root.detailCloseAnchorActive
                                                  && currentIndex >= 0;
                            const anchoredItem = currentIndex >= 0
                                                 ? currentItem : null;
                            const preferredSceneCenter = cardSceneCenter(
                                anchoredItem);
                            columnReflowActive = false;
                            columnReflowActive = true;
                            forEachPreparedDelegate(function (delegate) {
                                delegate.prepareReflow();
                            });
                            root.detailGridLayoutOpen = open;
                            _cols = _calculatedCols;
                            if (currentIndex >= 0) {
                                wallpaperDesktopWheel.cancel();
                                forceLayout();
                                const anchored = nearestVisibleContentY(
                                    currentItem, preferredSceneCenter);
                                contentY = anchored;
                                if (anchoredClose) {
                                    root.restoreDetailFocusPending = false;
                                    root.smoothDetailFocusPending = false;
                                }
                            }
                            forceLayout();
                            forEachPreparedDelegate(function (delegate) {
                                delegate.startPreparedReflow();
                            });
                            columnReflowTimer.restart();
                        }

                        function applySettledColumns() {
                            reflowTo(_calculatedCols);
                        }

                        on_AvailableWidthChanged: {
                            if (!_columnLatchReady) {
                                _cols = _calculatedCols;
                                initialColumnSettleTimer.restart();
                            } else if (!detailPanelAnimation.running) {
                                columnSettleTimer.restart();
                            }
                        }
                        Component.onCompleted: {
                            _cols = _calculatedCols;
                            initialColumnSettleTimer.restart();
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

                        highlightFollowsCurrentItem: true
                        highlight: Component {
                            Item {
                                visible: m_grid_view.currentItem !== null
                                z: 2
                                // Inset 2 = 6 (card margin) − 4 (ring outset),
                                // so the ring sits 4px outside the image
                                // control with the same concentric radius.
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    color: "transparent"
                                    border.color: MD.Token.color.primary
                                    border.width: 3
                                    radius: MD.Token.shape.corner.extra_small + 4
                                }
                            }
                        }
                    }

                    W.DesktopWheelScroll {
                        id: wallpaperDesktopWheel
                        anchors.fill: parent
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

                    Qml.Timer {
                        id: previewAnimationSettleTimer
                        interval: 140
                        repeat: false
                        onTriggered: {
                            if (!m_grid_view.moving && !m_grid_view.flicking
                                    && !wallpaperDesktopWheel.scrolling)
                                m_grid_view.previewAnimationsSettled = true;
                        }
                    }

                    Qml.Timer {
                        id: previewBoundarySettleTimer
                        interval: 180
                        repeat: false
                        onTriggered: {
                            if (!m_grid_view.moving && !m_grid_view.flicking
                                    && !wallpaperDesktopWheel.scrolling)
                                m_grid_view.previewAnimationsSettled = true;
                        }
                    }

                    Qml.Timer {
                        id: initialColumnSettleTimer
                        interval: 72
                        repeat: false
                        onTriggered: {
                            m_grid_view._cols = m_grid_view._calculatedCols;
                            m_grid_view.forceLayout();
                            m_grid_view._columnLatchReady = true;
                            m_grid_view._initialLayoutReady = true;
                        }
                    }

                    Qml.Timer {
                        id: columnSettleTimer
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
                        interval: 24
                        repeat: false
                        onTriggered: root.focusCurrentWallpaper()
                    }

                    MD.Button {
                        id: cancelSelectionButton
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.leftMargin: 16
                        anchors.topMargin: 12
                        z: 10
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
        }

        // --- Right: wallpaper detail panel ---
        Item {
            id: wallpaperDetailPanelContainer
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: wallpaperSplitView.detailWidth
            visible: root.detailWallpaper !== null || root.detailPanelProgress > 0.001
            clip: true

            MD.Pane {
                width: 280
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                radius: root.MD.MProp.page.backgroundRadius
                padding: 0
                showBackground: true
                // Present the detail surface early while the shared split
                // geometry continues its stable 220 ms transition.  A 1:1
                // opacity binding made the sidebar look delayed even though
                // its width was already moving.
                opacity: Math.min(1, root.detailPanelProgress * 1.35)
                enabled: root.detailPanelProgress > 0.98

                transform: Translate {
                    // Retain the same small leading offset as main so the
                    // detail surface and the preview compression read as one
                    // transition rather than two independent animations.
                    x: (1 - root.detailPanelProgress) * 18
                }

                contentItem: WallpaperDetailPanel {
                    wallpaperId: root.detailWallpaper?.id_proto ?? ""
                    fallbackWallpaper: root.detailWallpaper
                    showApply: true
                    onBack: root.closeWallpaperDetail()
                }
            }
        }
    }

    Component {
        id: wallpaperSelectSheetComponent

        W.SelectSheet {
            popupParent: root
            relay: wallpaperSelectSheetRelay
            currentWallpaperSelect: root.currentWallpaperSelect
        }
    }

    Component {
        id: wallpaperTweakSheetComponent

        W.TweakSheet {
            popupParent: root
            tweak: wallpaperTweakState
        }
    }

    Component {
        id: playlistListSheetComponent

        W.PlaylistListSheet {
            popupParent: root
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
