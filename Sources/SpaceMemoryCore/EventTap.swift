import AppKit

/// Watches the left mouse button system-wide and can swallow its events.
/// Runs on its own thread so a busy main thread can't stall the mouse.
final class EventTap {
    enum Kind { case down, cardDown, dragged, up, moved }

    private static let syntheticMarker: Int64 = 0x53504D45

    var onEvent: ((Kind, CGPoint, TimeInterval) -> Void)?

    private let lock = NSLock()
    private var suppressing = false
    private var cardFrames: [CGRect] = []
    private var cursorWasOverCard = false
    private var machPort: CFMachPort?

    func setCardFrames(_ frames: [CGRect]) {
        lock.withLock { cardFrames = frames }
    }

    /// Ends the app's native window drag, and hides mouse events from apps until the button is released.
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
            // Only moves over a card are forwarded to the main thread.
            lock.lock()
            let isOverCard = cardFrames.contains { $0.contains(point) }
            let shouldReport = isOverCard || cursorWasOverCard
            cursorWasOverCard = isOverCard
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
            if cardFrames.contains(where: { $0.contains(point) }) {
                suppressing = true
                swallow = true
                kind = .cardDown
            } else {
                // Clears any stale state.
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
