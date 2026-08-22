pragma ComponentBehavior: Bound
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

// Full settings page used by the display details' quick wallpaper entry.
// Keeping it in a PagePopup lets the user return to the selected display
// without changing the wallpaper library selection.
MD.Page {
    id: root

    title: qsTr("Wallpaper settings")
    implicitWidth: 520
    implicitHeight: 640
    // A popup has no scrolling page chrome of its own. Keep the app bar
    // elevated and opaque so the title remains readable above the preview.
    scrolling: true

    property string wallpaperId: ""
    property var fallbackWallpaper: null

    contentItem: WallpaperDetailPanel {
        wallpaperId: root.wallpaperId
        fallbackWallpaper: root.fallbackWallpaper
        showApply: false
        onBack: MD.Util.closePopup(root.MD.MProp.page)
    }
}
