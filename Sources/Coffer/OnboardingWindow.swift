import AppKit

/* First-run onboarding: what Coffer is and the one shortcut that drives
   it — no permission gate, since watching the pasteboard needs none. The
   window has no close button; the only way out is the Start button, and
   completion is persisted only at that click, so quitting (or
   force-quitting) mid-onboarding brings the onboarding back on the next
   launch. */
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onComplete: () -> Void

    private lazy var startButton = NSButton(
        title: "Start Using Coffer", target: self, action: #selector(start))

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        /* No .closable: the traffic-light close button never appears. */
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* Closing only via start(). */
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    // MARK: - Content

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Welcome to Coffer")
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let intro = NSTextField(
            wrappingLabelWithString:
                "Coffer remembers everything you copy — text, images, and files — "
                + "in a searchable history. Nothing you copy is lost to the next "
                + "⌘C again, and password manager entries are never recorded.")
        intro.font = .systemFont(ofSize: 14)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.preferredMaxLayoutWidth = 470

        let illustration = OnboardingIllustrationView()
        illustration.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            illustration.widthAnchor.constraint(equalToConstant: 480),
            illustration.heightAnchor.constraint(equalToConstant: 190),
        ])

        let shortcutRow = NSStackView(
            views: [
                labelView("Press"),
                keycap("⌘"), keycap("⌥"), keycap("C"),
                labelView("to open your clipboard history"),
            ])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 6

        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"

        let stack = NSStackView(
            views: [title, intro, illustration, shortcutRow, startButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(22, after: intro)
        stack.setCustomSpacing(24, after: shortcutRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
        return container
    }

    private func labelView(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func keycap(_ symbol: String) -> NSView {
        KeycapView(symbol: symbol)
    }

    @objc private func start() {
        window?.delegate = nil
        onComplete()
        close()
    }
}

/* One keyboard key, drawn as a keycap. */
private final class KeycapView: NSView {
    private let symbol: String

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.quaternarySystemFill.setFill()
        body.fill()
        NSColor.separatorColor.setStroke()
        body.lineWidth = 1
        body.stroke()

        let text = NSAttributedString(
            string: symbol,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let size = text.size()
        text.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/* A drawn "screenshot" of Coffer's palette: the glass card with a search
   field, a selected row, and media rows with thumbnails. Drawn (not a
   bundled image) so it stays crisp at any backing scale and needs no
   resource plumbing. */
private final class OnboardingIllustrationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let canvas = bounds

        // Backdrop in the app's green
        let backdrop = NSBezierPath(roundedRect: canvas, xRadius: 12, yRadius: 12)
        NSGradient(
            starting: NSColor(srgbRed: 0.07, green: 0.2, blue: 0.14, alpha: 1),
            ending: NSColor(srgbRed: 0.04, green: 0.1, blue: 0.07, alpha: 1)
        )?.draw(in: backdrop, angle: -90)

        // The palette card
        let card = NSRect(x: canvas.midX - 130, y: 14, width: 260, height: canvas.height - 28)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor(srgbRed: 0.93, green: 0.95, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Search field
        let search = NSRect(x: card.minX + 10, y: card.maxY - 32, width: card.width - 20, height: 22)
        NSColor.black.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: search, xRadius: 6, yRadius: 6).fill()
        NSAttributedString(
            string: "Search",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.black.withAlphaComponent(0.35),
            ]
        ).draw(at: NSPoint(x: search.minX + 8, y: search.midY - 6))

        // Rows: selected text row, plain text row, image row, file row
        var y = search.minY - 30
        drawRow(in: card, y: y, selected: true, kind: .text(width: 150))
        y -= 26
        drawRow(in: card, y: y, selected: false, kind: .text(width: 110))
        y -= 26
        drawRow(in: card, y: y, selected: false, kind: .image)
        y -= 26
        drawRow(in: card, y: y, selected: false, kind: .file)
    }

    private enum RowKind {
        case text(width: CGFloat)
        case image
        case file
    }

    private func drawRow(in card: NSRect, y: CGFloat, selected: Bool, kind: RowKind) {
        let row = NSRect(x: card.minX + 10, y: y, width: card.width - 20, height: 22)
        if selected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
        }
        let content = NSColor.black.withAlphaComponent(selected ? 0 : 0.35)
        // Text on the accent: white on every accent but a light one (yellow),
        // where the system itself switches to dark text. Judge by brightness.
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let accentIsLight = accent.map {
            0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent > 0.7
        } ?? false
        let textTint = selected ? (accentIsLight ? NSColor.black : NSColor.white) : content

        var x = row.minX + 8
        switch kind {
        case .image:
            let thumb = NSRect(x: x, y: row.midY - 7, width: 18, height: 14)
            NSColor.systemTeal.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
            x += 24
        case .file:
            let thumb = NSRect(x: x, y: row.midY - 8, width: 13, height: 16)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).stroke()
            x += 20
        case .text:
            break
        }

        let barWidth: CGFloat
        switch kind {
        case .text(let width): barWidth = width
        case .image: barWidth = 70
        case .file: barWidth = 90
        }
        let bar = NSRect(x: x, y: row.midY - 3, width: barWidth, height: 6)
        textTint.withAlphaComponent(selected ? 0.95 : 0.35).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
    }
}
