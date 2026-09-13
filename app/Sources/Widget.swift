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

/// QR + link + status. Two looks: a dark card for the desktop widget, and a flat native layout for the menu.
final class QRCard: NSView {
    enum Style { case desktop, menu }
    static let desktopSize = NSSize(width: 236, height: 318)
    static let menuSize = NSSize(width: 280, height: 248)

    let style: Style
    private let title = NSTextField(labelWithString: "Remote Mouse")
    private let qrBox = NSView()
    private let qr = NSImageView()
    private let hint = NSTextField(labelWithString: "Scan with your phone's camera")
    private let urlLabel = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")

    init(style: Style) {
        self.style = style
        super.init(frame: NSRect(origin: .zero, size: style == .desktop ? QRCard.desktopSize : QRCard.menuSize))
        wantsLayer = true
        let dark = style == .desktop
        if dark {
            layer?.cornerRadius = 18
            layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.96).cgColor
        }
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.isHidden = !dark

        qrBox.wantsLayer = true
        qrBox.layer?.backgroundColor = NSColor.white.cgColor
        qrBox.layer?.cornerRadius = 12
        qr.imageScaling = .scaleProportionallyUpOrDown
        qrBox.addSubview(qr)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = dark ? NSColor(white: 0.5, alpha: 1) : .secondaryLabelColor
        hint.alignment = .center

        urlLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        urlLabel.textColor = dark ? NSColor(white: 0.75, alpha: 1) : .labelColor
        urlLabel.alignment = .center
        urlLabel.maximumNumberOfLines = 2
        urlLabel.lineBreakMode = .byWordWrapping
        urlLabel.isSelectable = false

        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail

        [title, qrBox, hint, urlLabel, status].forEach(addSubview)
        layoutViews()
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layoutViews() {
        let w = bounds.width
        if style == .desktop {
            title.frame = NSRect(x: 12, y: bounds.height - 34, width: w - 24, height: 20)
            qrBox.frame = NSRect(x: (w - 176) / 2, y: bounds.height - 34 - 8 - 176, width: 176, height: 176)
        } else {
            qrBox.frame = NSRect(x: (w - 168) / 2, y: bounds.height - 10 - 168, width: 168, height: 168)
        }
        qr.frame = qrBox.bounds.insetBy(dx: 8, dy: 8)
        hint.frame = NSRect(x: 12, y: qrBox.frame.minY - 22, width: w - 24, height: 16)
        urlLabel.frame = NSRect(x: 6, y: hint.frame.minY - 32, width: w - 12, height: 28)
        let statusY = style == .desktop ? 14 : urlLabel.frame.minY - 16      // desktop card: pinned to the bottom edge
        status.frame = NSRect(x: 12, y: statusY, width: w - 24, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() { applyAppearance() }
    private func applyAppearance() {
        guard style == .menu else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {      // resolve dynamic colors for the layer
            qrBox.layer?.borderWidth = 1
            qrBox.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func update(url: String, statusText: String, ok: Bool) {
        qr.image = QR.image(url, size: qr.bounds.width)
        // if the link has to wrap, wrap right before "?k=" (zero-width space) and nowhere inside it (word joiners)
        urlLabel.stringValue = url.replacingOccurrences(of: "?k=", with: "\u{200B}?\u{2060}k\u{2060}=\u{2060}")
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let dot = ok ? NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.52, alpha: 1)
                     : NSColor(calibratedRed: 1, green: 0.36, blue: 0.36, alpha: 1)
        let textColor: NSColor = style == .desktop ? NSColor(white: 0.75, alpha: 1) : .secondaryLabelColor
        let s = NSMutableAttributedString(string: "\u{25CF}  ", attributes: [.foregroundColor: dot, .font: NSFont.systemFont(ofSize: 9), .paragraphStyle: para])
        s.append(NSAttributedString(string: statusText, attributes: [.foregroundColor: textColor, .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: para]))
        status.attributedStringValue = s
    }

    // dragging the card moves the widget window
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Borderless panel pinned just above the desktop icons: visible on the desktop, under every normal window.
final class WidgetWindow: NSPanel {
    let card = QRCard(style: .desktop)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: QRCard.desktopSize),
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
            setFrameOrigin(NSPoint(x: v.maxX - QRCard.desktopSize.width - 28, y: v.maxY - QRCard.desktopSize.height - 28))
        }
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
