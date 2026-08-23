import QtQuick
import org.kde.kwin as KWinComponents

// Transient compositor-side resize driver used by analyze_resize_trace.py.
// Load it through org.kde.kwin.Scripting.loadDeclarativeScript while a single
// diagnostic waywallen window is open. It changes only that window's right
// edge, never the pointer, focus, or any other desktop surface.
Item {
    id: root

    property var targetWindow: null
    property rect originalGeometry: Qt.rect(0, 0, 0, 0)
    property int frame: 0
    readonly property int frameCount: 180
    readonly property int widthStep: 3

    Timer {
        id: resizeTimer

        interval: 6
        repeat: true
        onTriggered: {
            if (!root.targetWindow) {
                stop();
                return;
            }
            if (root.frame >= root.frameCount) {
                root.targetWindow.frameGeometry = root.originalGeometry;
                console.info("waywallen kwin resize probe: complete frames="
                             + root.frameCount);
                stop();
                return;
            }

            const distanceSteps = Math.min(root.frame + 1,
                                           root.frameCount - root.frame - 1);
            const geometry = root.originalGeometry;
            root.targetWindow.frameGeometry = Qt.rect(
                geometry.x, geometry.y,
                geometry.width - distanceSteps * root.widthStep,
                geometry.height);
            ++root.frame;
        }
    }

    Component.onCompleted: {
        const windows = KWinComponents.Workspace.stackingOrder;
        for (let index = windows.length - 1; index >= 0; --index) {
            if (String(windows[index].caption).indexOf("waywallen") < 0)
                continue;
            root.targetWindow = windows[index];
            break;
        }
        if (!root.targetWindow) {
            console.warn("waywallen kwin resize probe: target window not found");
            return;
        }
        root.originalGeometry = root.targetWindow.frameGeometry;
        console.info("waywallen kwin resize probe: start geometry="
                     + root.originalGeometry);
        resizeTimer.start();
    }
}
