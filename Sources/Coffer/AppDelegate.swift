import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let store = ClipboardStore(persistence: HistoryPersistence())
    private let updater = UpdaterController()
    private let hotKeys = HotKeyCenter()
    private var watcher: PasteboardWatcher?
    private var historyPanel: HistoryPanelController?
    private var onboardingController: OnboardingWindowController?
    private var settingsWindowController: SettingsWindowController?

    private static let onboardingCompletedKey = "onboarding.completed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        /* A translocated launch relaunches itself from the real bundle —
           nothing else must start in this doomed instance. */
        if TranslocationHealer.healIfNeeded() { return }

        setUpMainMenu()
        updateStatusItemVisibility()
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusItemVisibility()
        }

        /* Completion is only recorded when onboarding is finished properly,
           so an interrupted (or force-quit) run shows it again. */
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            || CommandLine.arguments.contains("--onboarding")
        {
            showOnboarding()
        }

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
            /* Enough entries that the list scrolls, so the edge fades can
               be eyeballed too. */
            for index in stride(from: 30, through: 1, by: -1) {
                store.add(.text("Sample clipboard item \(index)"))
            }
            /* One of each media kind exercises the thumbnail paths. */
            let sample = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
                NSColor.systemTeal.setFill()
                rect.fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 30, dy: 18)).fill()
                return true
            }
            if let tiff = sample.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?
                    .representation(using: .png, properties: [:])
            {
                store.add(.image(png))
            }
            let manifest = URL(fileURLWithPath: "Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) {
                store.add(.files([manifest]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.historyPanel?.toggle()
            }
        }

        if CommandLine.arguments.contains("--settings") {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        /* The debounced save would never fire once the process is gone. */
        store.saveNow()
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
                self?.onboardingController = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingController?.window?.makeKeyAndOrderFront(nil)
    }

    /* Launching the app again while it's already running sends "reopen" to
       the live instance. With the menu bar icon hidden this is the only way
       back into the UI, so surface Settings (which also puts the app in the
       Dock via updateActivationPolicy). */
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if AppPreferences.isMenuBarIconHidden {
            openSettings()
        }
        return false
    }

    /* An accessory app has no visible menu bar, but ⌘-key equivalents are
       still dispatched through the main menu — without one, ⌘W/⌘Q do
       nothing in the settings window. The menu also becomes visible for
       real whenever the app temporarily joins the Dock (regular policy). */
    private func setUpMainMenu() {
        let appMenu = NSMenu()
        let historyItem = NSMenuItem(
            title: "Clipboard History", action: #selector(showHistory), keyEquivalent: "c")
        historyItem.keyEquivalentModifierMask = [.command, .option]
        historyItem.target = self
        appMenu.addItem(historyItem)
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Coffer",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(
                title: "Close Window",
                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    private func updateStatusItemVisibility() {
        if AppPreferences.isMenuBarIconHidden {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        } else if statusItem == nil {
            setUpStatusItem()
        }
        updateActivationPolicy()
    }

    private var isSettingsWindowVisible: Bool {
        settingsWindowController?.window?.isVisible == true
    }

    /* Dock presence: the app normally stays invisible (accessory policy),
       but while the menu bar icon is hidden AND Settings is open there would
       be no sign the app is running — so it joins the Dock for the duration
       and leaves again when the settings window closes. */
    private func updateActivationPolicy() {
        let wantsDock = AppPreferences.isMenuBarIconHidden && isSettingsWindowVisible
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        /* Flipping the policy can drop activation; keep Settings in front. */
        if isSettingsWindowVisible {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func setUpStatusItem() {
        /* A fixed length instead of squareLength: square items are as wide
           as the menu bar is tall, which pads a ~18pt symbol with a lot of
           dead space. 20pt hugs the icon while keeping its natural size —
           the same width every Domus app uses. */
        let item = NSStatusBar.system.statusItem(withLength: 20)
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
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(updater.makeMenuItem())
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

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(updater: updater)
            if let window = settingsWindowController?.window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    /* isVisible is still true inside willClose; re-evaluate
                       (and leave the Dock) on the next runloop cycle. */
                    DispatchQueue.main.async { self?.updateActivationPolicy() }
                }
            }
        }
        /* Accessory apps don't come forward on their own — activate first or
           the window opens behind the current app. */
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
    }
}
