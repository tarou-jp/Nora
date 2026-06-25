import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenshotOverlay {
    static func capture(completion: @escaping (NSImage?) -> Void) {
        guard let screen = NSScreen.main else { return completion(nil) }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            completion(nil)
            return
        }

        let win = ScreenshotWindow(screen: screen, completion: completion)
        win.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }
}

// MARK: - Window

private final class ScreenshotWindow: NSWindow {
    init(screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = SelectionView(screen: screen) { [weak self] image in
            NSCursor.pop()
            self?.orderOut(nil)
            completion(image)
        }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Selection view

private final class SelectionView: NSView {
    private let screen: NSScreen
    private let completion: (NSImage?) -> Void

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    init(screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        self.screen = screen
        self.completion = completion
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            NSCursor.pop()
            window?.orderOut(nil)
            completion(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        captureAndFinish()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.fill(bounds)

        guard let start = startPoint, let end = currentPoint else { return }
        let sel = selectionRect(from: start, to: end)
        guard sel.width > 2, sel.height > 2 else { return }

        // Punch out selected area
        ctx.setBlendMode(.clear)
        ctx.fill(sel)
        ctx.setBlendMode(.normal)

        // Border
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(sel.insetBy(dx: 0.75, dy: 0.75))

        // Size label
        let label = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
        label.draw(
            at: NSPoint(x: sel.minX, y: max(sel.minY - 22, 4)),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
        )
    }

    private func selectionRect(from a: NSPoint, to b: NSPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func captureAndFinish() {
        guard let start = startPoint, let end = currentPoint, let window else {
            completion(nil); return
        }
        let viewRect = selectionRect(from: start, to: end)
        guard viewRect.width > 5, viewRect.height > 5 else { completion(nil); return }

        // Convert view rect → Cocoa screen coords → Quartz coords (y=0 at top)
        let screenRect = window.convertToScreen(NSRect(origin: viewRect.origin, size: viewRect.size))
        let screenHeight = screen.frame.height
        let quartzRect = CGRect(
            x: screenRect.minX,
            y: screenHeight - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )

        window.orderOut(nil)
        NSCursor.pop()

        let captureScreen = screen
        let captureCompletion = completion

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    await MainActor.run { captureCompletion(nil) }
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = quartzRect
                let scale = captureScreen.backingScaleFactor
                config.width = max(1, Int(quartzRect.width * scale))
                config.height = max(1, Int(quartzRect.height * scale))

                try await Task.sleep(nanoseconds: 80_000_000)

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                let image = NSImage(cgImage: cgImage, size: NSSize(width: screenRect.width, height: screenRect.height))
                await MainActor.run { captureCompletion(image) }
            } catch {
                await MainActor.run { captureCompletion(nil) }
            }
        }
    }
}
