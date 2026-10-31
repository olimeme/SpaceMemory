import AppKit
import ScreenCaptureKit

/// A live ScreenCaptureKit feed of one window, drawn into a layer.
final class WindowCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    enum Quality { case full, widget, deckCard }

    let windowID: CGWindowID
    let size: CGSize
    let layer = CALayer()

    private(set) var frameCount = 0
    var hasFrame: Bool { frameCount > 0 }
    var onStopped: (() -> Void)?

    private var stream: SCStream?
    private var scWindow: SCWindow?
    private var quality = Quality.full
    private var stopped = false
    private var latestSample: CMSampleBuffer?
    private let frameQueue = DispatchQueue(label: "capture-frames", qos: .userInteractive)

    init(windowID: CGWindowID, size: CGSize) {
        self.windowID = windowID
        self.size = size
        super.init()
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.contentsGravity = .resize
        layer.cornerRadius = 10
        layer.masksToBounds = true
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    /// Listing the windows is slow, so captures started together should share one listing.
    static func listWindows() -> Task<SCShareableContent, Error> {
        Task { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
    }

    func start(listing: Task<SCShareableContent, Error> = WindowCapture.listWindows()) {
        Task {
            do {
                let content = try await listing.value
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    Log.write("capture: window \(windowID) not found by ScreenCaptureKit")
                    return
                }
                try await begin(window)
            } catch {
                Log.write("capture: failed for \(windowID): \(error.localizedDescription)")
            }
        }
    }

    private func begin(_ window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration(for: quality), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        await MainActor.run {
            self.scWindow = window
            if self.stopped {
                stream.stopCapture { _ in }
            } else {
                self.stream = stream
            }
        }
    }

    func setQuality(_ newQuality: Quality) {
        guard newQuality != quality else { return }
        quality = newQuality
        stream?.updateConfiguration(configuration(for: newQuality)) { error in
            if let error { Log.write("capture: reconfigure failed: \(error.localizedDescription)") }
        }
    }

    func stop() {
        stopped = true
        stream?.stopCapture { _ in }
        stream = nil
    }

    /// The part of the buffer the window actually covers, according to ScreenCaptureKit.
    private(set) var lastContentRect: CGRect = .zero

    /// The newest frame from the live stream, as opposed to a separate screenshot.
    func latestFrameImage() -> CGImage? {
        guard let buffer = latestSample?.imageBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent)
    }

    /// A one-off still of the window, used by the probe to check that parked windows still render.
    func screenshot() async -> CGImage? {
        guard let scWindow else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: configuration(for: .full))
    }

    private func configuration(for quality: Quality) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let pixelScale: CGFloat = quality == .full ? backing : 2 * widgetScale(for: size)
        config.width = max(2, Int(size.width * pixelScale))
        config.height = max(2, Int(size.height * pixelScale))
        config.scalesToFit = true
        let framesPerSecond: Int32 = quality == .full ? 30 : quality == .widget ? 10 : 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let contentRectValue = attachments.first?[.contentRect] as? NSDictionary
        DispatchQueue.main.async { [self] in
            frameCount += 1
            if let contentRectValue {
                lastContentRect = CGRect(dictionaryRepresentation: contentRectValue) ?? .zero
            }
            // Holding the sample stops ScreenCaptureKit recycling the surface while it is on screen.
            latestSample = sampleBuffer
            layer.contents = surface
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("capture: stream for \(windowID) stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [self] in onStopped?() }
    }
}

/// Refuses dropped content. A card isn't the window it shows, and a drop let through would land on
/// whatever is behind the card, which may be the desktop.
private final class CardView: NSView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

/// A click-through floating panel showing a window's live preview, with an optional header for docked cards.
final class PreviewPanel {
    let panel: NSPanel
    private let header: NSView
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(capture: WindowCapture) {
        let initial = CGRect(x: 0, y: 0, width: 240, height: 160)
        panel = NSPanel(contentRect: initial, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // The event tap handles all input, so the panel never has to take focus from the working window.
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]

        let container = CardView(frame: initial)
        container.registerForDraggedTypes([.fileURL, .URL, .string, .html, .rtf, .tiff, .png, .pdf, .fileContents,
                                           NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                                           NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
                                           NSPasteboard.PasteboardType("public.utf8-plain-text"),
                                           NSPasteboard.PasteboardType("public.data")])
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        let preview = NSView(frame: initial)
        preview.layer = capture.layer
        preview.wantsLayer = true
        preview.autoresizingMask = [.width, .height]
        container.addSubview(preview)

        // A shrunken title bar is unreadable, and the top strip is all that shows of a card in a deck.
        header = NSView(frame: CGRect(x: 0, y: initial.height - 24, width: initial.width, height: 24))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        header.autoresizingMask = [.width, .minYMargin]
        header.isHidden = true
        iconView.frame = CGRect(x: 6, y: 4, width: 16, height: 16)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        header.addSubview(iconView)
        titleLabel.frame = CGRect(x: 27, y: 4, width: initial.width - 33, height: 16)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.autoresizingMask = [.width]
        header.addSubview(titleLabel)
        container.addSubview(header)

        panel.contentView = container
    }

    /// The panel's frame in top-left coordinates.
    private(set) var frame: CGRect = .zero

    func setFrame(_ rect: CGRect, animated: Bool = false) {
        frame = rect
        let target = Screens.toAppKit(rect)
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [panel] in
                panel.invalidateShadow()
            })
        } else {
            panel.setFrame(target, display: false)
        }
    }

    /// Moves with no animation, and cancels one in progress, which would otherwise finish at its old target.
    func jump(to rect: CGRect) {
        frame = rect
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(Screens.toAppKit(rect), display: true)
        }
        panel.invalidateShadow()
    }

    func setHeader(title: String, icon: NSImage?) {
        titleLabel.stringValue = title
        iconView.image = icon
    }

    func showHeader(_ visible: Bool) { header.isHidden = !visible }
    /// Only for the length of a content drag: the rest of the time, the event tap handles all input.
    func setRefusesDrops(_ refuses: Bool) { panel.ignoresMouseEvents = !refuses }
    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
}
