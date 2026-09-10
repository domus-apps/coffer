import AppKit
import ServiceManagement
import SwiftUI

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
    private let splitViewController: SettingsSplitViewController

    init(updater: UpdaterController) {
        splitViewController = SettingsSplitViewController(updater: updater)
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
        window.setContentSize(NSSize(width: 640, height: 500))
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
    private let generalPane: NSViewController
    private var currentPane: NSViewController?

    init(updater: UpdaterController) {
        /* The pane is a SwiftUI grouped Form — the exact section-header +
           rounded-box arrangement Xcode's settings use — hosted inside the
           AppKit split chrome. */
        let model = SettingsModel(updater: updater)
        generalPane = NSHostingController(rootView: GeneralSettingsView(model: model))
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
        let target: CGFloat = atRest ? 0 : 1
        /* Only when the value changes. The animator sets the model value at
           once, so a pocket already at the target is skipped. Starting an
           animation on every layout pass dirtied the view for the next
           commit, which laid the sidebar out again, which started another
           animation: a loop that kept each app near 7% CPU for as long as
           it ran, the closed (retained) Settings window included. */
        for subview in scrollView.subviews
        where String(describing: type(of: subview)) == "NSScrollPocket"
            && subview.alphaValue != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                subview.animator().alphaValue = target
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

// MARK: - SwiftUI bridge

/* Preferences live in UserDefaults (via AppPreferences); this object just
   republishes their change notification so SwiftUI re-reads, and carries the
   pieces that aren't preferences (SMAppService, the updater). */
final class SettingsModel: ObservableObject {
    let updater: UpdaterController

    init(updater: UpdaterController) {
        self.updater = updater
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /* SMAppService needs a real app bundle; a bare `swift run` binary has
       no bundle identifier to register. */
    var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Coffer: launch-at-login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return version + build
    }

    func binding<Value>(
        _ get: @escaping () -> Value, _ set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

// MARK: - General pane

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        "Launch at login",
                        isOn: model.binding({ model.launchAtLogin }, { model.launchAtLogin = $0 })
                    )
                    .disabled(!model.isBundledApp)
                    if !model.isBundledApp {
                        Text("Available in the bundled app only (Scripts/bundle.sh).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        "Hide menu bar icon",
                        isOn: model.binding(
                            { AppPreferences.isMenuBarIconHidden },
                            { AppPreferences.isMenuBarIconHidden = $0 }))
                    Text(
                        "⌥⌘C still opens the history. While hidden, launch Coffer again to "
                            + "open Settings. The app appears in the Dock only while this "
                            + "window is open."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                HistoryLimitRow(model: model)
            } header: {
                Text("History")
            } footer: {
                let range = AppPreferences.historyLimitRange
                Text(
                    "Between \(range.lowerBound) and \(range.upperBound). The history lives "
                        + "in memory, images in full, so a higher cap uses more RAM. Lowering "
                        + "it removes the oldest items immediately.")
            }

            Section("Updates") {
                LabeledContent("Version", value: model.versionLabel)
                Button("Check for Updates…") {
                    model.updater.checkForUpdates()
                }
                .disabled(!model.updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }
}

/* The cap is typed or stepped. Both paths funnel through AppPreferences,
   which clamps, and the clamped value is written back to the field so
   out-of-range input visibly snaps to the nearest bound. The text is kept
   as a plain string: a number formatter's localized "1,000" would re-parse
   as 1 on the next commit. */
private struct HistoryLimitRow: View {
    @ObservedObject var model: SettingsModel
    @State private var text = "\(AppPreferences.historyLimit)"
    @FocusState private var isEditing: Bool

    var body: some View {
        LabeledContent("Keep clipboard items") {
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .focused($isEditing)
                    .onSubmit(commitText)
                    /* Commit on focus loss too, so tabbing away doesn't
                       silently drop a typed value. */
                    .onChange(of: isEditing) { _, editing in
                        if !editing { commitText() }
                    }
                Stepper(
                    "",
                    value: model.binding(
                        { AppPreferences.historyLimit }, { AppPreferences.historyLimit = $0 }),
                    in: AppPreferences.historyLimitRange, step: 10
                )
                .labelsHidden()
                Button("Reset to Default") {
                    AppPreferences.historyLimit = AppPreferences.defaultHistoryLimit
                }
                .controlSize(.small)
                .disabled(AppPreferences.historyLimit == AppPreferences.defaultHistoryLimit)
            }
        }
        /* The stepper and the reset button change the stored value behind
           the field's back; mirror it unless the user is mid-edit. */
        .onReceive(model.objectWillChange) { _ in
            if !isEditing { text = "\(AppPreferences.historyLimit)" }
        }
    }

    private func commitText() {
        if let proposed = Int(text.trimmingCharacters(in: .whitespaces)) {
            AppPreferences.historyLimit = proposed
        }
        text = "\(AppPreferences.historyLimit)"
    }
}
