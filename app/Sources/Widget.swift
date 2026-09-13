import Cocoa
import CoreImage

enum QR {
    /// Crisp QR code rendered with nearest-neighbour scaling.
    static func image(_ text: String, size: CGFloat) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage, let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: rect)
            return true
        }
    }
}

/// Shared card layout used both inside the menu and in the desktop widget.
final class QRCard: NSView {
    private let title = NSTextField(labelWithString: "Remote Mouse")
    private let qrBox = NSView()
    private let qr = NSImageView()
    private let urlLabel = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView()
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Scan with your phone's camera")

    static let size = NSSize(width: 236, height: 318)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.96).cgColor

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.alignment = .center

        qrBox.wantsLayer = true
        qrBox.layer?.backgroundColor = NSColor.white.cgColor
        qrBox.layer?.cornerRadius = 12
        qr.imageScaling = .scaleProportionallyUpOrDown
        qrBox.addSubview(qr)

        urlLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        urlLabel.textColor = NSColor(white: 0.72, alpha: 1)
        urlLabel.alignment = .center
        urlLabel.maximumNumberOfLines = 2
        urlLabel.lineBreakMode = .byCharWrapping

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor(white: 0.72, alpha: 1)
        status.lineBreakMode = .byTruncatingTail

        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = NSColor(white: 0.5, alpha: 1)
        hint.alignment = .center

        [title, qrBox, urlLabel, dot, status, hint].forEach(addSubview)
        layoutViews()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layoutViews() {
        let w = bounds.width
        title.frame = NSRect(x: 12, y: bounds.height - 34, width: w - 24, height: 20)
        let box: CGFloat = 176
        qrBox.frame = NSRect(x: (w - box) / 2, y: bounds.height - 34 - 8 - box, width: box, height: box)
        qr.frame = qrBox.bounds.insetBy(dx: 8, dy: 8)
        hint.frame = NSRect(x: 12, y: qrBox.frame.minY - 20, width: w - 24, height: 16)
        urlLabel.frame = NSRect(x: 12, y: hint.frame.minY - 32, width: w - 24, height: 30)
        dot.frame = NSRect(x: 16, y: 18, width: 8, height: 8)
        status.frame = NSRect(x: 30, y: 12, width: w - 42, height: 20)
    }

    func update(url: String, statusText: String, ok: Bool) {
        qr.image = QR.image(url, size: 160)
        urlLabel.stringValue = url
        status.stringValue = statusText
        dot.layer?.backgroundColor = (ok ? NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.52, alpha: 1)
                                         : NSColor(calibratedRed: 1, green: 0.36, blue: 0.36, alpha: 1)).cgColor
    }

    // dragging the card moves the widget window
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Borderless panel pinned just above the desktop icons: visible on the desktop, under every normal window.
final class WidgetWindow: NSPanel {
    let card = QRCard(frame: NSRect(origin: .zero, size: QRCard.size))

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: QRCard.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = card
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // just above the desktop icons, below every normal window (set last: isFloatingPanel etc. reset the level)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        let hadFrame = UserDefaults.standard.string(forKey: "NSWindow Frame QRWidget") != nil
        setFrameAutosaveName("QRWidget")
        if !hadFrame, let s = NSScreen.main {
            let v = s.visibleFrame
            setFrameOrigin(NSPoint(x: v.maxX - QRCard.size.width - 28, y: v.maxY - QRCard.size.height - 28))
        }
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
