import SwiftUI
import UIKit

/// The virtual touchscreen: a transparent view laid over the display that
/// turns real UIKit touches into `InputEvent`s in the device's own
/// 640×960 coordinates.
///
/// This deliberately bypasses SwiftUI gestures. A `DragGesture` only
/// tracks one finger, has no cancellation path (an interrupted gesture
/// leaves the guest believing a finger is still down), and can swallow or
/// miss quick taps. Real touch tracking gives began/moved/ended/cancelled
/// per finger, with UIKit guaranteeing an end (or cancel) for every
/// begin — so the guest can never be left with a stuck finger.
struct TouchCaptureView: UIViewRepresentable {
    var onEvent: (InputEvent) -> Void

    func makeUIView(context: Context) -> TouchCaptureUIView {
        let view = TouchCaptureUIView()
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ view: TouchCaptureUIView, context: Context) {
        view.onEvent = onEvent
    }
}

final class TouchCaptureUIView: UIView {
    var onEvent: ((InputEvent) -> Void)?

    /// Host touch IDs, stable for a touch's lifetime.
    private var touchIDs: [UITouch: Int] = [:]
    private var nextTouchID = 0

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = nextTouchID
            nextTouchID += 1
            touchIDs[touch] = id
            onEvent?(.touchBegan(point(for: touch, id: id)))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs[touch] else { continue }
            onEvent?(.touchMoved(point(for: touch, id: id)))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    /// Every begin gets an end: a cancelled touch reads as a lift, never a
    /// finger held down forever.
    private func end(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: touch) else { continue }
            onEvent?(.touchEnded(point(for: touch, id: id)))
        }
    }

    /// Maps a point in this view to the device's own pixels (portrait,
    /// origin top-left), clamping drags that leave the display to its edge.
    private func point(for touch: UITouch, id: Int) -> TouchPoint {
        let location = touch.location(in: self)
        let width = bounds.width, height = bounds.height
        guard width > 0, height > 0 else { return TouchPoint(x: 0, y: 0, touchID: id) }
        let x = min(max(location.x / width, 0), 1) * Double(GuestMemoryLayout.framebufferWidth)
        let y = min(max(location.y / height, 0), 1) * Double(GuestMemoryLayout.framebufferHeight)
        return TouchPoint(x: x, y: y, touchID: id)
    }
}
