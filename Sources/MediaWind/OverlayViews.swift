import AppKit

/// Dark background of the viewer window. Owns keyboard focus (so AVPlayerView doesn't) and
/// reports mouse movement for the hover arrows and the full-screen overlay.
final class ViewerRootView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { onMouseMoved?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

/// Round, translucent ‹ › button shown at the window edges on hover.
final class ArrowButton: NSView {
    enum Direction { case left, right }

    let direction: Direction
    var action: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }
    private var isHovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(direction: Direction) {
        self.direction = direction
        super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        wantsLayer = true
        toolTip = direction == .left ? "Previous (←)" : "Next (→)"
        setAccessibilityRole(.button)
        setAccessibilityLabel(direction == .left ? "Previous" : "Next")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSColor(white: 0, alpha: isPressed ? 0.75 : (isHovering ? 0.6 : 0.42)).setFill()
        circle.fill()
        NSColor(white: 1, alpha: 0.22).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let name = direction == .left ? "chevron.left" : "chevron.right"
        let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let nudge: CGFloat = direction == .left ? -1 : 1
        symbol.draw(in: NSRect(x: bounds.midX - size.width / 2 + nudge, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { action?() }
    }
}

/// Rounded dark label: the full-screen "IMG_1234.HEIC — 12 of 348" overlay.
final class PillLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// Text with an SF Symbol beside it, e.g. the "3× ▶▶" badge while scanning a video.
    func setText(_ text: String, symbol: String, symbolFirst: Bool) {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        let icon = NSAttributedString(attachment: attachment)
        let words = NSAttributedString(string: text)
        let string = NSMutableAttributedString()
        for part in symbolFirst ? [icon, words] : [words, icon] {
            if string.length > 0 { string.append(NSAttributedString(string: " ")) }
            string.append(part)
        }
        string.addAttributes([.font: label.font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.white],
                             range: NSRange(location: 0, length: string.length))
        label.attributedStringValue = string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Centered icon, title, explanation and buttons: used whenever something can't be shown,
/// so the window is never just blank.
final class MessageView: NSView {
    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonRow = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.55)]))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = NSColor(white: 1, alpha: 0.7)
        detailLabel.alignment = .center
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.setCustomSpacing(18, after: detailLabel)
        stack.addArrangedSubview(buttonRow)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String { titleLabel.stringValue }

    func configure(symbol: String, title: String, detail: String?, buttons: [NSView]) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach { buttonRow.addArrangedSubview($0) }
        buttonRow.isHidden = buttons.isEmpty
    }
}

/// Strip along the bottom explaining a problem that doesn't block the current file
/// (e.g. no permission to browse the folder).
final class BannerView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let row = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.28, green: 0.2, blue: 0.05, alpha: 0.92).cgColor
        layer?.cornerRadius = 10
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .white
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(label)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, buttons: [NSView]) {
        label.stringValue = text
        row.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        buttons.forEach { row.addArrangedSubview($0) }
    }
}
