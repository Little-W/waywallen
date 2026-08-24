pragma ComponentBehavior: Bound
import QtQuick
import waywallen.ui as W

// Continuous scrolling for discrete desktop wheel events.
// Pixel-delta touchpad gestures remain on Flickable's native one-to-one path.
Item {
    id: root

    // Do not give an inert helper the size of a normal, non-scrollable
    // content item. It must not take part in a plain page's child geometry
    // when there is no Flickable for the wheel handler to control.
    x: 0
    y: 0
    width: enabled && parent ? parent.width : 0
    height: enabled && parent ? parent.height : 0
    visible: enabled

    // A page supplies its scrolling content after construction. Without one,
    // the helper stays inert and does not manufacture another scroll surface.
    property Flickable flickable: null
    enabled: root.flickable !== null && root.flickable.interactive

    property real wheelStep: Math.max(24, Qt.styleHints.wheelScrollLines * 24)
    property alias angularFrequency: animator.angularFrequency
    readonly property alias scrolling: animator.scrolling

    function cancel() {
        animator.cancel();
    }

    function scrollBy(delta) {
        return animator.scrollBy(delta);
    }

    function scrollTo(position) {
        return animator.scrollTo(position);
    }

    W.WheelScrollAnimator {
        id: animator
        flickable: root.flickable
        // C++ owns the trajectory and preserves velocity when wheel events
        // retarget it. The clock below advances it exactly once per render
        // frame instead of producing invisible sub-frame Timer writes.
        angularFrequency: 40
    }

    FrameAnimation {
        running: animator.scrolling
        onTriggered: animator.advance(frameTime)
    }

    WheelHandler {
        target: null
        orientation: Qt.Vertical
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        blocking: true

        onWheel: function(event) {
            // Device type is unreliable for some Wayland receivers: select
            // the path from the actual delta precision instead.
            if (event.pixelDelta.y !== 0 || event.angleDelta.y === 0) {
                event.accepted = false;
                return;
            }

            const inversion = event.inverted ? -1 : 1;
            const ticks = event.angleDelta.y * inversion / 120.0;
            event.accepted = root.scrollBy(-ticks * root.wheelStep);
        }
    }

}
