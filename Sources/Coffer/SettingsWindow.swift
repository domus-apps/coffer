import AppKit

// MARK: - Window

/* One pane today; future panes (e.g. hot keys, excluded apps) slot in by
   extending this enum. */
enum SettingsPane: Int, CaseIterable {
    case general

    var title: String {
        switch self {
        case .general: "General"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        }
    }
}

/* System Settings-style window: full-height sidebar on the left, panes on
   the right. The style mask keeps all three traffic lights live (zoom stays
   disabled by macOS itself while the window is not resizable-by-content,
   matching native settings windows). */
final class SettingsWindowController: NSWindowController {
    private let splitViewController = SettingsSplitViewController()

    init() {
        let window = NSWindow(contentViewController: splitViewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        /* A toolbar (even an empty one) is required for the full-height
           sidebar look. The tall unified style centers the traffic lights
           in a roomier title bar (like Xcode's settings window) instead of
           pinning them to the top-left corner. */
        window.toolbarStyle = .unified
        let toolbar = NSToolbar()
        /* An empty toolbar defaults to .iconAndLabel, which inflates the
           unified title bar to 66pt; .iconOnly gives the standard 52pt that
           Xcode's settings window uses. */
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 340))
        window.center()

        super.init(window: window)
        splitViewController.onPaneChange = { [weak window] pane in
            window?.title = pane.title
        }
        splitViewController.show(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class SettingsSplitViewController: NSSplitViewController {
    var onPaneChange: ((SettingsPane) -> Void)?

    private let sidebar = SettingsSidebarViewController()
    private let paneContainer = NSViewController()
    private let generalPane = GeneralPaneViewController()
    private var currentPane: NSViewController?

    init() {
        super.init(nibName: nil, bundle: nil)

        paneContainer.view = NSView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 160
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: paneContainer))

        sidebar.onSelect = { [weak self] pane in
            self?.show(pane)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ pane: SettingsPane) {
        let next: NSViewController =
            switch pane {
            case .general: generalPane
            }
        guard next !== currentPane else { return }

        if let currentPane {
            currentPane.view.removeFromSuperview()
            currentPane.removeFromParent()
        }
        paneContainer.addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: paneContainer.view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: paneContainer.view.bottomAnchor),
            next.view.leadingAnchor.constraint(equalTo: paneContainer.view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: paneContainer.view.trailingAnchor),
        ])
        currentPane = next

        sidebar.select(pane)
        onPaneChange?(pane)
    }
}

// MARK: - Sidebar

final class SettingsSidebarViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onSelect: ((SettingsPane) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /* Extra top inset below the safe area. Zero, like Xcode's settings
       sidebar: the first row sits flush against the title bar boundary. */
    private static let scrollEdgeFadeClearance: CGFloat = 0

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        /* Managed manually in viewDidLayout: the automatic inset stops at
           the safe area, which leaves the first row inside the fade. */
        scrollView.automaticallyAdjustsContentInsets = false
        view = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateScrollEdgeFade()
        }
    }

    /* The soft scroll-edge fade (macOS 26) is not scroll-aware: its gradient
       backdrop hangs ~10pt below the title bar at all times, dimming a first
       row that sits flush against the boundary even when nothing is scrolled
       under the bar. Mirror Xcode's settings sidebar instead: fade only while
       content is actually scrolled under. The pocket is a private AppKit view
       (NSScrollPocket), so this is a defensive class-name lookup — if AppKit
       renames it, the system's default behavior simply returns. */
    private func updateScrollEdgeFade() {
        let restTop = -scrollView.contentInsets.top
        let atRest = scrollView.contentView.bounds.minY <= restTop + 0.5
        for subview in scrollView.subviews
        where String(describing: type(of: subview)) == "NSScrollPocket" {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                subview.animator().alphaValue = atRest ? 0 : 1
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        /* The pocket can appear after the first layout pass, so re-evaluate
           on every layout, not only when the inset changes. */
        defer { updateScrollEdgeFade() }
        let top = view.safeAreaInsets.top + Self.scrollEdgeFadeClearance
        guard scrollView.contentInsets.top != top else { return }
        let wasAtTop = scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if wasAtTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func select(_ pane: SettingsPane) {
        guard tableView.selectedRow != pane.rawValue else { return }
        tableView.selectRowIndexes(IndexSet(integer: pane.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsPane.allCases.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let pane = SettingsPane(rawValue: row) else { return nil }

        let cell = NSTableCellView()
        let imageView = NSImageView(
            image: NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
                ?? NSImage())
        let textField = NSTextField(labelWithString: pane.title)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let pane = SettingsPane(rawValue: tableView.selectedRow) else { return }
        onSelect?(pane)
    }
}

// MARK: - General pane

final class GeneralPaneViewController: NSViewController {
    private lazy var limitField: NSTextField = {
        let field = NSTextField(string: "\(AppPreferences.historyLimit)")
        field.alignment = .right
        field.target = self
        field.action = #selector(limitFieldChanged)
        /* Commit on focus loss too, so tabbing away doesn't silently drop
           a typed value. */
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        return field
    }()

    private lazy var limitStepper: NSStepper = {
        let stepper = NSStepper()
        stepper.minValue = Double(AppPreferences.historyLimitRange.lowerBound)
        stepper.maxValue = Double(AppPreferences.historyLimitRange.upperBound)
        stepper.increment = 10
        stepper.valueWraps = false
        stepper.integerValue = AppPreferences.historyLimit
        stepper.target = self
        stepper.action = #selector(limitStepperChanged)
        return stepper
    }()

    private lazy var resetButton: NSButton = {
        let button = NSButton(
            title: "Reset to Default", target: self, action: #selector(resetLimit))
        button.controlSize = .small
        return button
    }()

    private func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        return note
    }

    override func loadView() {
        let limitRow = NSStackView(views: [
            NSTextField(labelWithString: "Keep clipboard items:"), limitField, limitStepper,
            resetButton,
        ])
        limitRow.orientation = .horizontal
        limitField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        resetButton.isEnabled = AppPreferences.historyLimit != AppPreferences.defaultHistoryLimit

        let range = AppPreferences.historyLimitRange
        let limitNote = note(
            "Between \(range.lowerBound) and \(range.upperBound). The history lives in "
                + "memory — images in full — so a higher cap uses more RAM. Lowering it "
                + "removes the oldest items immediately.")

        let stack = NSStackView(views: [limitRow, limitNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            limitNote.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        view = container
    }

    @objc private func limitFieldChanged() {
        applyLimit(limitField.integerValue)
    }

    @objc private func limitStepperChanged() {
        applyLimit(limitStepper.integerValue)
    }

    @objc private func resetLimit() {
        applyLimit(AppPreferences.defaultHistoryLimit)
    }

    /* Both controls funnel through here: the preference clamps, and the
       clamped value is written back so out-of-range input visibly snaps
       to the nearest bound. Written as a plain string — integerValue's
       localized "1,000" would re-parse as 1 on the next commit. */
    private func applyLimit(_ proposed: Int) {
        AppPreferences.historyLimit = proposed
        let applied = AppPreferences.historyLimit
        limitField.stringValue = "\(applied)"
        limitStepper.integerValue = applied
        resetButton.isEnabled = applied != AppPreferences.defaultHistoryLimit
    }
}
