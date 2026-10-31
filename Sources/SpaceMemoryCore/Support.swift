import AppKit

/// Appends to ~/Library/Logs/SpaceMemory.log so runs can be inspected after the fact.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SpaceMemory.log")
    private static let queue = DispatchQueue(label: "log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

enum Edge: String { case left, right }

/// All geometry uses global top-left coordinates, the system CGEvent and the Accessibility API share.
enum Screens {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func topLeftFrame(of screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    static func visibleFrame(of screen: NSScreen) -> CGRect {
        let f = screen.visibleFrame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { topLeftFrame(of: $0).contains(point) } ?? NSScreen.main
    }

    /// The bottom-right corner of the whole desktop. macOS keeps a window's title bar on screen, so
    /// what remains visible is a strip one point wide and about one title bar tall.
    static var parkingOrigin: CGPoint {
        let union = NSScreen.screens.map(topLeftFrame).reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: union.maxX - 1, y: union.maxY - 1)
    }

    static func isParked(_ origin: CGPoint) -> Bool {
        origin.x >= parkingOrigin.x - 2
    }
}

/// The side zones of a screen: the band where windows shrink, and the outer part where they dock.
struct Zones {
    let visible: CGRect
    let bandWidth: CGFloat
    let dockWidth: CGFloat

    init(screen: NSScreen) {
        visible = Screens.visibleFrame(of: screen)
        bandWidth = max(260, visible.width * 0.16)
        dockWidth = max(110, visible.width * 0.05)
    }

    /// How far into the band a drag must go before shrinking begins, so that a shake near the edge
    /// of a large window isn't mistaken for a move toward the side.
    private let shrinkStart: CGFloat = 0.15

    /// 0 until a drag is clearly heading for the side, rising to 1 in the dock area.
    func shrinkProgress(atX x: CGFloat) -> CGFloat {
        max(0, (progress(atX: x) - shrinkStart) / (1 - shrinkStart))
    }

    func nearestEdge(to x: CGFloat) -> Edge { x - visible.minX < visible.maxX - x ? .left : .right }

    /// 0 in the working area, rising to 1 once the cursor reaches the dock area.
    func progress(atX x: CGFloat) -> CGFloat {
        let distance = min(x - visible.minX, visible.maxX - x)
        return min(1, max(0, (bandWidth - distance) / (bandWidth - dockWidth)))
    }
}

let widgetWidth: CGFloat = 240
let widgetMaxHeight: CGFloat = 170

func widgetScale(for size: CGSize) -> CGFloat {
    min(1, widgetWidth / size.width, widgetMaxHeight / size.height)
}
