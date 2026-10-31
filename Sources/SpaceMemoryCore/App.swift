import AppKit
import ApplicationServices

/// Launch flags: --check-windows App1,App2 and --check-gestures App1,App2 run the automated
/// feasibility checks, --check-fullview App exercises full view and native full screen,
/// --check-dropped-card exercises docking with a large window in front,
/// --check-drag Source,Target exercises dragging content between windows,
/// --check-switching App exercises the one-window focus area,
/// --check-shortcut set|verify exercises changing the shortcut, and --quit-after-checks exits when they finish.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = WindowManager()
    private let shortcut = ShortcutController()
    private var toggleItem: NSMenuItem?
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var managerStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        setUpMenu()
        handleTerminationSignals()

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        waitForPermissions()
    }

    /// Two copies would both act on every mouse event and fight over the same windows.
    private func quitOtherCopies() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func waitForPermissions() {
        let accessibility = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        statusLine?.title = "Accessibility: \(accessibility ? "on" : "NEEDED")  Screen Recording: \(screen ? "on" : "NEEDED")"
        Log.write("permissions: accessibility=\(accessibility) screen=\(screen)")
        guard accessibility, screen else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.waitForPermissions() }
            return
        }
        guard !managerStarted else { return }
        managerStarted = true
        guard manager.start() else {
            Log.write("start: could not create the event tap")
            statusLine?.title = "Could not create the event tap"
            return
        }
        statusLine?.title = "Running. Drag a window to a side, or shake one."
        shortcut.onPressed = { [weak self] in self?.manager.toggleFullView() }
        shortcut.onChanged = { [weak self] in self?.updateToggleItem() }
        shortcut.onSwitcherPressed = { [weak self] in self?.manager.switcherPressed() }
        manager.onFocusModeChanged = { [weak self] active in self?.shortcut.setSwitcherEnabled(active) }
        shortcut.start()
        updateToggleItem()
        Log.write("start: running")
        runRequestedChecks()
    }

    private func runRequestedChecks() {
        let args = CommandLine.arguments
        func names(after flag: String) -> [String]? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1].split(separator: ",").map(String.init)
        }
        let windowApps = names(after: "--check-windows")
        let gestureApps = names(after: "--check-gestures")
        let fullViewApps = names(after: "--check-fullview")
        let shortcutPhase = names(after: "--check-shortcut")?.first
        let switchingApps = names(after: "--check-switching")
        let dragApps = names(after: "--check-drag")
        let checksDroppedCard = args.contains("--check-dropped-card")
        guard windowApps != nil || gestureApps != nil || fullViewApps != nil || shortcutPhase != nil
                || switchingApps != nil || dragApps != nil || checksDroppedCard else { return }
        Task { @MainActor in
            if let windowApps { await Probe.runWindowChecks(appNames: windowApps) }
            if let gestureApps { await Probe.runGestureChecks(manager: manager, appNames: gestureApps) }
            if let fullViewApps { await Probe.runFullViewChecks(manager: manager, appNames: fullViewApps) }
            if let switchingApps { await Probe.runSwitchingChecks(manager: manager, appNames: switchingApps) }
            if checksDroppedCard { await Probe.runDroppedCardChecks(manager: manager) }
            if let dragApps { await Probe.runContentDragChecks(manager: manager, appNames: dragApps) }
            if let shortcutPhase {
                // Key presses only: the toggle would move windows, and this check is about the shortcut.
                shortcut.onPressed = nil
                await Probe.runShortcutChecks(controller: shortcut, phase: shortcutPhase)
            }
            if args.contains("--quit-after-checks") { NSApp.terminate(nil) }
        }
    }

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "SpaceMemory")
        let menu = NSMenu()
        let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "", action: #selector(toggleFullView), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle
        updateToggleItem()
        let change = NSMenuItem(title: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        menu.addItem(change)
        let restore = NSMenuItem(title: "Restore All Windows", action: #selector(restoreAll), keyEquivalent: "r")
        restore.target = self
        menu.addItem(restore)
        menu.addItem(NSMenuItem(title: "Quit SpaceMemory", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        statusLine = status
    }

    @objc private func restoreAll() { manager.restoreEverything() }
    @objc private func toggleFullView() { manager.toggleFullView() }
    @objc private func changeShortcut() { shortcut.showRecorder() }

    private func updateToggleItem() {
        toggleItem?.title = "Focused / Full View (\(shortcut.current.displayName))"
    }

    private func handleTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.restoreEverything()
        Log.write("quit: windows restored")
    }
}

/// Entry point, called by the launcher in the app bundle.
@_cdecl("spacememory_run")
public func spacememoryRun() {
    let app = NSApplication.shared
    // NSApplication only holds its delegate weakly.
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
