import AppKit

/// Watches the left mouse button system-wide and can swallow it while a preview is being dragged.
/// Runs on its own thread so that a slow app or busy main thread can never stall the user's mouse.
final class EventTap {
    enum Kind { case down, widgetDown, dragged, up, moved }

    private static let syntheticMarker: Int64 = 0x53504D45

    var onEvent: ((Kind, CGPoint, TimeInterval) -> Void)?

    private let lock = NSLock()
    private var suppressing = false
    private var widgetFrames: [CGRect] = []
    private var cursorWasOverWidget = false
    private var machPort: CFMachPort?

    func setWidgetFrames(_ frames: [CGRect]) {
        lock.withLock { widgetFrames = frames }
    }

    /// Ends the app's native window drag. From here until the real button release, the mouse events
    /// are hidden from apps, and the rest of the gesture is ours.
    func takeOverDrag(at point: CGPoint) {
        lock.withLock { suppressing = true }
        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        up.post(tap: .cgSessionEventTap)
    }

    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        machPort = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        let time = ProcessInfo.processInfo.systemUptime

        if type == .mouseMoved {
            // Moves are constant, so the main thread only hears about those that touch a widget.
            lock.lock()
            let isOverWidget = widgetFrames.contains { $0.contains(point) }
            let shouldReport = isOverWidget || cursorWasOverWidget
            cursorWasOverWidget = isOverWidget
            lock.unlock()
            if shouldReport {
                DispatchQueue.main.async { [weak self] in self?.onEvent?(.moved, point, time) }
            }
            return Unmanaged.passUnretained(event)
        }

        let kind: Kind
        var swallow = false

        lock.lock()
        switch type {
        case .leftMouseDown:
            if widgetFrames.contains(where: { $0.contains(point) }) {
                suppressing = true
                swallow = true
                kind = .widgetDown
            } else {
                // A new press always clears any stale state, so a click can never get lost for good.
                suppressing = false
                kind = .down
            }
        case .leftMouseDragged:
            swallow = suppressing
            kind = .dragged
        default:
            swallow = suppressing
            suppressing = false
            kind = .up
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.onEvent?(kind, point, time) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
