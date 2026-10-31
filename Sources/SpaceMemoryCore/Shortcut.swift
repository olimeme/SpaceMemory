import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_F),
                                   carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
                                   keyLabel: "F")

    var displayName: String {
        var name = ""
        if carbonModifiers & UInt32(controlKey) != 0 { name += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { name += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { name += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { name += "⌘" }
        return name + keyLabel
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    /// Shortcuts use the physical key, so labels come from the Latin layout whatever layout is active.
    private static func latinLabel(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count,
                                  &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    enum Validation {
        case valid(Shortcut)
        case invalid(String)
    }

    /// Requires two modifiers or a function key, since combinations like ⌘C belong to apps.
    static func validate(_ event: NSEvent) -> Validation {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        var count = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                               (.shift, shiftKey), (.command, cmdKey)] where flags.contains(flag) {
            modifiers |= UInt32(carbon)
            count += 1
        }
        let code = Int(event.keyCode)
        let functionKey = functionKeys[code]
        guard count >= 2 || functionKey != nil else {
            return .invalid("Use at least two of ⌃ ⌥ ⇧ ⌘, or a function key.")
        }
        let label = functionKey ?? namedKeys[code] ?? latinLabel(forKeyCode: event.keyCode)
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(code)"
        return .valid(Shortcut(keyCode: UInt32(code), carbonModifiers: modifiers, keyLabel: label))
    }
}

/// Saves and registers the global shortcuts, and shows the window for changing them.
final class ShortcutController: NSObject, NSWindowDelegate {
    private static let defaultsKey = "fullViewShortcut"

    private(set) var current: Shortcut
    var onPressed: (() -> Void)?
    var onChanged: (() -> Void)?
    var onSwitcherPressed: (() -> Void)?
    private(set) var pressCount = 0

    private var hotKey: EventHotKeyRef?
    private var switcherHotKey: EventHotKeyRef?
    private var window: NSWindow?
    private var messageLabel: NSTextField?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    var isRecording: Bool { window != nil }

    override init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            current = saved
        } else {
            current = .standard
        }
        super.init()
    }

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            let controller = Unmanaged<ShortcutController>.fromOpaque(userData!).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.id == 2 {
                controller.onSwitcherPressed?()
            } else {
                controller.pressCount += 1
                controller.onPressed?()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
        let status = register(current)
        Log.write("shortcut: \(current.displayName) registered with status \(status)")
    }

    /// Uses a Carbon hot key to avoid monitoring the whole keyboard. macOS doesn't report clashes with
    /// other apps, and both respond. For example, Rectangle's Center Third uses ⌃⌥F.
    private func register(_ shortcut: Shortcut) -> OSStatus {
        unregister()
        return RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                   EventHotKeyID(signature: 0x534D454D, id: 1),
                                   GetApplicationEventTarget(), 0, &hotKey)
    }

    /// ⌥Tab is only registered during focus mode.
    func setSwitcherEnabled(_ enabled: Bool) {
        if let switcherHotKey { UnregisterEventHotKey(switcherHotKey) }
        switcherHotKey = nil
        guard enabled else { return }
        let status = RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), EventHotKeyID(signature: 0x534D454D, id: 2),
                                         GetApplicationEventTarget(), 0, &switcherHotKey)
        Log.write("shortcut: ⌥Tab switcher registered with status \(status)")
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func use(_ shortcut: Shortcut) -> Bool {
        let status = register(shortcut)
        guard status == noErr else {
            Log.write("shortcut: \(shortcut.displayName) refused with status \(status)")
            return false
        }
        current = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        Log.write("shortcut: changed to \(shortcut.displayName)")
        onChanged?()
        return true
    }

    // MARK: Recording window

    func showRecorder() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        // Unregistered so pressing the current shortcut gets recorded.
        unregister()

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 380, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Change Shortcut"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        let content = window.contentView!

        let prompt = NSTextField(labelWithString: "Press the new shortcut")
        prompt.font = .systemFont(ofSize: 17, weight: .semibold)
        prompt.frame = CGRect(x: 20, y: 108, width: 340, height: 24)
        content.addSubview(prompt)

        let detail = NSTextField(labelWithString: "Current: \(current.displayName)")
        detail.textColor = .secondaryLabelColor
        detail.frame = CGRect(x: 20, y: 86, width: 340, height: 18)
        content.addSubview(detail)

        let message = NSTextField(wrappingLabelWithString: "If another app uses the same combination, both will respond.")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.frame = CGRect(x: 20, y: 50, width: 340, height: 32)
        content.addSubview(message)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRecording))
        cancel.frame = CGRect(x: 280, y: 12, width: 84, height: 30)
        content.addSubview(cancel)
        let reset = NSButton(title: "Use Default (\(Shortcut.standard.displayName))", target: self,
                             action: #selector(useDefault))
        reset.frame = CGRect(x: 16, y: 12, width: 170, height: 30)
        content.addSubview(reset)

        self.window = window
        messageLabel = message
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecorded(event)
            return nil
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func handleRecorded(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            cancelRecording()
            return
        }
        switch Shortcut.validate(event) {
        case let .invalid(reason):
            showRecorderError(reason)
        case let .valid(shortcut):
            if use(shortcut) {
                closeRecorder(reregisterCurrent: false)
            } else {
                showRecorderError("\(shortcut.displayName) isn't available. Try another combination.")
            }
        }
    }

    private func showRecorderError(_ text: String) {
        messageLabel?.stringValue = text
        messageLabel?.textColor = .systemRed
    }

    @objc func cancelRecording() {
        closeRecorder(reregisterCurrent: true)
    }

    @objc func useDefault() {
        if use(.standard) {
            closeRecorder(reregisterCurrent: false)
        } else {
            showRecorderError("\(Shortcut.standard.displayName) isn't available right now.")
        }
    }

    private func closeRecorder(reregisterCurrent: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let closing = window
        window = nil
        messageLabel = nil
        closing?.delegate = nil
        closing?.close()
        if reregisterCurrent { _ = register(current) }
        previousApp?.activate()
        previousApp = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        closeRecorder(reregisterCurrent: true)
    }
}
