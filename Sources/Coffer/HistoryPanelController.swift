import AppKit
import Carbon.HIToolbox

/* The ⌘⌥C palette: a floating, nonactivating panel listing the history
   newest-first. ↑/↓ move the selection, Return (or a double-click) copies
   it back to the pasteboard, Escape or clicking elsewhere dismisses. */
final class HistoryPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    private let store: ClipboardStore
    private let panel: KeyCapturePanel
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing copied yet")

    init(store: ClipboardStore) {
        self.store = store
        let margin = Self.shadowMargin
        panel = KeyCapturePanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.glassSize.width + margin * 2,
                height: Self.glassSize.height + margin * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        configureContent()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: ClipboardStore.changed, object: store)
    }

    func toggle() {
        if panel.isVisible {
            panel.close()
        } else {
            show()
        }
    }

    private func configurePanel() {
        /* Borderless + transparent: the Liquid Glass view below supplies the
           whole visible shape, so it reads as a menu, not a window. */
        panel.isOpaque = false
        panel.backgroundColor = .clear
        /* No window-server shadow: it is snapshotted from content alpha at
           unpredictable times and kept showing up square behind the rounded
           glass. The shadow is drawn in-window instead (see the shadow view
           in configureContent), which is deterministic. */
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        /* Open on whatever Space (incl. full-screen apps) the user is on. */
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCommit = { [weak self] in self?.copySelection() }
        panel.onCancel = { [weak self] in self?.panel.close() }
    }

    private func configureContent() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        /* Real Liquid Glass — the same material context menus get on
           macOS 26. The content view is clipped to the glass shape so the
           scrolling list never pokes past the rounded corners. */
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)

        /* The glass sits inset in a transparent margin; a content-less layer
           with an explicit rounded shadowPath supplies the menu shadow. The
           panel is fixed-size, so plain frames beat Auto Layout here. */
        let glassFrame = NSRect(
            x: Self.shadowMargin, y: Self.shadowMargin,
            width: Self.glassSize.width, height: Self.glassSize.height)

        let shadow = NSView(frame: glassFrame)
        shadow.wantsLayer = true
        if let layer = shadow.layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 16
            layer.shadowOffset = CGSize(width: 0, height: -8)
            layer.shadowPath = CGPath(
                roundedRect: shadow.bounds,
                cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius,
                transform: nil)
        }

        let glass = NSGlassEffectView(frame: glassFrame)
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = content

        let root = NSView()
        root.addSubview(shadow)
        root.addSubview(glass)
        root.addSubview(
            HairlineBorderView(frame: glassFrame, cornerRadius: Self.cornerRadius))
        panel.contentView = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    /* Matches the corner rounding of Tahoe's context menus. */
    private static let cornerRadius: CGFloat = 18
    /* The visible glass card; the window is larger by shadowMargin on every
       side so the in-window shadow has room to render. */
    private static let glassSize = NSSize(width: 360, height: 320)
    private static let shadowMargin: CGFloat = 40

    private func show() {
        tableView.reloadData()
        tableView.sizeLastColumnToFit()
        updateEmptyState()
        if !store.items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        position()
        /* Nonactivating: the panel takes key focus for its own keyboard
           handling while the frontmost app stays active underneath. */
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)
    }

    /* Context-menu-style placement (à la Maccy): the glass card opens with
       its top-left corner at the mouse cursor, nudged back onto the screen
       when the cursor sits near an edge. The window itself extends
       shadowMargin past the card on every side. */
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = Self.glassSize
        var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        panel.setFrameOrigin(
            NSPoint(x: origin.x - Self.shadowMargin, y: origin.y - Self.shadowMargin))
    }

    private func copySelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.items.count else { return }
        let item = store.items[row]
        panel.close()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item, forType: .string)
        /* The watcher sees this write and promotes the item to the front —
           exactly the re-copy behavior the history model already defines. */
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !store.items.isEmpty
    }

    @objc private func rowDoubleClicked() {
        copySelection()
    }

    @objc private func storeChanged() {
        guard panel.isVisible else { return }
        let selected = tableView.selectedRow
        tableView.reloadData()
        updateEmptyState()
        if !store.items.isEmpty {
            let row = min(max(selected, 0), store.items.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let identifier = NSUserInterfaceItemIdentifier("ItemCell")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 13)
        }
        label.stringValue = ClipboardHistory.previewLine(for: store.items[row])
        return label
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        /* The debug hook needs the panel to survive focus loss so it can be
           screenshotted from a script; real runs dismiss like a menu. */
        guard ProcessInfo.processInfo.environment["COFFER_DEBUG_PANEL"] != "1" else { return }
        panel.close()
    }
}

/* The edge treatment system context menus get: a faint dark outline plus a
   bright inner rim, which reads against light and dark backdrops alike.
   Colors re-resolve on appearance changes via updateLayer. */
private final class HairlineBorderView: NSView {
    private let outerRing = CALayer()
    private let innerRing = CALayer()

    init(frame: NSRect, cornerRadius: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true

        outerRing.frame = bounds
        outerRing.cornerRadius = cornerRadius
        outerRing.borderWidth = 0.5

        innerRing.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        innerRing.cornerRadius = cornerRadius - 0.5
        innerRing.borderWidth = 1

        for ring in [outerRing, innerRing] {
            ring.cornerCurve = .continuous
            layer?.addSublayer(ring)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        outerRing.borderColor =
            NSColor.black.withAlphaComponent(isDark ? 0.5 : 0.15).cgColor
        innerRing.borderColor =
            NSColor.white.withAlphaComponent(isDark ? 0.25 : 0.5).cgColor
    }

    /* Purely decorative: never swallow clicks meant for the list. */
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/* A nonactivating panel that can take keyboard focus, intercepting Return
   and Escape before the responder chain so the table view's own key
   handling (arrows, type-select) keeps working untouched. */
private final class KeyCapturePanel: NSPanel {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                onCommit?()
                return
            case kVK_Escape:
                onCancel?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}
