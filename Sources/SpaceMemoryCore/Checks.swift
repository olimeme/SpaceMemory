import AppKit
import ScreenCaptureKit

/// Automated checks using simulated input. They move real windows, then put them back.
enum Checks {
    private static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SpaceMemory-checks")

    private static func report(_ line: String) {
        Log.write("check: \(line)")
    }

    private static func findWindow(appName: String) -> AXWindow? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
        }
        for app in apps {
            let windows = AXWindow.windows(ofPID: app.processIdentifier).filter { $0.isStandard }
            if let window = windows.first(where: { ($0.size?.width ?? 0) > 200 }) { return window }
        }
        return nil
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func savePNG(_ image: CGImage?, name: String) -> String {
        guard let image else { return "no image" }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(name + ".png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return "encode failed"
        }
        try? data.write(to: url)
        return url.path
    }

    /// By title, for checks that press inside a window and must not touch the user's own.
    private static func titled(_ appName: String, _ title: String) -> AXWindow? {
        NSWorkspace.shared.runningApplications
            .filter { ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName) }
            .flatMap { AXWindow.windows(ofPID: $0.processIdentifier) }
            .first { $0.isStandard && $0.title.localizedCaseInsensitiveContains(title) }
    }

    private static func notRestored(_ before: [(AXWindow, CGRect)]) -> [String] {
        before.filter { window, frame in
            guard let now = window.frame else { return false }
            return abs(now.minX - frame.minX) > 2 || abs(now.minY - frame.minY) > 2
                || abs(now.width - frame.width) > 2 || abs(now.height - frame.height) > 2
        }.map { "\($0.0.appName) \($0.1)" }
    }

    private static func sameImage(_ a: CGImage?, _ b: CGImage?) -> Bool {
        guard let a, let b, let dataA = a.dataProvider?.data, let dataB = b.dataProvider?.data else { return false }
        return CFEqual(dataA, dataB)
    }

    // MARK: Input

    private static func post(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func drag(_ from: CGPoint, to: CGPoint, steps: Int = 50) async {
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            await sleep(0.012)
        }
    }

    /// A title-bar point that's empty in most apps.
    private static func titleBarPoint(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + frame.width * 0.82, y: frame.minY + 8)
    }

    @MainActor
    static func runGestureChecks(manager: WindowManager, appNames: [String]) async {
        report("=== gesture checks ===")
        for name in appNames {
            guard let window = findWindow(appName: name), let frame = window.frame,
                  let screen = Screens.screen(at: CGPoint(x: frame.midX, y: frame.midY)) else {
                report("[\(name)] no usable window found")
                continue
            }
            window.raise()
            await sleep(0.6)
            let zones = Zones(screen: screen)
            let start = titleBarPoint(of: frame)
            let beforeDocked = manager.dockedCount
            guard AXWindow.at(start)?.id == window.id else {
                report("[\(name)] FAILED: window isn't under the press point")
                continue
            }

            post(.mouseMoved, start)
            await sleep(0.1)
            post(.leftMouseDown, start)
            await sleep(0.15)
            await drag(start, to: CGPoint(x: start.x + 60, y: start.y))
            await sleep(0.3) // lets the capture deliver its first frame
            let dockPoint = CGPoint(x: zones.visible.maxX - 40, y: start.y)
            await drag(CGPoint(x: start.x + 60, y: start.y), to: dockPoint, steps: 70)
            await sleep(0.1)
            post(.leftMouseUp, dockPoint)
            // Too soon for an animation to have finished.
            await sleep(0.05)
            if let card = manager.entries.first(where: { $0.window.id == window.id }) {
                let onScreen = card.preview.panel.frame
                let wanted = Screens.toAppKit(card.slotFrame)
                report("[\(name)] 50 ms after release: card already in place \(abs(onScreen.minX - wanted.minX) < 1 && abs(onScreen.minY - wanted.minY) < 1 && abs(onScreen.width - wanted.width) < 1), panel \(onScreen), slot \(wanted)")
            }
            await sleep(0.55)

            let docked = manager.dockedCount == beforeDocked + 1
            let origin = window.origin ?? .zero
            report("[\(name)] edge drag: docked \(docked), real window parked \(Screens.isParked(origin)) at \(origin)")
            guard docked, let entry = manager.entries.first(where: { $0.window.id == window.id }) else {
                report("[\(name)] FAILED, putting the window back")
                window.setOrigin(frame.origin)
                continue
            }
            report("[\(name)] card frame \(entry.preview.frame)")
            report("[\(name)] docked image: \(savePNG(await desktopSnapshot(), name: "\(name)-docked-desktop"))")

            let framesBefore = entry.capture.frameCount
            await sleep(2)
            report("[\(name)] card frames in 2 s: \(entry.capture.frameCount - framesBefore)")

            // A large window in front covers the column, and then the card has to be revealed first.
            if manager.hiddenColumnCount > 0 {
                report("[\(name)] column hidden by the front window, resting at the edge")
                post(.mouseMoved, CGPoint(x: zones.visible.maxX - 1, y: entry.slotFrame.midY))
                await sleep(0.9)
                report("[\(name)] revealed \(manager.isColumnRevealed)")
            }
            let card = CGPoint(x: entry.slotFrame.midX, y: entry.slotFrame.midY)
            post(.mouseMoved, card)
            await sleep(0.1)
            post(.leftMouseDown, card)
            await sleep(0.05)
            post(.leftMouseUp, card)
            await sleep(0.6)
            let after = window.frame ?? .zero
            report("[\(name)] click card: restored to original \(after == frame) (\(after))")
            guard AXWindow.at(start)?.id == window.id else {
                report("[\(name)] FAILED: window isn't under the press point, skipping its remaining gestures")
                window.setOrigin(frame.origin)
                continue
            }

            // Drag back out of the zone during the same gesture: the window should return, not dock.
            post(.mouseMoved, start)
            await sleep(0.1)
            post(.leftMouseDown, start)
            await sleep(0.15)
            await drag(start, to: CGPoint(x: start.x + 60, y: start.y))
            await sleep(0.3)
            let zonePoint = CGPoint(x: zones.visible.maxX - zones.bandWidth * 0.7, y: start.y)
            await drag(CGPoint(x: start.x + 60, y: start.y), to: zonePoint, steps: 40)
            report("[\(name)] mid-shrink image: \(savePNG(await desktopSnapshot(), name: "\(name)-midshrink-desktop"))")
            await drag(zonePoint, to: start, steps: 40)
            post(.leftMouseUp, start)
            await sleep(0.6)
            let returned = window.frame ?? .zero
            let close = abs(returned.minX - frame.minX) < 3 && abs(returned.minY - frame.minY) < 3
            report("[\(name)] drag in and back out: not docked \(manager.dockedCount == beforeDocked), back in place \(close) (\(returned))")
            window.setOrigin(frame.origin)
            await sleep(0.3)

            // Dock once more, then switch to the app as Cmd-Tab would: the window must not stay hidden.
            window.raise()
            await sleep(0.4)
            guard AXWindow.at(start)?.id == window.id else {
                report("[\(name)] FAILED: window isn't under the press point, skipping the app switch")
                continue
            }
            post(.mouseMoved, start)
            await sleep(0.1)
            post(.leftMouseDown, start)
            await sleep(0.15)
            await drag(start, to: CGPoint(x: start.x + 60, y: start.y))
            await sleep(0.3)
            await drag(CGPoint(x: start.x + 60, y: start.y), to: dockPoint, steps: 70)
            await sleep(0.1)
            post(.leftMouseUp, dockPoint)
            await sleep(0.6)
            let dockedAgain = manager.dockedCount == beforeDocked + 1
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            await sleep(0.8)
            let switched = window.frame ?? .zero
            report("[\(name)] app switch while docked: was docked \(dockedAgain), window restored \(switched == frame) (\(switched))")
            window.setOrigin(frame.origin)
            await sleep(0.3)
        }

        await runShakeCheck(manager: manager, appNames: appNames)
        report("=== gesture checks done ===")
    }

    private static func performShake(_ window: AXWindow, fallback: CGRect) async {
        let start = titleBarPoint(of: window.frame ?? fallback)
        post(.mouseMoved, start)
        await sleep(0.1)
        post(.leftMouseDown, start)
        await sleep(0.15)
        await drag(start, to: CGPoint(x: start.x + 5, y: start.y), steps: 3)
        await sleep(0.2)
        var position = CGPoint(x: start.x + 5, y: start.y)
        for i in 0..<7 {
            let target = CGPoint(x: start.x + (i % 2 == 0 ? 70 : -70), y: start.y)
            await drag(position, to: target, steps: 5)
            position = target
        }
        await drag(position, to: start, steps: 5)
        post(.leftMouseUp, start)
        await sleep(1.2)
    }

    private static func pressShortcut() {
        press(3, [.maskControl, .maskAlternate, .maskCommand]) // 3 is the F key
    }

    // MARK: Switching

    /// Only sends app shortcuts to the expected app.
    private static func pressIfFront(_ appName: String, _ key: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.localizedName == appName else {
            report("[switch] skipped a key press: \(appName) wasn't in front")
            return false
        }
        press(key, flags)
        return true
    }

    private static func postModifier(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    @MainActor
    private static func reportFocusArea(_ manager: WindowManager, _ step: String) {
        guard let main = manager.focusedMainWindow, let frame = main.frame else {
            report("[switch] \(step): FAILED, no main window")
            return
        }
        let visible = Screens.screen(at: CGPoint(x: frame.midX, y: frame.midY)).map { Screens.visibleFrame(of: $0) } ?? .zero
        let others = AXWindow.allOnScreen().filter { window in
            guard window.id != main.id, let origin = window.origin else { return false }
            return !Screens.isParked(origin) && visible.contains(origin)
        }
        let managed = Set(manager.entries.map(\.window.id))
        let overlapping = manager.entries.filter { $0.dockEdge != nil && $0.preview.frame.intersects(frame) }.count
        let front = NSWorkspace.shared.frontmostApplication.flatMap { AXWindow.focused(ofPID: $0.processIdentifier) }
        report("[switch] \(step): main \(main.appName) \(main.id) \(frame), has focus \(front?.id == main.id), main is a card \(managed.contains(main.id)), other windows visible \(others.map(\.appName)), cards over it \(overlapping), cards \(manager.dockedCount)")
    }

    /// Switches to the last-used window, then measures how long the previous one takes to become a parked card.
    @MainActor
    private static func reportDockTime(_ manager: WindowManager, step: String) async {
        guard let previous = manager.focusedMainWindow else { return }
        postModifier(58, down: true, flags: .maskAlternate)
        await sleep(0.05)
        press(48, .maskAlternate)
        await sleep(0.1)
        postModifier(58, down: false, flags: [])
        let started = ProcessInfo.processInfo.systemUptime
        var elapsed: Int?
        while ProcessInfo.processInfo.systemUptime - started < 1.5 {
            let isCard = manager.entries.contains { $0.window.id == previous.id && $0.dockEdge != nil }
            if isCard, manager.focusedMainWindow?.id != previous.id {
                elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                break
            }
            await sleep(0.005)
        }
        report("[switch] dock time \(step): \(elapsed.map { "\($0) ms" } ?? "not docked within 1.5 s")")
        await sleep(0.6)
    }

    @MainActor
    static func runSwitchingChecks(manager: WindowManager, appNames: [String]) async {
        report("=== switching checks ===")
        guard appNames.count >= 2, let first = findWindow(appName: appNames[0]) else {
            report("[switch] needs a window in each of two apps")
            return
        }
        let other = appNames[1]
        let before = AXWindow.allOnScreen().map { ($0, $0.frame ?? .zero) }
        first.raise()
        await sleep(0.6)

        manager.toggleFullView()
        await sleep(2.5)
        reportFocusArea(manager, "start")
        report("[switch] start image: \(savePNG(await desktopSnapshot(), name: "switch-start"))")

        let firstID = first.id
        findWindow(appName: other).flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.activate()
        await sleep(1.2)
        reportFocusArea(manager, "app activated")
        report("[switch] previous window parked \(Screens.isParked(first.origin ?? .zero)), is a card \(manager.entries.contains { $0.window.id == firstID })")
        report("[switch] activated image: \(savePNG(await desktopSnapshot(), name: "switch-activated"))")

        // The real ⌘Tab, which returns to the previous app.
        let afterActivate = manager.focusedMainWindow?.id
        postModifier(55, down: true, flags: .maskCommand)
        await sleep(0.05)
        press(48, .maskCommand)
        await sleep(0.05)
        postModifier(55, down: false, flags: [])
        await sleep(1.2)
        report("[switch] ⌘Tab changed the main window: \(manager.focusedMainWindow?.id != afterActivate), now \(manager.focusedMainWindow?.appName ?? "?")")
        reportFocusArea(manager, "⌘Tab")

        // This card's stream has been through two handoffs, so it must still be live.
        if let card = manager.entries.first(where: { $0.window.appName == other }) {
            let a = card.capture.latestFrameImage()
            let framesBefore = card.capture.frameCount
            await sleep(1.5)
            let b = card.capture.latestFrameImage()
            report("[switch] reused stream on \(other) card: frames \(card.capture.frameCount - framesBefore), content changed \(!sameImage(a, b))")
        } else {
            report("[switch] FAILED: no \(other) card to check")
        }
        await reportDockTime(manager, step: "after ⌘Tab")

        // ⌥Tab, held across two presses: selects the second most recent window, then switches on release.
        let beforeSwitcher = manager.focusedMainWindow?.id
        postModifier(58, down: true, flags: .maskAlternate)
        await sleep(0.05)
        press(48, .maskAlternate)
        await sleep(0.35)
        let firstChoice = manager.switcherSelectionID
        report("[switch] ⌥Tab once: selected \(firstChoice.map(String.init) ?? "nothing"), lifted \(manager.hoveredWindowID == firstChoice), main unchanged \(manager.focusedMainWindow?.id == beforeSwitcher)")
        press(48, .maskAlternate)
        await sleep(0.35)
        let secondChoice = manager.switcherSelectionID
        report("[switch] ⌥Tab twice: selected \(secondChoice.map(String.init) ?? "nothing"), moved on \(secondChoice != firstChoice)")
        report("[switch] selection image: \(savePNG(await desktopSnapshot(), name: "switch-selection"))")
        postModifier(58, down: false, flags: [])
        await sleep(1.2)
        report("[switch] ⌥ released: main is the selection \(manager.focusedMainWindow?.id == secondChoice), switcher closed \(manager.switcherSelectionID == nil)")
        reportFocusArea(manager, "⌥Tab")

        // Tapped once, ⌥Tab goes back to the window just left.
        let leftWindow = beforeSwitcher
        postModifier(58, down: true, flags: .maskAlternate)
        await sleep(0.05)
        press(48, .maskAlternate)
        await sleep(0.15)
        postModifier(58, down: false, flags: [])
        await sleep(1.2)
        report("[switch] ⌥Tab tapped: back to the last window \(manager.focusedMainWindow?.id == leftWindow)")
        reportFocusArea(manager, "⌥Tab tapped")

        // Windows of one app: ⌘` switches without activating anything.
        findWindow(appName: appNames[0]).flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.activate()
        await sleep(1.2)
        let beforeBacktick = manager.focusedMainWindow?.id
        if pressIfFront(appNames[0], 50, .maskCommand) {
            await sleep(1.2)
            report("[switch] ⌘` changed the main window: \(manager.focusedMainWindow?.id != beforeBacktick), still \(manager.focusedMainWindow?.appName ?? "?")")
            reportFocusArea(manager, "⌘`")
        }

        // A click on a card.
        if let card = manager.entries.last(where: { $0.dockEdge != nil }) {
            let point = CGPoint(x: card.hitRect.midX, y: card.hitRect.midY)
            let cardID = card.window.id
            post(.mouseMoved, point)
            await sleep(0.3)
            post(.leftMouseDown, point)
            await sleep(0.05)
            post(.leftMouseUp, point)
            await sleep(1.2)
            report("[switch] card clicked: main is that window \(manager.focusedMainWindow?.id == cardID)")
            reportFocusArea(manager, "card click")
            await reportDockTime(manager, step: "after card click")
        }

        // Full view carries across a switch, and each window keeps its own focused size.
        let focusedSize = manager.focusedMainWindow?.size
        let fullFirst = manager.focusedMainWindow
        manager.toggleFullView()
        await sleep(0.8)
        report("[switch] full view on: \(manager.isFullView), hidden columns \(manager.hiddenColumnCount)")
        findWindow(appName: other).flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.activate()
        await sleep(1.2)
        reportFocusArea(manager, "switch in full view")
        report("[switch] still full view \(manager.isFullView), hidden columns \(manager.hiddenColumnCount)")
        report("[switch] full view image: \(savePNG(await desktopSnapshot(), name: "switch-fullview"))")
        manager.toggleFullView()
        await sleep(1)
        reportFocusArea(manager, "back to focused")
        if let fullFirst { NSRunningApplication(processIdentifier: fullFirst.pid)?.activate() }
        await sleep(1.2)
        report("[switch] returning window: same window \(manager.focusedMainWindow?.id == fullFirst?.id), same size \(manager.focusedMainWindow?.size == focusedSize)")

        // A window that's just been opened.
        findWindow(appName: appNames[0]).flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.activate()
        await sleep(1)
        let beforeNew = manager.focusedMainWindow?.id
        if pressIfFront(appNames[0], 45, .maskCommand) {
            await sleep(1.5)
            report("[switch] new window: main changed \(manager.focusedMainWindow?.id != beforeNew)")
            reportFocusArea(manager, "new window")
        }

        // Switching faster than previews can arrive.
        let apps = appNames.prefix(2).compactMap { findWindow(appName: $0) }.compactMap { NSRunningApplication(processIdentifier: $0.pid) }
        for app in apps + apps {
            app.activate()
            await sleep(0.08)
        }
        await sleep(1.5)
        reportFocusArea(manager, "rapid switching")
        let visibleCards = manager.entries.filter { $0.dockEdge != nil }
        let duplicates = visibleCards.count - Set(visibleCards.map(\.window.id)).count
        report("[switch] rapid switching: duplicate cards \(duplicates), main is a card \(visibleCards.contains { $0.window.id == manager.focusedMainWindow?.id })")

        manager.exitFocus()
        await sleep(1.2)
        report("[switch] exit: focus \(manager.isFocusMode), cards \(manager.entries.count), windows checked \(before.count), not back in place \(notRestored(before))")
        report("=== switching checks done ===")
    }

    // MARK: A dropped card and a large window

    @MainActor
    static func runDroppedCardChecks(manager: WindowManager) async {
        report("=== dropped card checks ===")
        guard let large = titled("Chrome", "SpaceMemory drag test"), let window = titled("TextEdit", "snap-test"),
              let screen = NSScreen.main else {
            report("[dropped] FAILED: test windows not found")
            return
        }
        let visible = Screens.visibleFrame(of: screen)
        let zones = Zones(screen: screen)
        large.setFrame(visible)
        large.raise()
        await sleep(0.7)
        window.raise()
        await sleep(0.7)
        guard let frame = window.frame else { return }
        let start = titleBarPoint(of: frame)
        guard AXWindow.at(start)?.id == window.id else {
            report("[dropped] FAILED: window isn't under the press point")
            return
        }

        let parkedCard: () -> ManagedEntry? = { manager.entries.first { $0.window.id == window.id } }
        func cardState() -> String {
            guard let card = parkedCard() else { return "no card" }
            let inPlace = abs(card.preview.frame.minX - card.slotFrame.minX) < 1
            return "panel on screen \(card.preview.panel.isVisible), in its slot \(inPlace), hidden columns \(manager.hiddenColumnCount)"
        }

        post(.mouseMoved, start)
        await sleep(0.1)
        post(.leftMouseDown, start)
        await sleep(0.15)
        let moved = CGPoint(x: start.x + 60, y: start.y)
        await drag(start, to: moved)
        await sleep(0.3)
        let dockPoint = CGPoint(x: zones.visible.maxX - 40, y: start.y)
        await drag(moved, to: dockPoint, steps: 70)
        await sleep(0.1)
        post(.leftMouseUp, dockPoint)

        await sleep(0.8)
        report("[dropped] 0.8 s after drop: large window in front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), \(cardState())")
        report("[dropped] image: \(savePNG(await desktopSnapshot(), name: "dropped-visible"))")
        await sleep(2)
        report("[dropped] 2.8 s after drop, cursor still at the edge: \(cardState())")

        post(.mouseMoved, CGPoint(x: visible.midX, y: visible.midY))
        await sleep(1)
        report("[dropped] cursor left: \(cardState())")
        report("[dropped] hidden image: \(savePNG(await desktopSnapshot(), name: "dropped-hidden"))")

        post(.mouseMoved, CGPoint(x: visible.maxX - 1, y: visible.midY))
        await sleep(0.9)
        report("[dropped] rested at the edge: revealed \(manager.isColumnRevealed), \(cardState())")
        if let card = parkedCard() {
            let point = CGPoint(x: card.hitRect.midX, y: card.hitRect.midY)
            post(.mouseMoved, point)
            await sleep(0.3)
            post(.leftMouseDown, point)
            await sleep(0.05)
            post(.leftMouseUp, point)
            await sleep(0.8)
        }
        report("[dropped] clicked: card gone \(parkedCard() == nil), window back \(window.frame == frame) (\(window.frame ?? .zero))")
        report("=== dropped card checks done ===")
    }

    // MARK: Dragging content between windows

    @MainActor
    static func runContentDragChecks(manager: WindowManager, appNames: [String]) async {
        report("=== content drag checks ===")
        guard appNames.count >= 2, let source = titled(appNames[0], "SpaceMemory drag test"),
              let target = titled(appNames[1], "drag-target"), let sourceFrame = source.frame else {
            report("[drag] FAILED: test windows not found")
            return
        }
        let before = AXWindow.allOnScreen().map { ($0, $0.frame ?? .zero) }
        source.raise()
        await sleep(0.6)
        manager.toggleFullView()
        await sleep(2.5)

        func center(_ window: AXWindow) -> CGPoint {
            let frame = window.frame ?? sourceFrame
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        func cardPoint() -> CGPoint? {
            manager.entries.first { $0.window.id == target.id }.map { CGPoint(x: $0.hitRect.midX, y: $0.hitRect.midY) }
        }
        /// Presses in the middle of the source, and moves far enough for the app to start its drag.
        func beginDrag() async -> CGPoint {
            let start = center(source)
            guard AXWindow.at(start)?.id == source.id else {
                report("[drag] FAILED: test window isn't under the press point, not pressing")
                return start
            }
            post(.mouseMoved, start)
            await sleep(0.2)
            post(.leftMouseDown, start)
            await sleep(0.2)
            await drag(start, to: CGPoint(x: start.x + 30, y: start.y + 10), steps: 8)
            await sleep(0.3)
            return CGPoint(x: start.x + 30, y: start.y + 10)
        }

        report("[drag] main \(manager.focusedMainWindow?.appName ?? "?"), target is a card \(cardPoint() != nil)")

        // Released straight onto a card: it must be refused, without opening anything.
        var position = await beginDrag()
        report("[drag] drag detected: \(manager.isContentDragging)")
        if let card = cardPoint() {
            await drag(position, to: card, steps: 15)
            await sleep(0.1)
            report("[drag] over card, quick release: lifted \(manager.hoveredWindowID == target.id)")
            post(.leftMouseUp, card)
        }
        await sleep(1)
        report("[drag] dropped on card: ended \(!manager.isContentDragging), main still source \(manager.focusedMainWindow?.id == source.id), cards accept clicks through tap \(manager.entries.allSatisfy { $0.preview.panel.ignoresMouseEvents })")

        // Held over a card: the window opens, and the drop lands in it.
        position = await beginDrag()
        if let card = cardPoint() {
            await drag(position, to: card, steps: 15)
            await sleep(0.9)
            report("[drag] held over card: main is target \(manager.focusedMainWindow?.id == target.id), still dragging \(manager.isContentDragging), source parked \(Screens.isParked(source.origin ?? .zero))")
            report("[drag] held image: \(savePNG(await desktopSnapshot(), name: "drag-held"))")
            let drop = center(target)
            await drag(card, to: drop, steps: 15)
            await sleep(0.3)
            post(.leftMouseUp, drop)
        }
        await sleep(1)
        report("[drag] dropped in opened window: ended \(!manager.isContentDragging), main is target \(manager.focusedMainWindow?.id == target.id)")
        report("[drag] dropped image: \(savePNG(await desktopSnapshot(), name: "drag-dropped"))")

        // ⌘Tab in the middle of a drag.
        NSRunningApplication(processIdentifier: source.pid)?.activate()
        await sleep(1.2)
        report("[drag] back to source: \(manager.focusedMainWindow?.id == source.id)")
        position = await beginDrag()
        postModifier(55, down: true, flags: .maskCommand)
        await sleep(0.05)
        press(48, .maskCommand)
        await sleep(0.05)
        postModifier(55, down: false, flags: [])
        await sleep(1.2)
        report("[drag] ⌘Tab mid-drag: main is target \(manager.focusedMainWindow?.id == target.id), still dragging \(manager.isContentDragging)")
        let secondDrop = center(target)
        await drag(position, to: secondDrop, steps: 15)
        await sleep(0.3)
        post(.leftMouseUp, secondDrop)
        await sleep(1)
        report("[drag] ⌘Tab drop image: \(savePNG(await desktopSnapshot(), name: "drag-cmdtab"))")

        // Selecting text is a press and a move too, but mustn't open anything.
        NSRunningApplication(processIdentifier: target.pid)?.activate()
        await sleep(1)
        let selectStart = CGPoint(x: center(target).x, y: center(target).y + 80)
        post(.mouseMoved, selectStart)
        await sleep(0.2)
        if AXWindow.at(selectStart)?.id == target.id, let other = manager.entries.first(where: { $0.dockEdge != nil }) {
            post(.leftMouseDown, selectStart)
            await sleep(0.2)
            let point = CGPoint(x: other.hitRect.midX, y: other.hitRect.midY)
            await drag(selectStart, to: point, steps: 15)
            await sleep(0.9)
            report("[drag] selecting text over a card: treated as a drag \(manager.isContentDragging), main unchanged \(manager.focusedMainWindow?.id == target.id)")
            post(.leftMouseUp, point)
        }
        await sleep(0.5)

        manager.exitFocus()
        await sleep(1.2)
        report("[drag] exit: focus \(manager.isFocusMode), windows checked \(before.count), not back in place \(notRestored(before))")
        report("=== content drag checks done ===")
    }

    // MARK: Changing the shortcut

    private static func press(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// "set" changes the shortcut. "verify", in a new launch, checks that it was saved and resets it.
    @MainActor
    static func runShortcutChecks(controller: ShortcutController, phase: String) async {
        report("=== shortcut checks: \(phase) ===")
        let fKey: CGKeyCode = 3
        let jKey: CGKeyCode = 38
        let kKey: CGKeyCode = 40
        let escape: CGKeyCode = 53
        let allThree: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

        func fires(_ key: CGKeyCode, _ flags: CGEventFlags) async -> Bool {
            let before = controller.pressCount
            press(key, flags)
            await sleep(0.4)
            return controller.pressCount > before
        }

        report("[shortcut] current: \(controller.current.displayName)")
        if phase == "set" {
            report("[shortcut] default fires: \(await fires(fKey, allThree))")

            controller.showRecorder()
            await sleep(0.5)
            report("[shortcut] recorder open: \(controller.isRecording), image: \(savePNG(await desktopSnapshot(), name: "shortcut-recorder"))")
            // Pressing the current shortcut here re-selects it, instead of toggling the view.
            report("[shortcut] current shortcut while recording toggles: \(await fires(fKey, allThree)), current \(controller.current.displayName)")
            controller.cancelRecording()

            controller.showRecorder()
            await sleep(0.5)
            // These keys would reach whichever app is in front if the recorder didn't get focus.
            guard NSApp.isActive else {
                report("[shortcut] FAILED: the recorder window didn't take focus")
                controller.cancelRecording()
                return
            }
            press(kKey, [.maskCommand])
            await sleep(0.4)
            report("[shortcut] after single-modifier key: still recording \(controller.isRecording), current \(controller.current.displayName)")
            report("[shortcut] rejection image: \(savePNG(await desktopSnapshot(), name: "shortcut-rejected"))")
            press(escape, [])
            await sleep(0.4)
            report("[shortcut] after Esc: recording \(controller.isRecording), current \(controller.current.displayName), default fires \(await fires(fKey, allThree))")

            controller.showRecorder()
            await sleep(0.5)
            press(jKey, allThree)
            await sleep(0.5)
            report("[shortcut] pressed a new one: recording \(controller.isRecording), current \(controller.current.displayName)")
            report("[shortcut] new fires: \(await fires(jKey, allThree)), old fires: \(await fires(fKey, allThree))")
        } else {
            report("[shortcut] survived restart: \(controller.current.displayName == "⌃⌥⌘J")")
            report("[shortcut] saved one fires: \(await fires(jKey, allThree)), default fires: \(await fires(fKey, allThree))")
            controller.showRecorder()
            await sleep(0.4)
            controller.useDefault()
            await sleep(0.4)
            report("[shortcut] after Use Default: recording \(controller.isRecording), current \(controller.current.displayName)")
            report("[shortcut] default fires: \(await fires(fKey, allThree)), old custom fires: \(await fires(jKey, allThree))")
        }
        report("=== shortcut checks done: \(phase) ===")
    }

    // MARK: Full view and native full screen

    @MainActor
    static func runFullViewChecks(manager: WindowManager, appNames: [String]) async {
        report("=== full view checks ===")
        guard let first = appNames.first, let window = findWindow(appName: first), let frame = window.frame else {
            report("[view] no usable window")
            return
        }
        window.raise()
        await sleep(0.6)

        // The shortcut from nothing starts focus mode.
        pressShortcut()
        await sleep(4)
        let focusedFrame = window.frame ?? .zero
        report("[view] shortcut from normal: focus \(manager.isFocusMode), full view \(manager.isFullView), cards \(manager.dockedCount)")
        let overlap = manager.entries.filter { $0.dockEdge != nil && $0.preview.frame.intersects(focusedFrame) }.count
        report("[view] focused \(focusedFrame), hidden columns \(manager.hiddenColumnCount), cards overlapping \(overlap)")
        report("[view] focused image: \(savePNG(await desktopSnapshot(), name: "view-focused"))")

        pressShortcut()
        await sleep(1)
        let screen = Screens.screen(at: CGPoint(x: focusedFrame.midX, y: focusedFrame.midY))
        let visible = screen.map { Screens.visibleFrame(of: $0) } ?? .zero
        report("[view] shortcut to full view: full view \(manager.isFullView), fills screen \(window.frame == visible) (\(window.frame ?? .zero)), hidden columns \(manager.hiddenColumnCount)")
        report("[view] full view image: \(savePNG(await desktopSnapshot(), name: "view-full"))")

        let edge = CGPoint(x: visible.maxX - 1, y: visible.midY)
        post(.mouseMoved, edge)
        await sleep(0.1)
        report("[view] brief touch of edge: revealed \(manager.isColumnRevealed)")
        await sleep(0.8)
        report("[view] resting at edge: revealed \(manager.isColumnRevealed), hidden columns \(manager.hiddenColumnCount)")
        report("[view] revealed image: \(savePNG(await desktopSnapshot(), name: "view-revealed"))")

        post(.mouseMoved, CGPoint(x: visible.midX, y: visible.midY))
        await sleep(0.9)
        report("[view] cursor left: revealed \(manager.isColumnRevealed), hidden columns \(manager.hiddenColumnCount)")

        pressShortcut()
        await sleep(1)
        let backFrame = window.frame ?? .zero
        let overlapAfter = manager.entries.filter { $0.dockEdge != nil && $0.preview.frame.intersects(backFrame) }.count
        report("[view] shortcut back: full view \(manager.isFullView), same frame as focused \(backFrame == focusedFrame), hidden columns \(manager.hiddenColumnCount), cards overlapping \(overlapAfter)")

        // Native full screen: the window goes to its own Space, away from the parked windows.
        let live = manager.entries.first { $0.window.appName == "Safari" } ?? manager.entries.first
        window.setFullScreen(true)
        await sleep(3)
        report("[native] entered: frame \(window.frame ?? .zero), hidden columns \(manager.hiddenColumnCount)")
        report("[native] image: \(savePNG(await desktopSnapshot(), name: "native-full"))")
        if let live {
            let a = live.capture.latestFrameImage()
            let framesBefore = live.capture.frameCount
            await sleep(2)
            let b = live.capture.latestFrameImage()
            report("[native] \(live.window.appName) stream across Spaces: frames \(live.capture.frameCount - framesBefore), content changed \(!sameImage(a, b))")
        }
        let nativeFrame = window.frame ?? .zero
        post(.mouseMoved, CGPoint(x: nativeFrame.maxX - 1, y: nativeFrame.midY))
        await sleep(0.9)
        report("[native] resting at edge: revealed \(manager.isColumnRevealed)")
        report("[native] revealed image: \(savePNG(await desktopSnapshot(), name: "native-revealed"))")
        if let card = manager.entries.last(where: { $0.dockEdge == .right }) {
            let point = CGPoint(x: card.hitRect.midX, y: card.hitRect.midY)
            post(.mouseMoved, point)
            await sleep(0.4)
            post(.leftMouseDown, point)
            await sleep(0.05)
            post(.leftMouseUp, point)
            await sleep(2)
            let gone = !manager.entries.contains { $0 === card }
            report("[native] clicked \(card.window.appName): card removed \(gone), window at \(card.window.frame ?? .zero), frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            report("[native] after click image: \(savePNG(await desktopSnapshot(), name: "native-after-click"))")
        }
        window.raise()
        await sleep(2)
        window.setFullScreen(false)
        await sleep(3)
        report("[native] exited: frame \(window.frame ?? .zero), focus \(manager.isFocusMode), hidden columns \(manager.hiddenColumnCount)")
        report("[native] exited image: \(savePNG(await desktopSnapshot(), name: "native-exited"))")

        window.raise()
        await sleep(0.6)
        await performShake(window, fallback: frame)
        await sleep(0.5)
        report("[view] exit shake: focus \(manager.isFocusMode), cards \(manager.entries.count), main back \(window.frame == frame) (\(window.frame ?? .zero))")
        window.setFrame(frame)
        report("=== full view checks done ===")
    }

    @MainActor
    private static func runShakeCheck(manager: WindowManager, appNames: [String]) async {
        guard let first = appNames.first, let window = findWindow(appName: first), let frame = window.frame else {
            return
        }
        let before = AXWindow.allOnScreen().filter { $0.id != window.id }.map { ($0, $0.frame ?? .zero) }
        window.raise()
        await sleep(0.6)

        func shake() async { await performShake(window, fallback: frame) }

        await shake()
        let cards = manager.entries.filter { $0.dockEdge != nil }
        report("[focus] active: \(manager.isFocusMode), other windows: \(before.count), cards: \(cards.count)")
        let misplaced = cards.filter { abs($0.preview.panel.frame.minX - Screens.toAppKit($0.slotFrame).minX) >= 1 }
        report("[focus] cards not at their slot: \(misplaced.count)")
        let mainNow = window.frame ?? .zero
        let overlapping = cards.filter { $0.preview.frame.intersects(mainNow) }.count
        report("[focus] main window \(frame) -> \(mainNow), cards overlapping it: \(overlapping)")
        let visible = Screens.screen(at: CGPoint(x: mainNow.midX, y: mainNow.midY)).map { Screens.visibleFrame(of: $0) } ?? .zero
        report("[focus] cards outside the screen: \(cards.filter { !visible.contains($0.preview.frame) }.count)")
        let parked = cards.filter { Screens.isParked($0.window.origin ?? .zero) }.count
        report("[focus] real windows parked: \(parked) of \(cards.count)")
        for edge in [Edge.left, .right] {
            let column = cards.filter { $0.dockEdge == edge }
            let covered = column.filter { $0.hitRect.height < $0.slotFrame.height }.count
            report("[focus] \(edge.rawValue) column: \(column.count) cards, \(covered) overlapped into a deck")
        }
        report("[focus] image: \(savePNG(await desktopSnapshot(), name: "focus-desktop"))")

        // Hover and click a card buried in the deck: exactly that card's window must come back.
        let leftCount = cards.filter { $0.dockEdge == .left }.count
        let column = cards.filter { $0.dockEdge == (leftCount > cards.count - leftCount ? .left : .right) }
        if column.count >= 2 {
            // Another app's card could become the main window, and pressing its title bar may hit a button.
            let target = column.first { $0.window.pid == window.pid } ?? column[column.count / 2]
            let point = CGPoint(x: target.hitRect.midX, y: target.hitRect.midY)
            post(.mouseMoved, point)
            await sleep(0.4)
            report("[deck] hovered \(target.window.appName): lifted \(manager.hoveredWindowID == target.window.id)")
            report("[deck] hover image: \(savePNG(await desktopSnapshot(), name: "deck-hover-desktop"))")
            post(.leftMouseDown, point)
            await sleep(0.05)
            post(.leftMouseUp, point)
            await sleep(0.7)
            let gone = !manager.entries.contains { $0 === target }
            report("[deck] click card: that window is now the main one \(manager.focusedMainWindow?.id == target.window.id), card removed \(gone), previous main is a card \(manager.entries.contains { $0.window.id == window.id })")
        }

        // Clicking the card changed which window is in the focus area, so that's the one to shake.
        await performShake(manager.focusedMainWindow ?? window, fallback: frame)
        await sleep(0.5)
        let othersBack = before.allSatisfy { other, original in
            guard let now = other.frame else { return true }
            return abs(now.minX - original.minX) < 2 && abs(now.minY - original.minY) < 2
        }
        let shakeEnded = !manager.isFocusMode
        if !shakeEnded {
            report("[focus] FAILED: second shake didn't end focus mode")
            manager.exitFocus()
            await sleep(1.2)
        }
        let mainBack = window.frame == frame
        report("[focus] second shake: active \(manager.isFocusMode), others back \(othersBack), main back \(mainBack) (\(window.frame ?? .zero))")
        report("[focus] cards left: \(manager.entries.count)")
        report("[focus] restored image: \(savePNG(await desktopSnapshot(), name: "focus-restored-desktop"))")
        window.setFrame(frame)
    }

    private static func desktopSnapshot() async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
