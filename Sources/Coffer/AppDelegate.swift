import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let store = ClipboardStore()
    private let hotKeys = HotKeyCenter()
    private var watcher: PasteboardWatcher?
    private var historyPanel: HistoryPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        historyPanel = HistoryPanelController(store: store)

        let watcher = PasteboardWatcher { [weak self] item in
            self?.store.add(item)
        }
        watcher.start()
        self.watcher = watcher

        hotKeys.register(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey) | UInt32(optionKey)
        ) { [weak self] in
            self?.historyPanel?.toggle()
        }

        /* Dev hook: COFFER_DEBUG_PANEL=1 seeds the history and opens the
           panel right away, so the palette can be eyeballed (and
           screenshotted) without priming the real pasteboard. */
        if ProcessInfo.processInfo.environment["COFFER_DEBUG_PANEL"] == "1" {
            for sample in ["Third sample item", "Second sample item", "First sample item"] {
                store.add(sample)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.historyPanel?.toggle()
            }
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Coffer")

        let menu = NSMenu()
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Coffer \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        let history = NSMenuItem(
            title: "Clipboard History",
            action: #selector(showHistory), keyEquivalent: "c")
        history.keyEquivalentModifierMask = [.command, .option]
        history.target = self
        menu.addItem(history)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Coffer",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showHistory() {
        historyPanel?.toggle()
    }
}
