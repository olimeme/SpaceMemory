import AppKit

/// A window shown as a preview, either mid-drag or docked.
final class ManagedEntry {
    let window: AXWindow
    let size: CGSize
    let originalOrigin: CGPoint
    let capture: WindowCapture
    let preview: PreviewPanel
    var wantsParked = true
    var dockEdge: Edge?
    var dockScreenFrame: CGRect = .zero
    var fromFocusMode = false
    var slotFrame: CGRect = .zero
    /// The clickable part of the card. In a deck, this is its visible strip.
    var hitRect: CGRect = .zero
    var restingQuality = WindowCapture.Quality.card

    init(window: AXWindow, size: CGSize, originalOrigin: CGPoint, capture: WindowCapture) {
        self.window = window
        self.size = size
        self.originalOrigin = originalOrigin
        self.capture = capture
        preview = PreviewPanel(capture: capture)
    }
}

final class WindowManager {
    private enum Phase {
        case idle
        case pressed(window: AXWindow, frame: CGRect, press: CGPoint)
        case nativeDrag(window: AXWindow, frame: CGRect, grab: CGPoint, capture: WindowCapture)
        case proxyDrag(entry: ManagedEntry, grab: CGPoint)
        case cardPress(entry: ManagedEntry, press: CGPoint)
    }

    private struct PendingCard {
        let window: AXWindow
        let frame: CGRect
        let capture: WindowCapture
        var preferredEdge: Edge?
    }

    private struct FocusSession {
        let id = UUID()
        let visible: CGRect
        var main: AXWindow
        var cardsReady = false
        var initialDockingDone = false
        var needsCentering = true
        /// The main window's focused frame, set while in full view.
        var frameBeforeFullView: CGRect?
        /// Where each window returns when the session ends.
        var originals: [(window: AXWindow, frame: CGRect)] = []
        var focusedFrames: [CGWindowID: CGRect] = [:]
        var edges: [CGWindowID: Edge] = [:]
        /// Most recent first.
        var recent: [CGWindowID] = []

        mutating func remember(_ window: AXWindow, frame: CGRect) {
            guard !originals.contains(where: { $0.window.id == window.id }) else { return }
            originals.append((window, frame))
        }

        func originalFrame(of id: CGWindowID) -> CGRect? {
            originals.first { $0.window.id == id }?.frame
        }
    }

    private let cardMargin: CGFloat = 10

    private let tap = EventTap()
    private var phase = Phase.idle
    private var shake = ShakeDetector()
    private(set) var entries: [ManagedEntry] = []
    private var focus: FocusSession? {
        didSet {
            if (oldValue == nil) != (focus == nil) { onFocusModeChanged?(focus != nil) }
        }
    }
    var onFocusModeChanged: ((Bool) -> Void)?
    /// Set while ⌥ is held after ⌥Tab.
    private var switcher: (candidates: [ManagedEntry], index: Int, timer: Timer)?
    /// Clicking the desktop activates Finder, which must not promote a Finder window.
    private var lastDesktopPress: TimeInterval = 0
    private var ignoredFocusID: CGWindowID?
    /// True while dragging a file, text or image, as opposed to a window or card.
    private(set) var isContentDragging = false
    private var dragPasteboardCount = 0
    private var heldCard: ManagedEntry?
    private var heldCardSince: TimeInterval = 0
    /// Off after a held card opens, until the cursor leaves the cards.
    private var holdArmed = true
    /// Applied on mouse release, since a window can't be resized mid-drag.
    private var pendingMainRestore: (window: AXWindow, frame: CGRect)?
    private var hovered: ManagedEntry?
    private var lastShakeTime: TimeInterval = 0
    private var coveredColumns: Set<String> = []
    private var revealedColumn: String?
    /// Keeps a just-dropped card visible until the cursor leaves its column.
    private var isHoldingDroppedColumn = false
    private var cursorAtEdgeSince: (column: String, time: TimeInterval)?
    private var ticksOutsideRevealedColumn = 0
    private var ticks = 0
    private var columnTimer: Timer?

    var dockedCount: Int { entries.filter { $0.dockEdge != nil }.count }
    var isFocusMode: Bool { focus != nil }
    var hoveredWindowID: CGWindowID? { hovered?.window.id }
    var isFullView: Bool { focus?.frameBeforeFullView != nil }
    var hiddenColumnCount: Int { coveredColumns.filter { $0 != revealedColumn }.count }
    var isColumnRevealed: Bool { revealedColumn != nil }
    var focusedMainWindow: AXWindow? { focus?.main }
    var switcherSelectionID: CGWindowID? { switcher.map { $0.candidates[$0.index].window.id } }
    func exitFocus() { endFocus() }

    func start() -> Bool {
        rescueParkedWindows()
        tap.onEvent = { [weak self] kind, point, time in self?.handle(kind, point, time) }
        guard tap.start() else { return false }
        columnTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.columnTick()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = app?.processIdentifier { self?.applicationActivated(pid) }
        }
        return true
    }

    // MARK: Input

    private func handle(_ kind: EventTap.Kind, _ point: CGPoint, _ time: TimeInterval) {
        switch kind {
        case .down: pressed(at: point)
        case .cardDown: cardPressed(at: point)
        case .dragged: dragged(to: point, time: time)
        case .up: released(at: point)
        case .moved: cursorMoved(to: point)
        }
    }

    private func pressed(at point: CGPoint) {
        shake.reset()
        setHovered(nil)
        dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        guard let window = AXWindow.at(point), let frame = window.frame,
              !entries.contains(where: { $0.window.id == window.id }) else {
            lastDesktopPress = ProcessInfo.processInfo.systemUptime
            phase = .idle
            return
        }
        phase = .pressed(window: window, frame: frame, press: point)
    }

    private func dragged(to point: CGPoint, time: TimeInterval) {
        if trackContentDrag(at: point, time: time) { return }
        switch phase {
        case .idle:
            break

        case let .pressed(window, frame, press):
            guard let current = window.frame else { return }
            let moved = abs(current.minX - frame.minX) >= 2 || abs(current.minY - frame.minY) >= 2
            guard moved, current.size == frame.size else { return }
            // Started early so a frame is ready when the window reaches a side zone.
            let capture = WindowCapture(windowID: window.id, size: frame.size)
            capture.start()
            let grab = CGPoint(x: press.x - frame.minX, y: press.y - frame.minY)
            phase = .nativeDrag(window: window, frame: frame, grab: grab, capture: capture)
            Log.write("drag: native drag of \(window.appName) window \(window.id)")

        case let .nativeDrag(window, frame, grab, capture):
            if shake.add(point, time: time) {
                shakeTriggered(on: window, frameBeforeDrag: frame)
                lastShakeTime = time
            }
            guard time - lastShakeTime > 0.4, !shake.mightBeShaking(at: time),
                  let screen = Screens.screen(at: point),
                  Zones(screen: screen).shrinkProgress(atX: point.x) > 0 else { return }
            guard capture.hasFrame else { return }
            takeOver(window: window, frame: frame, grab: grab, capture: capture, at: point)

        case let .proxyDrag(entry, grab):
            place(entry, cursor: point, grab: grab)

        case let .cardPress(entry, press):
            guard hypot(point.x - press.x, point.y - press.y) > 5 else { return }
            startDraggingCard(entry, press: press, cursor: point)
        }
    }

    private func released(at point: CGPoint) {
        endContentDrag()
        var finishedDragOfMain = false
        switch phase {
        case .idle, .pressed:
            break
        case let .nativeDrag(window, _, _, capture):
            capture.stop()
            finishedDragOfMain = window.id == focus?.main.id || window.id == pendingMainRestore?.window.id
            // Dragging a full-view window returns it to focused view.
            if window.id == focus?.main.id { focus?.frameBeforeFullView = nil }
        case let .proxyDrag(entry, grab):
            finishProxyDrag(entry, cursor: point, grab: grab)
        case let .cardPress(entry, _):
            if focus != nil {
                phase = .idle
                promote(entry.window)
            } else {
                undock(entry)
                restore(entry, to: restoredOrigin(for: entry))
            }
        }
        phase = .idle
        if finishedDragOfMain { settleMainWindow() }
    }

    private func cursorMoved(to point: CGPoint) {
        guard case .idle = phase, switcher == nil else { return }
        setHovered(card(at: point))
    }

    // MARK: Dragging content between windows

    /// Returns true during a content drag. A drag writes to the drag pasteboard; selecting text doesn't.
    private func trackContentDrag(at point: CGPoint, time: TimeInterval) -> Bool {
        switch phase {
        case .idle, .pressed: break
        default: return false
        }
        if !isContentDragging {
            guard NSPasteboard(name: .drag).changeCount != dragPasteboardCount else { return false }
            isContentDragging = true
            holdArmed = true
            entries.forEach { $0.preview.setRefusesDrops(true) }
            Log.write("content drag: started")
        }
        guard switcher == nil else { return true }
        let target = card(at: point)
        if target == nil { holdArmed = true }
        if target !== heldCard {
            heldCard = target
            heldCardSince = time
            setHovered(holdArmed ? target : nil)
        }
        return true
    }

    private func openHeldCard() {
        guard let card = heldCard, holdArmed, focus != nil,
              ProcessInfo.processInfo.systemUptime - heldCardSince >= 0.45 else { return }
        heldCard = nil
        holdArmed = false
        setHovered(nil)
        Log.write("content drag: opening \(card.window.appName) window \(card.window.id)")
        promote(card.window)
    }

    private func endContentDrag() {
        guard isContentDragging else { return }
        isContentDragging = false
        heldCard = nil
        setHovered(nil)
        entries.forEach { $0.preview.setRefusesDrops(false) }
        Log.write("content drag: ended")
    }

    // MARK: Native drag to preview

    private func takeOver(window: AXWindow, frame: CGRect, grab: CGPoint, capture: WindowCapture, at point: CGPoint) {
        // The release may still be queued behind this event.
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }

        let entry = makeEntry(window: window, frame: frame, capture: capture)
        entry.fromFocusMode = focus != nil
        entries.append(entry)
        place(entry, cursor: point, grab: grab)
        entry.preview.show()

        let started = ProcessInfo.processInfo.systemUptime
        tap.takeOverDrag(at: point)
        phase = .proxyDrag(entry: entry, grab: grab)
        Log.write("swap: took over \(window.appName) window \(window.id)")

        // Gives the app time to process the mouse-up before the window moves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak entry] in
            guard let entry else { return }
            self?.park(entry, attempt: 1, started: started)
        }
    }

    private func makeEntry(window: AXWindow, frame: CGRect, capture: WindowCapture) -> ManagedEntry {
        let entry = ManagedEntry(window: window, size: frame.size, originalOrigin: frame.origin, capture: capture)
        capture.onStopped = { [weak self, weak entry] in
            if let self, let entry { self.windowDisappeared(entry) }
        }
        return entry
    }

    private func park(_ entry: ManagedEntry, attempt: Int, started: TimeInterval) {
        guard entry.wantsParked else { return }
        entry.window.setOrigin(Screens.parkingOrigin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak entry] in
            guard let self, let entry, entry.wantsParked else { return }
            let origin = entry.window.origin ?? .zero
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            if Screens.isParked(origin) {
                Log.write("swap: parked \(entry.window.appName) after \(attempt) attempt(s), \(elapsed) ms")
            } else if attempt < 4 {
                Log.write("swap: \(entry.window.appName) not parked (at \(origin)), retrying")
                self.park(entry, attempt: attempt + 1, started: started)
            } else {
                Log.write("swap: FAILED to park \(entry.window.appName), window at \(origin)")
                if entry.fromFocusMode {
                    entry.capture.onStopped = nil
                    entry.capture.stop()
                    self.windowDisappeared(entry)
                }
            }
        }
    }

    private func place(_ entry: ManagedEntry, cursor: CGPoint, grab: CGPoint) {
        guard let screen = Screens.screen(at: cursor) else { return }
        let progress = Zones(screen: screen).shrinkProgress(atX: cursor.x)
        let eased = 1 - (1 - progress) * (1 - progress)
        let scale = 1 + (cardScale(for: entry.size) - 1) * eased
        let frame = CGRect(x: cursor.x - grab.x * scale, y: cursor.y - grab.y * scale,
                           width: entry.size.width * scale, height: entry.size.height * scale)
        entry.preview.setFrame(frame)
    }

    private func finishProxyDrag(_ entry: ManagedEntry, cursor: CGPoint, grab: CGPoint) {
        guard let screen = Screens.screen(at: cursor) else { return }
        let zones = Zones(screen: screen)
        if zones.progress(atX: cursor.x) > 0.5 {
            dock(entry, edge: zones.nearestEdge(to: cursor.x), screenFrame: zones.visible)
            revealedColumn = columnKey(of: entry)
            isHoldingDroppedColumn = true
            ticksOutsideRevealedColumn = 0
            layOutCards()
            if focus == nil {
                focusFrontmostWindow()
            } else if entry.window.id == focus?.main.id, let next = switcherCandidates().first(where: { $0 !== entry }) {
                promote(next.window)
            }
        } else if focus != nil, entry.window.id != focus?.main.id {
            promote(entry.window)
        } else {
            let y = max(zones.visible.minY, cursor.y - grab.y)
            restore(entry, to: CGPoint(x: cursor.x - grab.x, y: y))
        }
    }

    // MARK: Cards and decks

    private func dock(_ entry: ManagedEntry, edge: Edge, screenFrame: CGRect) {
        entry.dockEdge = edge
        entry.dockScreenFrame = screenFrame
        entry.capture.setQuality(.card)
        let title = entry.window.title
        entry.preview.setHeader(title: title.isEmpty ? entry.window.appName : title,
                                icon: NSRunningApplication(processIdentifier: entry.window.pid)?.icon)
        entry.preview.showHeader(true)
        entry.preview.setRefusesDrops(isContentDragging)
        Log.write("dock: \(entry.window.appName) on \(edge.rawValue) edge")
    }

    private func undock(_ entry: ManagedEntry) {
        entry.dockEdge = nil
        entry.preview.showHeader(false)
        layOutCards()
    }

    private func layOutCards() {
        hovered = nil
        var columns: [String: [ManagedEntry]] = [:]
        var columnOrder: [String] = []
        for entry in entries {
            guard let key = columnKey(of: entry) else { continue }
            if columns[key] == nil { columnOrder.append(key) }
            columns[key, default: []].append(entry)
        }
        for key in columnOrder { layOutColumn(columns[key] ?? [], isHidden: isColumnHidden(key)) }
        updateCardHitAreas()
    }

    private func columnKey(of entry: ManagedEntry) -> String? {
        guard let edge = entry.dockEdge else { return nil }
        let screen = entry.dockScreenFrame
        return "\(edge.rawValue)-\(screen.minX)-\(screen.minY)"
    }

    private func isColumnHidden(_ key: String) -> Bool {
        coveredColumns.contains(key) && key != revealedColumn
    }

    private func updateCardHitAreas() {
        tap.setCardFrames(entries.filter { entry in
            columnKey(of: entry).map { !isColumnHidden($0) } ?? false
        }.map(\.hitRect))
    }

    /// Stacks cards in a column, overlapping them into a deck if they don't fit.
    private func layOutColumn(_ column: [ManagedEntry], isHidden: Bool) {
        guard let first = column.first, let edge = first.dockEdge, let last = column.last else { return }
        let screen = first.dockScreenFrame
        let available = screen.height - 2 * cardMargin
        let sizes = column.map { cardSize(for: $0) }
        let naturalHeight = sizes.map(\.height).reduce(0, +) + CGFloat(column.count - 1) * cardMargin
        let isDeck = naturalHeight > available
        let lastHeight = sizes[sizes.count - 1].height
        let deckStep = column.count > 1 ? (available - lastHeight) / CGFloat(column.count - 1) : 0

        var y = screen.minY + cardMargin
        for (index, entry) in column.enumerated() {
            let size = sizes[index]
            let x = edge == .left ? screen.minX + cardMargin : screen.maxX - size.width - cardMargin
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            let step = isDeck ? deckStep : size.height + cardMargin
            let isCovered = isDeck && entry !== last && step < size.height
            entry.slotFrame = frame
            entry.hitRect = isCovered ? CGRect(x: x, y: y, width: size.width, height: step) : frame
            entry.restingQuality = isCovered ? .deckCard : .card
            y += step
        }
        setColumn(column, hidden: isHidden, animated: false)
    }

    private func setColumn(_ column: [ManagedEntry], hidden: Bool, animated: Bool) {
        guard let edge = column.first?.dockEdge, let screen = column.first?.dockScreenFrame else { return }
        for entry in column {
            if hidden {
                var away = entry.slotFrame
                away.origin.x = edge == .left ? screen.minX - away.width - 20 : screen.maxX + 20
                entry.capture.setQuality(.deckCard)
                placeCard(entry, at: away, animated: animated)
            } else {
                entry.capture.setQuality(entry.restingQuality)
                placeCard(entry, at: entry.slotFrame, animated: animated)
            }
        }
        if hidden {
            // Ordered out so an off-screen card can't appear on another display.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self else { return }
                for entry in column {
                    if let key = self.columnKey(of: entry), self.isColumnHidden(key) { entry.preview.close() }
                }
            }
        } else {
            column.forEach { $0.preview.show() }
        }
    }

    private func placeCard(_ entry: ManagedEntry, at frame: CGRect, animated: Bool) {
        if animated {
            entry.preview.setFrame(frame, animated: true)
        } else {
            entry.preview.jump(to: frame)
        }
    }

    // MARK: Hiding columns

    private func columnTick() {
        if isContentDragging {
            // In case the tap missed the button release.
            guard CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                endContentDrag()
                return
            }
            if switcher == nil {
                openHeldCard()
                followFocus()
                updateEdgeReveal()
            }
            return
        }
        guard case .idle = phase, switcher == nil else { return }
        ticks += 1
        // ⌘` changes focus without activating an app, so there's no notification for it.
        if focus != nil, ticks % 2 == 0 { followFocus() }
        guard dockedCount > 0 else {
            coveredColumns = []
            revealedColumn = nil
            isHoldingDroppedColumn = false
            cursorAtEdgeSince = nil
            return
        }
        if ticks % 3 == 0 { updateCoveredColumns() }
        updateEdgeReveal()
    }

    private func columnRect(of entry: ManagedEntry) -> CGRect {
        let screen = entry.dockScreenFrame
        let width = cardWidth + 2 * cardMargin
        let x = entry.dockEdge == .left ? screen.minX : screen.maxX - width
        return CGRect(x: x, y: screen.minY, width: width, height: screen.height)
    }

    private func updateCoveredColumns() {
        var covered: Set<String> = []
        if let app = NSWorkspace.shared.frontmostApplication,
           let front = AXWindow.focused(ofPID: app.processIdentifier), front.isStandard,
           !entries.contains(where: { $0.window.id == front.id }),
           let frame = front.frame {
            for entry in entries {
                guard let key = columnKey(of: entry) else { continue }
                let rect = columnRect(of: entry)
                if rect.intersection(frame).width > rect.width / 2 { covered.insert(key) }
            }
        }
        guard covered != coveredColumns else { return }
        let changed = covered.symmetricDifference(coveredColumns)
        coveredColumns = covered
        if let revealed = revealedColumn, !covered.contains(revealed), !isHoldingDroppedColumn { revealedColumn = nil }
        Log.write("columns: covered \(covered.sorted())")
        applyVisibility(of: changed)
    }

    private func applyVisibility(of keys: Set<String>) {
        setHovered(nil)
        for key in keys {
            let column = entries.filter { columnKey(of: $0) == key }
            setColumn(column, hidden: isColumnHidden(key), animated: true)
        }
        updateCardHitAreas()
    }

    private func updateEdgeReveal() {
        guard let cursor = CGEvent(source: nil)?.location else { return }
        if let revealed = revealedColumn {
            let inside = entries.contains { columnKey(of: $0) == revealed && columnRect(of: $0).contains(cursor) }
            ticksOutsideRevealedColumn = inside ? 0 : ticksOutsideRevealedColumn + 1
            if ticksOutsideRevealedColumn >= 3 {
                revealedColumn = nil
                isHoldingDroppedColumn = false
                ticksOutsideRevealedColumn = 0
                applyVisibility(of: [revealed])
            }
            return
        }
        let atEdge = entries.first { entry in
            guard let key = columnKey(of: entry), coveredColumns.contains(key) else { return false }
            let screen = entry.dockScreenFrame
            let edgeDistance = entry.dockEdge == .left ? cursor.x - screen.minX : screen.maxX - cursor.x
            return edgeDistance < 3 && cursor.y >= screen.minY && cursor.y <= screen.maxY
        }.flatMap { columnKey(of: $0) }
        guard let atEdge else {
            cursorAtEdgeSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let since = cursorAtEdgeSince, since.column == atEdge else {
            cursorAtEdgeSince = (atEdge, now)
            return
        }
        // The delay avoids revealing when the cursor passes a scrollbar.
        if now - since.time >= 0.3 {
            cursorAtEdgeSince = nil
            revealedColumn = atEdge
            ticksOutsideRevealedColumn = 0
            applyVisibility(of: [atEdge])
        }
    }

    private func cardSize(for entry: ManagedEntry) -> CGSize {
        let scale = cardScale(for: entry.size)
        return CGSize(width: entry.size.width * scale, height: entry.size.height * scale)
    }

    private func card(at point: CGPoint) -> ManagedEntry? {
        entries.first { $0.dockEdge != nil && $0.hitRect.contains(point) }
    }

    /// Lifts a card out of its column. Selection uses hit rects, so the lifted card doesn't block its neighbors.
    private func setHovered(_ entry: ManagedEntry?) {
        guard entry !== hovered else { return }
        if let old = hovered, old.dockEdge != nil {
            old.preview.setFrame(old.slotFrame, animated: true)
            old.capture.setQuality(old.restingQuality)
            entries.filter { $0.dockEdge == old.dockEdge && $0.dockScreenFrame == old.dockScreenFrame }
                .forEach { $0.preview.show() }
        }
        hovered = entry
        guard let entry, let edge = entry.dockEdge else { return }
        var lifted = entry.slotFrame
        lifted.origin.x += edge == .left ? 14 : -14
        lifted.origin.y = min(lifted.minY, entry.dockScreenFrame.maxY - cardMargin - lifted.height)
        entry.preview.setFrame(lifted, animated: true)
        entry.preview.show()
        entry.capture.setQuality(.card)
    }

    private func cardPressed(at point: CGPoint) {
        setHovered(nil)
        guard let entry = card(at: point) else {
            phase = .idle
            return
        }
        phase = .cardPress(entry: entry, press: point)
    }

    private func startDraggingCard(_ entry: ManagedEntry, press: CGPoint, cursor: CGPoint) {
        let scale = cardScale(for: entry.size)
        let frame = entry.slotFrame
        let grab = CGPoint(x: (press.x - frame.minX) / scale, y: (press.y - frame.minY) / scale)
        undock(entry)
        entry.capture.setQuality(.full)
        entry.preview.show()
        place(entry, cursor: cursor, grab: grab)
        phase = .proxyDrag(entry: entry, grab: grab)
    }

    /// The window's old position, or centered if that was in a side zone.
    private func restoredOrigin(for entry: ManagedEntry) -> CGPoint {
        let center = CGPoint(x: entry.originalOrigin.x + entry.size.width / 2,
                             y: entry.originalOrigin.y + entry.size.height / 2)
        if let screen = Screens.screen(at: center) {
            let zones = Zones(screen: screen)
            if zones.progress(atX: center.x) == 0 { return entry.originalOrigin }
            return CGPoint(x: zones.visible.midX - entry.size.width / 2,
                           y: max(zones.visible.minY, entry.originalOrigin.y))
        }
        return entry.originalOrigin
    }

    private func restore(_ entry: ManagedEntry, to origin: CGPoint) {
        entry.wantsParked = false
        entry.capture.onStopped = nil
        entry.window.setOrigin(origin)
        entry.window.raise()
        entries.removeAll { $0 === entry }
        layOutCards()
        closeAfterRedraw(entry)
        Log.write("restore: \(entry.window.appName) to \(origin)")
    }

    /// Keeps the preview up until the real window has redrawn underneath it.
    private func closeAfterRedraw(_ entry: ManagedEntry) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            entry.preview.close()
            entry.capture.stop()
        }
    }

    private func windowDisappeared(_ entry: ManagedEntry) {
        entry.preview.close()
        entries.removeAll { $0 === entry }
        layOutCards()
        Log.write("card: removed \(entry.window.appName), its window closed")
    }

    private func focusFrontmostWindow() {
        let managed = Set(entries.map(\.window.id))
        AXWindow.allOnScreen().first { !managed.contains($0.id) }?.raise()
    }

    /// Restores a parked window that gains focus, since typing would otherwise go to a hidden window.
    private func applicationActivated(_ pid: pid_t) {
        guard focus == nil else {
            followFocus()
            return
        }
        guard case .idle = phase,
              entries.contains(where: { $0.window.pid == pid && $0.dockEdge != nil }),
              let focused = AXWindow.focused(ofPID: pid),
              let entry = entries.first(where: { $0.window.id == focused.id && $0.dockEdge != nil }) else { return }
        undock(entry)
        restore(entry, to: restoredOrigin(for: entry))
    }

    // MARK: Switching windows

    private var canSwitchNow: Bool {
        if isContentDragging { return true }
        if case .idle = phase { return true }
        return false
    }

    private func followFocus() {
        guard let session = focus, session.cardsReady, switcher == nil, canSwitchNow else { return }
        if session.main.frame == nil, let next = switcherCandidates().first {
            Log.write("switch: main window closed")
            promote(next.window)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let front = AXWindow.focused(ofPID: app.processIdentifier),
              front.id != session.main.id, front.isStandard, !front.isFullScreen else {
            return
        }
        if front.id == ignoredFocusID { return }
        ignoredFocusID = nil
        if app.bundleIdentifier == "com.apple.finder",
           ProcessInfo.processInfo.systemUptime - lastDesktopPress < 0.6 {
            ignoredFocusID = front.id
            return
        }
        promote(front)
    }

    /// Makes a window the main window and docks the previous one.
    private func promote(_ window: AXWindow) {
        guard var session = focus, session.cardsReady, window.id != session.main.id else { return }
        let entry = entries.first { $0.window.id == window.id }
        guard let size = entry?.size ?? window.size else { return }
        if let entry {
            session.remember(window, frame: session.originalFrame(of: window.id)
                             ?? CGRect(origin: entry.originalOrigin, size: entry.size))
        } else if let frame = window.frame {
            session.remember(window, frame: frame)
        }

        let old = session.main
        let oldFrame = old.frame
        let wasFullView = session.frameBeforeFullView != nil
        if let focused = session.frameBeforeFullView ?? oldFrame { session.focusedFrames[old.id] = focused }
        session.recent.removeAll { $0 == old.id || $0 == window.id }
        session.recent.insert(old.id, at: 0)

        let preferredEdge = entry?.dockEdge
        let target = focusedTarget(size: session.focusedFrames[window.id]?.size ?? size,
                                   visible: session.visible, alsoReserving: preferredEdge)
        session.main = window
        session.needsCentering = false
        session.frameBeforeFullView = wasFullView ? target : nil
        focus = session
        Log.write("switch: \(window.appName) window \(window.id) in, \(old.appName) window \(old.id) out")

        if let entry {
            entry.wantsParked = false
            entry.capture.onStopped = nil
            entries.removeAll { $0 === entry }
            layOutCards()
            closeAfterRedraw(entry)
        }
        window.setFrame(wasFullView ? session.visible : target)
        window.raise()

        // A native full-screen window can't be parked.
        if let oldFrame, !old.isFullScreen, !entries.contains(where: { $0.window.id == old.id }) {
            let capture = WindowCapture(windowID: old.id, size: oldFrame.size)
            capture.setQuality(.card)
            capture.start()
            dockWhenReady([PendingCard(window: old, frame: oldFrame, capture: capture, preferredEdge: preferredEdge)],
                          sessionID: session.id, started: ProcessInfo.processInfo.systemUptime,
                          deadline: Date().addingTimeInterval(3))
        }
        updateCoveredColumns()
    }

    /// The horizontal space left between the edge columns.
    private func focusAreaBounds(in visible: CGRect, alsoReserving edge: Edge? = nil) -> (minX: CGFloat, maxX: CGFloat) {
        let docked = entries.filter { $0.dockEdge != nil && $0.dockScreenFrame == visible }
        let reserved = cardWidth + 2 * cardMargin
        let reservesLeft = edge == .left || docked.contains { $0.dockEdge == .left }
        let reservesRight = edge == .right || docked.contains { $0.dockEdge == .right }
        return (visible.minX + (reservesLeft ? reserved : 0), visible.maxX - (reservesRight ? reserved : 0))
    }

    private func focusedTarget(size: CGSize, visible: CGRect, alsoReserving edge: Edge?) -> CGRect {
        let (minX, maxX) = focusAreaBounds(in: visible, alsoReserving: edge)
        let width = min(size.width, maxX - minX)
        let height = min(size.height, visible.height)
        return CGRect(x: minX + (maxX - minX - width) / 2, y: visible.minY + (visible.height - height) / 2,
                      width: width, height: height)
    }

    /// Docked windows, most recently used first.
    private func switcherCandidates() -> [ManagedEntry] {
        let docked = entries.filter { $0.dockEdge != nil }
        let recent = focus?.recent ?? []
        let known = recent.compactMap { id in docked.first { $0.window.id == id } }
        return known + docked.reversed().filter { entry in !recent.contains(entry.window.id) }
    }

    /// Selects the last window used, or steps further back if ⌥ is still held.
    func switcherPressed() {
        guard focus?.cardsReady == true, canSwitchNow else { return }
        if var active = switcher {
            active.index = (active.index + 1) % active.candidates.count
            switcher = active
            highlight(active.candidates[active.index])
            return
        }
        let candidates = switcherCandidates()
        guard let first = candidates.first else { return }
        // Hot keys have no release event, so ⌥ is polled.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { self?.finishSwitcher() }
        }
        switcher = (candidates, 0, timer)
        highlight(first)
    }

    private func highlight(_ entry: ManagedEntry) {
        if let key = columnKey(of: entry), key != revealedColumn {
            let previous = revealedColumn
            revealedColumn = coveredColumns.contains(key) ? key : nil
            applyVisibility(of: Set([previous, key].compactMap { $0 }))
        }
        setHovered(entry)
    }

    private func finishSwitcher() {
        guard let active = switcher else { return }
        active.timer.invalidate()
        switcher = nil
        let chosen = active.candidates[active.index]
        setHovered(nil)
        if let revealed = revealedColumn {
            revealedColumn = nil
            applyVisibility(of: [revealed])
        }
        if entries.contains(where: { $0 === chosen }) { promote(chosen.window) }
    }

    // MARK: Focus mode

    /// Starts focus mode if needed, otherwise switches between focused and full view.
    func toggleFullView() {
        guard var session = focus else {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let front = AXWindow.focused(ofPID: app.processIdentifier), front.isStandard,
                  !entries.contains(where: { $0.window.id == front.id }),
                  let frame = front.frame else { return }
            startFocus(main: front, originalFrame: frame)
            return
        }
        guard let frame = session.main.frame,
              let screen = Screens.screen(at: CGPoint(x: frame.midX, y: frame.midY)) else { return }
        if let focusedFrame = session.frameBeforeFullView {
            session.frameBeforeFullView = nil
            focus = session
            session.main.setFrame(focusedFrame)
            session.main.raise()
            settleMainWindow()
            Log.write("view: \(session.main.appName) focused")
        } else {
            session.frameBeforeFullView = frame
            focus = session
            session.main.setFrame(Screens.visibleFrame(of: screen))
            session.main.raise()
            Log.write("view: \(session.main.appName) full view")
        }
        updateCoveredColumns()
    }

    private func shakeTriggered(on window: AXWindow, frameBeforeDrag: CGRect) {
        if focus != nil {
            endFocus()
        } else {
            startFocus(main: window, originalFrame: frameBeforeDrag)
        }
    }

    private func startFocus(main: AXWindow, originalFrame: CGRect) {
        guard let screen = Screens.screen(at: CGPoint(x: originalFrame.midX, y: originalFrame.midY)) else { return }
        let visible = Screens.visibleFrame(of: screen)
        var session = FocusSession(visible: visible, main: main)
        session.focusedFrames[main.id] = originalFrame
        focus = session

        let managed = Set(entries.map(\.window.id))
        let others = AXWindow.allOnScreen().compactMap { window -> (window: AXWindow, frame: CGRect)? in
            guard window.id != main.id, !managed.contains(window.id),
                  let frame = window.frame, visible.intersects(frame) else { return nil }
            return (window, frame)
        }
        Log.write("focus: starting with \(main.appName), \(others.count) other window(s)")

        let listing = WindowCapture.listWindows()
        // Reversed so the frontmost window ends up as the top card.
        let pending = others.reversed().map { other -> PendingCard in
            let capture = WindowCapture(windowID: other.window.id, size: other.frame.size)
            capture.setQuality(.card)
            capture.start(listing: listing)
            focus?.remember(other.window, frame: other.frame)
            return PendingCard(window: other.window, frame: other.frame, capture: capture)
        }
        // Remembered last so it's raised last on restore.
        focus?.remember(main, frame: originalFrame)
        Log.write("focus: waiting for \(pending.count) preview(s)")
        dockWhenReady(pending, sessionID: session.id,
                      started: ProcessInfo.processInfo.systemUptime, deadline: Date().addingTimeInterval(3))
    }

    /// Docks each window once its preview has a first frame.
    private func dockWhenReady(_ pending: [PendingCard], sessionID: UUID, started: TimeInterval, deadline: Date) {
        guard let session = focus, session.id == sessionID else {
            pending.forEach { $0.capture.stop() }
            return
        }
        let visible = session.visible
        let ready = pending.filter { $0.capture.hasFrame }
        let waiting = pending.filter { !$0.capture.hasFrame }
        for item in ready {
            // Quick switching may have promoted it again already.
            if item.window.id == focus?.main.id {
                item.capture.stop()
                continue
            }
            let entry = makeEntry(window: item.window, frame: item.frame, capture: item.capture)
            entry.fromFocusMode = true
            entries.append(entry)
            entry.preview.setFrame(item.frame)
            entry.preview.show()
            let edge = session.edges[item.window.id] ?? item.preferredEdge
                ?? (item.frame.midX < visible.midX ? .left : .right)
            focus?.edges[item.window.id] = edge
            dock(entry, edge: edge, screenFrame: visible)
            park(entry, attempt: 1, started: started)
        }
        if !ready.isEmpty {
            layOutCards()
            focus?.cardsReady = true
            settleMainWindow()
        }
        if waiting.isEmpty || Date() >= deadline {
            for item in waiting {
                item.capture.stop()
                Log.write("focus: no preview for \(item.window.appName), leaving its window alone")
            }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            Log.write("focus: cards done in \(elapsed) ms, \(waiting.count) window(s) left out")
            focus?.cardsReady = true
            focus?.initialDockingDone = true
            settleMainWindow()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.dockWhenReady(waiting, sessionID: sessionID, started: started, deadline: deadline)
        }
    }

    private func endFocus() {
        guard let session = focus else { return }
        if let active = switcher {
            active.timer.invalidate()
            switcher = nil
        }
        focus = nil
        ignoredFocusID = nil
        let returning = entries.filter { $0.fromFocusMode && $0.dockEdge != nil }
        Log.write("focus: ending, \(returning.count) window(s) coming back")
        for entry in returning {
            entry.dockEdge = nil
            entry.wantsParked = false
            entry.capture.onStopped = nil
            entry.preview.showHeader(false)
            entry.preview.show()
            let home = session.originalFrame(of: entry.window.id) ?? CGRect(origin: entry.originalOrigin, size: entry.size)
            entry.preview.setFrame(home, animated: true)
        }
        entries.removeAll { entry in returning.contains { $0 === entry } }
        layOutCards()
        if let frame = session.originalFrame(of: session.main.id) {
            pendingMainRestore = (session.main, frame)
        }
        let others = session.originals.filter { $0.window.id != session.main.id }

        // Previews animate home first, then the real windows replace them in their original order.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for other in others {
                other.window.setFrame(other.frame)
                other.window.raiseWithoutActivating()
            }
            session.main.raise()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                for entry in returning {
                    entry.preview.close()
                    entry.capture.stop()
                }
            }
        }
        settleMainWindow()
    }

    /// Moves or resizes the main window, unless it's being dragged.
    private func settleMainWindow() {
        if case .nativeDrag = phase { return }
        if let restore = pendingMainRestore {
            pendingMainRestore = nil
            restore.window.setFrame(restore.frame)
            Log.write("focus: main window back at \(restore.frame)")
        }
        guard let session = focus, session.cardsReady, session.frameBeforeFullView == nil,
              let frame = session.main.frame,
              let screen = Screens.screen(at: CGPoint(x: frame.midX, y: frame.midY)) else { return }

        let visible = Screens.visibleFrame(of: screen)
        if session.needsCentering, session.initialDockingDone {
            focus?.needsCentering = false
            session.main.setFrame(focusedTarget(size: frame.size, visible: visible, alsoReserving: nil))
            Log.write("focus: centered \(session.main.appName) at \(session.main.frame ?? .zero)")
            return
        }
        let (minX, maxX) = focusAreaBounds(in: visible)

        var fitted = frame
        fitted.size.width = min(frame.width, maxX - minX)
        fitted.size.height = min(frame.height, visible.height)
        fitted.origin.x = min(max(frame.minX, minX), maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
        guard fitted != frame else { return }

        session.main.setFrame(fitted)
        Log.write("focus: fitted \(session.main.appName) from \(frame) to \(session.main.frame ?? .zero)")
    }

    // MARK: Recovery

    func restoreEverything() {
        let session = focus
        focus = nil
        for entry in entries {
            entry.dockEdge = nil
            restore(entry, to: restoredOrigin(for: entry))
        }
        session?.originals.forEach { $0.window.setFrame($0.frame) }
        if let pending = pendingMainRestore {
            pendingMainRestore = nil
            pending.window.setFrame(pending.frame)
        }
    }

    /// Recovers windows left parked by a crash.
    private func rescueParkedWindows() {
        for window in AXWindow.allOnScreen() {
            guard let frame = window.frame, Screens.isParked(frame.origin),
                  let screen = NSScreen.main else { continue }
            let visible = Screens.visibleFrame(of: screen)
            window.setOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.minY + 40))
            Log.write("rescue: brought back \(window.appName) window \(window.id)")
        }
    }
}
