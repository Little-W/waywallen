pragma Singleton
import QtCore
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

// App-wide singleton state and derived theming.
QtObject {
    id: root

    property bool sidebarAutoExpand: true
    // Ephemeral scene state used while the desktop shell changes width. It is
    // deliberately not persisted: animated previews can pause for this short
    // transition without changing a user's wallpaper settings.
    property bool sidebarAnimating: false
    // Live top-level Wayland configure bursts are treated as one transient
    // scene state. Expensive backdrop effects can pause without changing any
    // persisted appearance setting, then resume after geometry settles.
    property bool windowResizing: false
    // Internal split-view geometry (currently the wallpaper detail panel) can
    // animate at the output refresh rate without also decoding GIFs or
    // rebuilding a live backdrop texture on every intermediate width.
    property bool contentGeometryAnimating: false
    // Volatile copy of the wallpaper library's resolved grid settings. The
    // Discover page uses this only until its own layout is explicitly changed;
    // keeping the bridge in memory avoids constructing a second QSettings
    // writer for WallpaperView during startup.
    property bool wallpaperGridTweakReady: false
    property int wallpaperGridItemSize: 162
    property real wallpaperGridItemAspectRatio: 1
    property int wallpaperGridLayoutMode: 0
    // Compact navigation is an overlay rather than a layout row. Pages use
    // this transient safe inset so their final item can scroll above it while
    // ordinary content still travels beneath the live material.
    property real compactNavigationInset: 0
    property int networkCacheMaximumMiB: 1024
    property string themeMode: "system"
    // Cupertino's default blue. Users can still switch back to the system
    // accent or choose any custom color from Settings.
    readonly property color defaultAccentColor: "#0A84FF"
    property string accentMode: "custom"
    property color accentColor: defaultAccentColor
    property string lastOpenedVersion: ""
    // Custom accent is intentionally used directly by high-salience controls
    // such as switches.  For the system mode, defer to Qcm's resolved token.
    readonly property color effectiveAccentColor: accentMode === "custom"
        ? accentColor
        : MD.Token.color.primary

    // Keep the desktop shell neutral rather than deriving its large surfaces
    // from Material's accent-seeded tonal palette. Qcm still supplies the
    // controls, typography, interaction states and dynamic accent colors.
    readonly property bool cupertinoDark: MD.Token.isDarkTheme
    readonly property color cupertinoCanvas: cupertinoDark ? "#1C1C1E" : "#F7F7FA"
    readonly property color cupertinoSidebar: cupertinoDark ? "#242426" : "#F5F5F7"
    readonly property color cupertinoCard: cupertinoDark ? "#2C2C2E" : "#FFFFFF"
    readonly property color cupertinoBorder: cupertinoDark ? "#3A3A3C" : "#D1D1D6"
    // Glass surfaces meet through this opaque seam.  It intentionally stays
    // white in the light design so wallpaper never leaks through structural
    // joins between the sidebar, title bar and content canvas.
    readonly property color cupertinoSeam: cupertinoDark ? "#3A3A3C" : "#FFFFFF"
    readonly property color cupertinoControlFill: cupertinoDark ? "#3A3A3C" : "#E8E8ED"

    onNetworkCacheMaximumMiBChanged:
        W.App.setNetworkCacheMaximumSize(networkCacheMaximumMiB * 1024 * 1024)
    onThemeModeChanged: _applyThemeMode()
    onAccentModeChanged: _applyAccentColor()
    onAccentColorChanged: {
        if (accentMode === "custom")
            _applyAccentColor();
    }

    Component.onCompleted: {
        W.App.setNetworkCacheMaximumSize(networkCacheMaximumMiB * 1024 * 1024)
        setThemeMode(themeMode)
        setAccentMode(accentMode)
    }

    function setThemeMode(mode) {
        const normalized = mode === "light" || mode === "dark" ? mode : "system";
        if (themeMode !== normalized)
            themeMode = normalized;
        else
            _applyThemeMode();
    }

    function _applyThemeMode() {
        const system = themeMode === "system";
        MD.Token.color.useSysColorSM = system;
        if (!system)
            MD.Token.themeMode = themeMode === "dark" ? MD.Enum.Dark : MD.Enum.Light;
    }

    function setAccentMode(mode) {
        const normalized = mode === "custom" ? "custom" : "system";
        if (accentMode !== normalized)
            accentMode = normalized;
        else
            _applyAccentColor();
    }

    function _applyAccentColor() {
        const system = accentMode === "system";
        MD.Token.color.useSysAccentColor = system;
        if (!system)
            MD.Token.color.accentColor = accentColor;
    }

    function recordOpenedVersion(version) {
        if (version.length === 0)
            return false;
        const previous = lastOpenedVersion;
        if (previous !== version)
            lastOpenedVersion = version;
        return previous.length > 0 && previous !== version;
    }

    readonly property Component errorToastAction: Component {
        MD.Action {
            required property string error
            text: qsTr("Copy")
            onTriggered: {
                W.Action.copyToClipboard(error);
                W.Action.toast(qsTr("Copied to clipboard"), 2000);
            }
        }
    }

    function toastError(error) {
        const action = errorToastAction.createObject(root, {
            error: error
        });
        W.Action.toast(error, 0, MD.Enum.TFCloseable, action);
    }

    readonly property Settings _generalSettings: Settings {
        property alias sidebarAutoExpand: root.sidebarAutoExpand
        property alias networkCacheMaximumMiB: root.networkCacheMaximumMiB
        property alias themeMode: root.themeMode
        property alias accentMode: root.accentMode
        property alias accentColor: root.accentColor
        property alias lastOpenedVersion: root.lastOpenedVersion
    }

    // Per-vendor Material color schemes, seeded from each GPU vendor's brand
    // color and tracking the app theme mode, so vendor chips stay legible in
    // light and dark.
    readonly property QtObject gpu: QtObject {
        // PCI vendor IDs: AMD 0x1002, NVIDIA 0x10de, Intel 0x8086.
        readonly property MD.MdColorMgr amd: MD.MdColorMgr {
            accentColor: Qt.rgba(0.86, 0.20, 0.20, 1.0)
            mode: MD.Token.color.mode
            useSysColorSM: MD.Token.color.useSysColorSM
        }
        readonly property MD.MdColorMgr nvidia: MD.MdColorMgr {
            accentColor: Qt.rgba(0.27, 0.66, 0.20, 1.0)
            mode: MD.Token.color.mode
            useSysColorSM: MD.Token.color.useSysColorSM
        }
        readonly property MD.MdColorMgr intel: MD.MdColorMgr {
            accentColor: Qt.rgba(0.20, 0.45, 0.85, 1.0)
            mode: MD.Token.color.mode
            useSysColorSM: MD.Token.color.useSysColorSM
        }

        function forVendor(vendorId) {
            if (vendorId === 0x1002)
                return amd;
            if (vendorId === 0x10de)
                return nvidia;
            if (vendorId === 0x8086)
                return intel;
            return null;
        }
    }
}
