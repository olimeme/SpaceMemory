import AppKit
import ApplicationServices

// Private but long-stable; every macOS window manager uses it, as there is no public AX-to-CGWindowID mapping.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Another app's window, controlled through the Accessibility API.
final class AXWindow {
    let element: AXUIElement
    let id: CGWindowID
    let pid: pid_t

    init?(element: AXUIElement, pid: pid_t) {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else { return nil }
        self.element = element
        self.id = windowID
        self.pid = pid
        AXUIElementSetMessagingTimeout(element, 0.25)
    }

    var appName: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)" }

    var origin: CGPoint? {
        guard let value = copyAttribute(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value = copyAttribute(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    var frame: CGRect? {
        guard let origin, let size else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var title: String { (copyAttribute(kAXTitleAttribute) as? String) ?? "" }

    var isFullScreen: Bool { (copyAttribute("AXFullScreen") as? Bool) ?? false }

    var isStandard: Bool {
        (copyAttribute(kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
    }

    @discardableResult
    func setOrigin(_ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    func setFrame(_ frame: CGRect) {
        // Moving first makes room for growth at the screen edge; sizing again corrects any clamping.
        setOrigin(frame.origin)
        setSize(frame.size)
        setOrigin(frame.origin)
        setSize(frame.size)
    }

    /// Native full screen, which puts the window in its own Space.
    func setFullScreen(_ on: Bool) {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    func raise() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Reorders the window without switching the active app.
    func raiseWithoutActivating() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    private func copyAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    // MARK: Finding windows

    static func windows(ofPID pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.compactMap { AXWindow(element: $0, pid: pid) }
    }

    static func focused(ofPID pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return nil }
        return AXWindow(element: value as! AXUIElement, pid: pid)
    }

    private struct ListedWindow {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    /// On-screen windows of other apps, frontmost first.
    private static func listedWindows() -> [ListedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  (entry[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 else { return nil }
            return ListedWindow(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// The normal window under a point, or nil if a menu, the Dock or similar is on top of it.
    static func at(_ point: CGPoint) -> AXWindow? {
        guard let top = listedWindows().first(where: { $0.bounds.contains(point) }), top.layer == 0 else { return nil }
        return windows(ofPID: top.pid).first { $0.id == top.id && $0.isStandard }
    }

    /// All standard windows on screen, frontmost first.
    static func allOnScreen() -> [AXWindow] {
        let listed = listedWindows().filter { $0.layer == 0 }
        var byPID: [pid_t: [AXWindow]] = [:]
        return listed.compactMap { item in
            let windows = byPID[item.pid] ?? AXWindow.windows(ofPID: item.pid)
            byPID[item.pid] = windows
            return windows.first { $0.id == item.id && $0.isStandard }
        }
    }
}
