import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing

/* The ⌘⌥C palette: a floating, nonactivating panel listing the history
   newest-first under a sticky search field. Typing filters the list live,
   ↑/↓ move the selection, Return (or a double-click) copies it back to the
   pasteboard (⌥Return: a file row's path instead), Escape clears the search — or, already empty, dismisses (as does
   clicking elsewhere). A row, or its preview, can be dragged out. A trash button beside the search field offers
   Clear History, confirmed inside the panel itself. Dragged by the strip
   above the search field, the panel is pinned there: it opens in that spot
   from then on, and a pin beside the trash unpins it, back to opening at
   the pointer. */
final class HistoryPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSMenuItemValidation
{
    private let store: ClipboardStore
    private let panel: KeyCapturePanel
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scrollView = FadingScrollView()
    private let blurStrip = ProgressiveBlurView(
        stripHeight: HistoryPanelController.searchFieldBottom)
    /* Clear History, and the confirmation that replaces the whole list
       while the question is up. */
    private let clearButton = NSButton()
    private let unpinButton = PinButton()
    /* One glass capsule for both buttons: a circle around the trash, and
       stretched leftward to take the pin in while the panel is pinned.
       Interactive (macOS 27; on 26 it stays still), so pressing either
       button swells and brightens the whole pill, as a toolbar group does.
       Glass under each button instead pressed only that button's glass. */
    private let buttonGroup = NSGlassEffectView()
    private var buttonGroupWidth: NSLayoutConstraint!
    private var isPinShown = false
    /* Set when the drag strip is grabbed; moves while it's set are the
       user's, and get remembered (see windowDidMove). */
    private var isUserDragging = false
    private let confirmView = NSStackView()
    private let confirmLabel = NSTextField(labelWithString: "")
    private var isConfirmingClear = false
    /* What the table shows: the store filtered by the current query. The
       search field owns key focus, so the table renders every row in its
       unemphasized (gray-pill) style unless told otherwise — hence the row
       delegate below forcing the emphasized look. */
    private var filteredItems: [ClipboardItem] = []
    /* The copying app of each filtered row (bundle ID, nil if unknown),
       and its icon and name, looked up once per app. */
    private var filteredSources: [String?] = []
    private var sourceApps: [String: (icon: NSImage, name: String)?] = [:]
    /* Decoded previews are cached so scrolling never re-decodes: raster
       copies keyed by their PNG bytes, file thumbnails by URL. */
    private let imagePreviews = NSCache<NSData, NSImage>()
    private let fileThumbnails = NSCache<NSURL, NSImage>()
    /* The larger look beside the card: hovering a thumbnail for
       previewDelay opens it (see updateHover). */
    private let preview = ThumbnailPreview()
    private let filePreviews = NSCache<NSURL, NSImage>()
    private var hoveredRow = -1
    private var hoverTimer: Timer?
    /* Just after a preview closes, the next thumbnail opens at once, as
       tooltips stay warm: skimming down a column of images shouldn't
       wait at every row. */
    private var previewClosedAt = Date.distantPast
    /* Opened from the row menu: kept wherever the pointer goes (it ends
       up where the menu item was, often over another row) until Escape,
       another thumbnail, a selection change, a scroll, or a new query. */
    private var menuPreviewRow: Int?
    /* Closed with Escape while the pointer rests on its thumbnail: not
       reopened until the pointer moves off it. */
    private var dismissedRow: Int?
    /* Which open request a finished file render belongs to. */
    private var previewGeneration = 0
    /* The row the preview shows, and the grace after the pointer leaves
       that row's thumbnail: time to reach the preview (to drag from it)
       before it closes. */
    private var previewRow = -1
    private var leaveTimer: Timer?
    private static let previewDelay: TimeInterval = 0.4
    private static let previewWarmth: TimeInterval = 0.4
    private static let previewLeaveGrace: TimeInterval = 0.35
    private static let fileRowHeight: CGFloat = 40
    private static let fileThumbnailSide: CGFloat = 28
    private static let sourceIconSide: CGFloat = 16

    init(store: ClipboardStore) {
        self.store = store
        let margin = Self.shadowMargin
        let size = Self.savedGlassSize()
        panel = KeyCapturePanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: size.width + margin * 2,
                height: size.height + margin * 2),
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
        /* The row extras (file paths, app icons) can change in Settings
           while the panel is up. */
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: AppPreferences.changed, object: nil)
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
           glass, and its outline steps at the rounded corners even with a
           delayed invalidateShadow. The shadow is drawn in-window instead
           (see the shadow view in configureContent), which is deterministic. */
        panel.hasShadow = false
        /* Only the drag strip moves the panel (see DragHandleView): with
           the position remembered, a stray drag on the background would
           otherwise relocate every future open. */
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        /* Open on whatever Space (incl. full-screen apps) the user is on. */
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCommit = { [weak self] flags in self?.commit(with: flags) }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
    }

    private func configureContent() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        /* Track the table's width through panel resizes; sizeLastColumnToFit
           at show time only covers the initial layout. */
        column.resizingMask = .autoresizingMask
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
        /* Rows drag out as what they hold (see ItemDrag); copy only, so a
           drop into a Finder folder never moves the original file. */
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        /* Right-click on a row: NSTableView pops this up and records the
           row in clickedRow. The delegate hookup guards against the panel's
           close-on-resign-key while the menu is up (see menuWillOpen). */
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        /* The Return shortcuts shown beside the two copies, for discovery;
           the keys themselves are handled by the panel (see commit). */
        let copyItem = NSMenuItem(
            title: L("Copy"), action: #selector(copyClickedRow), keyEquivalent: "\r")
        copyItem.keyEquivalentModifierMask = []
        copyItem.target = self
        let deleteItem = NSMenuItem(
            title: L("Delete"), action: #selector(deleteClickedRow), keyEquivalent: "")
        deleteItem.target = self
        let copyPathItem = NSMenuItem(
            title: L("Copy Path"), action: #selector(copyPathClickedRow), keyEquivalent: "\r")
        copyPathItem.keyEquivalentModifierMask = [.option]
        copyPathItem.target = self
        let previewItem = NSMenuItem(
            title: L("Preview"), action: #selector(previewClickedRow), keyEquivalent: "")
        previewItem.target = self
        contextMenu.addItem(copyItem)
        contextMenu.addItem(copyPathItem)
        contextMenu.addItem(previewItem)
        contextMenu.addItem(deleteItem)
        tableView.menu = contextMenu

        /* Always active: the panel never makes Coffer the active app. */
        tableView.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))

        /* The preview lives in a window of its own, so the pointer's
           arrival there (to drag the image out) comes from the popover. */
        preview.onPointerInsideChange = { [weak self] inside in
            guard let self else { return }
            if inside {
                self.leaveTimer?.invalidate()
            } else if self.hoveredRow < 0 {
                self.scheduleLeaveCheck()
            }
        }
        preview.onDragEnded = { [weak self] operation in
            guard let self else { return }
            if operation.isEmpty {
                self.scheduleLeaveCheck()
            } else {
                self.panel.close()
            }
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        /* Rows slide under a still pointer when the list scrolls. */
        NotificationCenter.default.addObserver(
            self, selector: #selector(listScrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        /* Sticky by construction: the field sits above the scroll view on
           the glass, so the list scrolls beneath it. */
        searchField.placeholderString = L("Search")
        searchField.font = .systemFont(ofSize: 13)
        searchField.focusRingType = .none
        searchField.delegate = self
        /* Large: the field's bezel is drawn at its intrinsic height
           whatever its frame, 24pt at regular size, which left it shorter
           than the 28pt button capsule beside it. */
        searchField.controlSize = .large
        searchField.translatesAutoresizingMaskIntoConstraints = false

        /* Clear History: the trash at the capsule's right end. Dimmed
           rather than removed when there's nothing to clear, so the header
           never shifts. */
        clearButton.image = NSImage(
            systemSymbolName: "trash", accessibilityDescription: L("Clear History"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.contentTintColor = .labelColor
        clearButton.toolTip = L("Clear History")
        clearButton.setAccessibilityLabel(L("Clear History"))
        clearButton.target = self
        clearButton.action = #selector(clearHistoryClicked)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        /* Unpin: left of the trash in the same capsule, shown only while
           the panel is pinned to a dragged-to spot. The pin says why
           it's there; under the pointer it turns into what a click does. */
        let pinSymbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        unpinButton.pinImage = NSImage(
            systemSymbolName: "pin.fill", accessibilityDescription: L("Unpin"))?
            .withSymbolConfiguration(pinSymbol)
        unpinButton.unpinImage = NSImage(
            systemSymbolName: "pin.slash.fill", accessibilityDescription: L("Unpin"))?
            .withSymbolConfiguration(pinSymbol)
        unpinButton.imagePosition = .imageOnly
        unpinButton.isBordered = false
        unpinButton.contentTintColor = .labelColor
        unpinButton.toolTip = L("Unpin")
        unpinButton.setAccessibilityLabel(L("Unpin"))
        unpinButton.target = self
        unpinButton.action = #selector(unpinClicked)
        unpinButton.translatesAutoresizingMaskIntoConstraints = false

        /* The confirmation takes the list's place rather than opening an
           alert: a second window would take key status from this
           nonactivating panel and close it (see windowDidResignKey). Return
           confirms, Escape cancels — routed through the panel, so the
           default-button key equivalent below only supplies the look. */
        confirmLabel.font = .systemFont(ofSize: 13)
        confirmLabel.alignment = .center
        let cancelButton = NSButton(
            title: L("Cancel"), target: self, action: #selector(cancelClearClicked))
        cancelButton.bezelStyle = .rounded
        let confirmButton = NSButton(
            title: L("Clear"), target: self, action: #selector(confirmClearClicked))
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.hasDestructiveAction = true
        let confirmButtons = NSStackView(views: [cancelButton, confirmButton])
        confirmButtons.orientation = .horizontal
        confirmButtons.spacing = 8
        confirmView.orientation = .vertical
        confirmView.alignment = .centerX
        confirmView.spacing = 12
        confirmView.addView(confirmLabel, in: .center)
        confirmView.addView(confirmButtons, in: .center)
        confirmView.isHidden = true
        confirmView.translatesAutoresizingMaskIntoConstraints = false

        /* Real Liquid Glass — the same material context menus get on
           macOS 26. The content view is clipped to the glass shape so the
           scrolling list never pokes past the rounded corners. */
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        /* Z-order, bottom-up: the list runs the full card height, the blur
           strip sits over it (so rows blur as they slide under), and the
           search field draws crisp on top of both. */
        blurStrip.translatesAutoresizingMaskIntoConstraints = false
        scrollView.onHeaderIntrusion = { [weak blurStrip] strength in
            blurStrip?.strength = strength
        }
        content.addSubview(scrollView)
        content.addSubview(blurStrip)
        content.addSubview(searchField)
        content.addSubview(emptyLabel)
        let groupContent = NSView()
        groupContent.addSubview(unpinButton)
        groupContent.addSubview(clearButton)
        buttonGroup.contentView = groupContent
        buttonGroup.cornerRadius = Self.buttonSize / 2
        if #available(macOS 27.0, *) { buttonGroup.effectIsInteractive = true }
        buttonGroup.translatesAutoresizingMaskIntoConstraints = false
        unpinButton.isHidden = true
        unpinButton.alphaValue = 0
        content.addSubview(buttonGroup)
        content.addSubview(confirmView)

        /* The glass sits inset in a transparent margin; a content-less layer
           with an explicit rounded shadowPath supplies the menu shadow.
           Plain frames plus autoresizing masks: the margins are constant, so
           width/height springs keep every layer glued to the card through
           live resizes without Auto Layout. */
        let glassFrame = NSRect(
            origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin),
            size: glassSize)

        let shadow = MenuShadowView(frame: glassFrame, cornerRadius: Self.cornerRadius)

        let glass = NSGlassEffectView(frame: glassFrame)
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = content

        let grip = ResizeGripView(frame: glassFrame)
        grip.minSize = Self.minGlassSize
        grip.cornerRadius = Self.cornerRadius
        grip.onProposeFrame = { [weak self] frame in self?.applyGlassFrame(frame) }
        grip.onDragEnded = { [weak self] in self?.saveGlassSize() }

        /* The root must already have its final size when the autoresizing
           subviews are added: contentView assignment resizes it to the
           window, and springs added while it was zero-sized would misread
           that first resize as a (huge) delta to distribute. */
        let root = PanelRootView(frame: NSRect(origin: .zero, size: panel.frame.size))
        let hairline = HairlineBorderView(frame: glassFrame, cornerRadius: Self.cornerRadius)
        for view in [shadow, glass, hairline] {
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        /* The strip above the search field, below the top resize band:
           pinned to the card's top edge through resizes. Under the grip, so
           the corner resize zones win where they overlap it. */
        let handle = DragHandleView(
            frame: NSRect(
                x: glassFrame.minX,
                y: glassFrame.maxY - Self.searchFieldTop,
                width: glassFrame.width,
                height: Self.searchFieldTop - ResizeGripView.topBand))
        handle.autoresizingMask = [.width, .minYMargin]
        handle.onDragBegan = { [weak self] in self?.isUserDragging = true }
        root.addSubview(handle)
        grip.autoresizingMask = [.width, .height]
        root.addSubview(grip)
        /* Topmost, so its rect wins over the bands' while a drag runs. */
        let dragCursor = DragCursorView(frame: root.bounds)
        dragCursor.autoresizingMask = [.width, .height]
        root.addSubview(dragCursor)
        grip.dragCursorView = dragCursor
        root.dragCursorView = dragCursor
        panel.contentView = root

        scrollView.stickyHeaderInset = Self.searchAreaHeight
        scrollView.headerFadeTop = Self.searchFieldBottom
        buttonGroupWidth = buttonGroup.widthAnchor.constraint(equalToConstant: Self.buttonSize)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(
                equalTo: content.topAnchor, constant: Self.searchFieldTop),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(
                equalTo: buttonGroup.leadingAnchor, constant: -6),
            searchField.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            buttonGroup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            buttonGroup.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            buttonGroup.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            buttonGroupWidth,
            clearButton.trailingAnchor.constraint(equalTo: groupContent.trailingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: groupContent.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            clearButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            unpinButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor),
            unpinButton.centerYAnchor.constraint(equalTo: groupContent.centerYAnchor),
            unpinButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            unpinButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            blurStrip.topAnchor.constraint(equalTo: content.topAnchor),
            blurStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blurStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blurStrip.heightAnchor.constraint(
                equalToConstant: Self.searchFieldBottom + FadingScrollView.headerFadeHeight),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            /* Full height: the list must reach the card's bottom edge so the
               fade dissolves into it, instead of cropping against an inset
               boundary floating above it. The 6pt rest gap lives in the
               scroll view's bottom content inset instead. */
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            confirmView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            confirmView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        updateEmptyState()
        updatePinButton()
    }

    /* Matches the corner rounding of Tahoe's context menus. */
    private static let cornerRadius: CGFloat = 18
    /* The sticky search strip: 10pt top padding + 28pt field + 6pt gap to
       the first row at rest. The list scrolls underneath it (see
       stickyHeaderInset on FadingScrollView). */
    private static let searchAreaHeight: CGFloat = 44
    /* The padding above the search field, which doubles as the drag strip
       (less the top resize band). */
    private static let searchFieldTop: CGFloat = 10
    /* The search field's height, and each button's square in the capsule. */
    private static let buttonSize: CGFloat = 28
    /* The field's bottom edge (10pt top padding + 28pt field): where rows
       must be fully hidden, and where the dissolve ramp hangs from. */
    private static let searchFieldBottom: CGFloat = 38
    /* The visible glass card; the window is larger by shadowMargin on every
       side so the in-window shadow has room to render. The card is
       resizable by any edge or corner (see ResizeGripView) and the chosen
       size persists across launches. */
    private static let defaultGlassSize = NSSize(width: 360, height: 320)
    private static let minGlassSize = NSSize(width: 240, height: 160)
    private static let shadowMargin: CGFloat = 40
    private static let glassWidthKey = "panel.glassWidth"
    private static let glassHeightKey = "panel.glassHeight"
    /* The card's top-left corner in screen coordinates, once dragged. */
    private static let glassLeftKey = "panel.glassLeft"
    private static let glassTopKey = "panel.glassTop"

    private var savedGlassTopLeft: NSPoint? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: Self.glassLeftKey) != nil,
                defaults.object(forKey: Self.glassTopKey) != nil
            else { return nil }
            return NSPoint(
                x: defaults.double(forKey: Self.glassLeftKey),
                y: defaults.double(forKey: Self.glassTopKey))
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(newValue.x, forKey: Self.glassLeftKey)
                defaults.set(newValue.y, forKey: Self.glassTopKey)
            } else {
                defaults.removeObject(forKey: Self.glassLeftKey)
                defaults.removeObject(forKey: Self.glassTopKey)
            }
        }
    }

    private var glassTopLeft: NSPoint {
        NSPoint(
            x: panel.frame.minX + Self.shadowMargin,
            y: panel.frame.maxY - Self.shadowMargin)
    }

    private var glassSize: NSSize {
        NSSize(
            width: panel.frame.width - Self.shadowMargin * 2,
            height: panel.frame.height - Self.shadowMargin * 2)
    }

    private static func savedGlassSize() -> NSSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: glassWidthKey)
        let height = defaults.double(forKey: glassHeightKey)
        guard width > 0, height > 0 else { return defaultGlassSize }
        return NSSize(
            width: max(width, minGlassSize.width),
            height: max(height, minGlassSize.height))
    }

    /* Live resize from the grip, which proposes the card's new screen
       frame (already held to the minimum size, opposite edges pinned). */
    private func applyGlassFrame(_ glassFrame: NSRect) {
        isUserDragging = false
        panel.setFrame(
            glassFrame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
    }

    private func saveGlassSize() {
        UserDefaults.standard.set(glassSize.width, forKey: Self.glassWidthKey)
        UserDefaults.standard.set(glassSize.height, forKey: Self.glassHeightKey)
        /* Resizing by the left or top edge moves the corner too. */
        if savedGlassTopLeft != nil {
            savedGlassTopLeft = glassTopLeft
        }
    }

    private func show() {
        /* Each open starts fresh, like a menu: no leftover query, no
           pending confirmation. */
        endClearConfirmation()
        searchField.stringValue = ""
        refilter()
        tableView.sizeLastColumnToFit()
        position()
        updatePinButton()
        /* Nonactivating: the panel takes key focus for its own keyboard
           handling while the frontmost app stays active underneath. Focus
           lands on the search field so typing filters immediately; the
           list is driven from the panel's key interception instead. */
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        /* Dev hook: COFFER_DEBUG_SCROLL=<points> opens the list
           pre-scrolled, so the scroll-edge treatments can be screenshotted
           deterministically. */
        if let raw = ProcessInfo.processInfo.environment["COFFER_DEBUG_SCROLL"],
            let offset = Double(raw)
        {
            /* Deferred: at show() time the table hasn't tiled its rows yet,
               so an immediate scroll would be clamped back to the top. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let scrollView = self.tableView.enclosingScrollView
                else { return }
                let clip = scrollView.contentView
                /* Constrained like a user scroll, so a huge offset means
                   "all the way down" instead of sailing past the document. */
                let proposed = NSRect(
                    origin: NSPoint(x: 0, y: -Self.searchAreaHeight + CGFloat(offset)),
                    size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    /* Re-derives the visible rows from the store and the query. Selection
       lands on `row` clamped into the new list — 0 (the newest match) for
       fresh opens and query changes, the previous row for store updates. */
    private func refilter(selectingRow row: Int = 0) {
        hidePreview()
        let entries = ClipboardHistory.filtering(
            store.entries, with: searchField.stringValue, item: \.item)
        filteredItems = entries.map(\.item)
        filteredSources = entries.map(\.source)
        tableView.reloadData()
        updateEmptyState()
        guard !filteredItems.isEmpty else { return }
        let target = min(max(row, 0), filteredItems.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        scrollRowIntoView(target)
    }

    /* scrollRowToVisible replacement that knows about the sticky header and
       the edge fades: to AppKit a row tucked behind the search field still
       counts as visible, so the stock method would leave it there — and a
       row aligned flush with an edge sits inside the dissolve ramp, half
       faded while it is the selection. Rows are brought in clear of both
       ramps; at the ends of the list the clip's own clamping wins, where
       the fades are off anyway. */
    private func scrollRowIntoView(_ row: Int) {
        let clip = scrollView.contentView
        let rowRect = tableView.rect(ofRow: row)
        /* Where the header ramp ends, measured from the clip's top; and the
           bottom ramp's height. */
        let topClearance = Self.searchFieldBottom + FadingScrollView.headerFadeHeight
        let bottomClearance = FadingScrollView.fadeHeight
        let offset: CGFloat
        if rowRect.minY < clip.bounds.minY + topClearance {
            offset = rowRect.minY - topClearance
        } else if rowRect.maxY > clip.bounds.maxY - bottomClearance {
            offset = rowRect.maxY - clip.bounds.height + bottomClearance
        } else {
            return
        }
        let proposed = NSRect(origin: NSPoint(x: 0, y: offset), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func controlTextDidChange(_ notification: Notification) {
        refilter()
    }

    private func moveSelection(by delta: Int) {
        guard !isConfirmingClear, !filteredItems.isEmpty else { return }
        let row = min(max(tableView.selectedRow + delta, 0), filteredItems.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowIntoView(row)
    }

    /* Return answers the confirmation while it's up; otherwise it copies
       the selected item. ⌥ takes a file row's path instead of the files
       (other rows have no path: a beep, and the panel stays). Coffer
       never pastes for you: that would mean posting keystrokes, which
       needs a permission Coffer otherwise has no use for. */
    private func commit(with flags: NSEvent.ModifierFlags) {
        if isConfirmingClear {
            performClear()
            return
        }
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        if flags.contains(.option) {
            guard case .files(let urls) = filteredItems[row] else {
                NSSound.beep()
                return
            }
            copyPaths(of: urls)
        } else {
            copyItem(at: row)
        }
    }

    /* Escape backs out one level at a time: the preview, the
       confirmation, then the query, then the panel. */
    private func cancel() {
        if preview.isVisible {
            dismissPreview()
        } else if isConfirmingClear {
            endClearConfirmation()
        } else if searchField.stringValue.isEmpty {
            panel.close()
        } else {
            searchField.stringValue = ""
            refilter()
        }
    }

    /* Context-menu-style placement (à la Maccy): the glass card opens with
       its top-left corner at the mouse cursor, or where it was dragged to
       last, nudged back onto the screen either way. A dragged-to spot on a
       display that's no longer connected falls back to the cursor (and is
       kept, for when the display returns). The window itself extends
       shadowMargin past the card on every side. */
    private func position() {
        isUserDragging = false
        let anchor: NSPoint
        let screen: NSScreen?
        if let saved = savedGlassTopLeft,
            let home = NSScreen.screens.first(where: {
                /* Nudged inside: the corner sits on the card's top edge,
                   which a frame's own maxY doesn't contain. */
                $0.frame.contains(NSPoint(x: saved.x + 1, y: saved.y - 1))
            })
        {
            anchor = saved
            screen = home
        } else {
            anchor = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        }
        guard let frame = screen?.visibleFrame else { return }
        let size = glassSize
        var origin = NSPoint(x: anchor.x, y: anchor.y - size.height)
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        panel.setFrameOrigin(
            NSPoint(x: origin.x - Self.shadowMargin, y: origin.y - Self.shadowMargin))
    }

    /* Where copies go: the pasteboard the watcher watches. */
    private static var pasteboard: NSPasteboard { PasteboardWatcher.pasteboard }

    private func copySelection() {
        copyItem(at: tableView.selectedRow)
    }

    private func copyItem(at row: Int) {
        guard row >= 0, row < filteredItems.count else { return }
        let item = filteredItems[row]
        panel.close()
        let pasteboard = Self.pasteboard
        pasteboard.clearContents()
        switch item {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .image(let data):
            pasteboard.setData(data, forType: .png)
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
        pasteboard.setData(Data(), forType: PasteboardWatcher.fromCoffer)
        /* The watcher sees this write and promotes the item to the front —
           exactly the re-copy behavior the history model already defines. */
    }

    // MARK: - Row context menu

    @objc private func copyClickedRow() {
        copyItem(at: tableView.clickedRow)
    }

    /* The files' paths as text, one per line, as Finder's Copy as
       Pathname writes them. */
    private func copyPaths(of urls: [URL]) {
        panel.close()
        let pasteboard = Self.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(
            urls.map(\.absoluteURL.path).joined(separator: "\n"), forType: .string)
        pasteboard.setData(Data(), forType: PasteboardWatcher.fromCoffer)
    }

    @objc private func copyPathClickedRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredItems.count, case .files(let urls) = filteredItems[row]
        else { return }
        copyPaths(of: urls)
    }

    @objc private func previewClickedRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredItems.count else { return }
        hoverTimer?.invalidate()
        menuPreviewRow = row
        hoveredRow = row
        showPreview(forRow: row)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let row = tableView.clickedRow
        let item = row >= 0 && row < filteredItems.count ? filteredItems[row] : nil
        switch menuItem.action {
        case #selector(previewClickedRow):
            if case .text = item { return false }
            return item != nil
        case #selector(copyPathClickedRow):
            if case .files = item { return true }
            return false
        default:
            return true
        }
    }

    /* Deleting keeps the panel open: storeChanged re-filters and moves the
       selection to the nearest remaining row. */
    @objc private func deleteClickedRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredItems.count else { return }
        store.remove(filteredItems[row])
    }

    // MARK: - Clear history

    @objc private func clearHistoryClicked() {
        beginClearConfirmation()
    }

    @objc private func cancelClearClicked() {
        endClearConfirmation()
    }

    @objc private func confirmClearClicked() {
        performClear()
    }

    /* Swap the list for the question. Focus leaves the (hidden) search
       field and the panel swallows typing, so keys can't edit the query
       behind the confirmation; Return and Escape still arrive through the
       panel's own routing. */
    private func beginClearConfirmation() {
        guard !isConfirmingClear, !store.items.isEmpty else { return }
        isConfirmingClear = true
        hidePreview()
        panel.makeFirstResponder(nil)
        panel.capturesAllKeys = true
        updateConfirmLabel()
        for view in [scrollView, blurStrip, searchField, buttonGroup] as [NSView] {
            view.isHidden = true
        }
        updateEmptyState()
        confirmView.isHidden = false
    }

    private func endClearConfirmation() {
        guard isConfirmingClear else { return }
        isConfirmingClear = false
        confirmView.isHidden = true
        for view in [scrollView, blurStrip, searchField, buttonGroup] as [NSView] {
            view.isHidden = false
        }
        updatePinButton()
        updateEmptyState()
        panel.capturesAllKeys = false
        panel.makeFirstResponder(searchField)
    }

    /* The panel stays open, like Delete: storeChanged lands on the
       "Nothing copied yet" placeholder and the trash button dimmed. */
    private func performClear() {
        endClearConfirmation()
        store.clear()
    }

    private func updateConfirmLabel() {
        let count = store.items.count
        confirmLabel.stringValue =
            count == 1 ? L("Clear the only item?") : L("Clear all %d items?", count)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isContextMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isContextMenuOpen = false
        /* The menu took key status; unless the chosen action closed the
           panel (Copy), hand focus back so typing and arrows keep working.
           Deferred: the menu item's action fires after menuDidClose. */
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.searchField)
        }
    }

    private var isContextMenuOpen = false

    @objc private func unpinClicked() {
        savedGlassTopLeft = nil
        updatePinButton()
        /* The panel stays where it is; the next open follows the cursor. */
        panel.makeFirstResponder(searchField)
    }

    /* The capsule stretches to take the pin in and shrinks back around
       the trash, the search field giving way alongside. Animated only
       while the panel is on screen: pinning happens mid-drag, unpinning on
       the pin's own click. */
    private func updatePinButton() {
        let pinned = savedGlassTopLeft != nil
        guard pinned != isPinShown else { return }
        isPinShown = pinned
        if pinned { unpinButton.isHidden = false }
        let width = Self.buttonSize * (pinned ? 2 : 1)
        guard panel.isVisible else {
            buttonGroupWidth.constant = width
            unpinButton.alphaValue = pinned ? 1 : 0
            unpinButton.isHidden = !pinned
            return
        }
        /* The constraint itself is animated, not the frames: that lays the
           header out on every frame, and the glass reshapes only on real
           layout (an implicit frame animation snapped it to the end shape
           while the buttons drifted on their own). */
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            buttonGroupWidth.animator().constant = width
            unpinButton.animator().alphaValue = pinned ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !self.isPinShown else { return }
            self.unpinButton.isHidden = true
        }
    }

    /* The placeholder and the trash button both follow the store: nothing
       to show and nothing to clear when it's empty. */
    private func updateEmptyState() {
        emptyLabel.isHidden = !filteredItems.isEmpty || isConfirmingClear
        emptyLabel.stringValue = store.items.isEmpty ? L("Nothing copied yet") : L("No Results")
        clearButton.isEnabled = !store.items.isEmpty
    }

    @objc private func rowDoubleClicked() {
        copySelection()
    }

    @objc private func preferencesChanged() {
        guard panel.isVisible else { return }
        refilter(selectingRow: tableView.selectedRow)
    }

        @objc private func storeChanged() {
        guard panel.isVisible else { return }
        refilter(selectingRow: tableView.selectedRow)
        /* A copy can land mid-confirmation: keep the count honest, and
           drop the question if there's nothing left to clear. */
        if isConfirmingClear {
            if store.items.isEmpty {
                endClearConfirmation()
            } else {
                updateConfirmLabel()
            }
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    /* A click on another row (or ↑/↓) moves on from a preview the row
       menu opened. */
    func tableViewSelectionDidChange(_ notification: Notification) {
        if menuPreviewRow != nil { hidePreview() }
    }

    /* File rows carry a second line, their folder, unless that's off in
       Settings. */
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard AppPreferences.showsFilePaths, row < filteredItems.count,
            case .files = filteredItems[row]
        else {
            return tableView.rowHeight
        }
        return Self.fileRowHeight
    }

    /* The first of the row's drag writers; the drag's start adds the rest
       (every file of a multi-file copy: a pasteboard item holds one). */
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> NSPasteboardWriting?
    {
        guard !isConfirmingClear, row < filteredItems.count else { return nil }
        return ItemDrag.writers(for: filteredItems[row]).first
    }

    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
    ) {
        hidePreview()
        /* The table asks for one writer per row and never hands its drag
           to an overridable beginDraggingSession (measured), so the other
           files join the drag pasteboard as extra items here. */
        guard let row = rowIndexes.first, row < filteredItems.count else { return }
        let rest = ItemDrag.writers(for: filteredItems[row]).dropFirst()
        if !rest.isEmpty { session.draggingPasteboard.writeObjects(Array(rest)) }
    }

    /* A drop that took the item uses it, as a copy does: the panel goes. */
    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        if !operation.isEmpty { panel.close() }
    }

    /* Key focus lives on the search field, so the table would render its
       selection in the inactive gray style; force the emphasized (accent
       color) look the palette should always have. */
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let cell = itemCell(in: tableView, row: row)
        /* No icon to show gives its width back to the text. */
        let app = AppPreferences.showsSourceIcons ? sourceApp(for: filteredSources[row]) : nil
        cell.sourceIconView?.image = app?.icon
        cell.sourceIconView?.toolTip = app?.name
        cell.sourceIconView?.isHidden = app == nil
        cell.sourceIconWidth?.constant = app == nil ? 0 : Self.sourceIconSide
        return cell
    }

    private func itemCell(in tableView: NSTableView, row: Int) -> HistoryCellView {
        switch filteredItems[row] {
        case .text(let text):
            let cell = textCell(in: tableView)
            cell.textField?.stringValue = ClipboardHistory.previewLine(for: text)
            return cell
        case .image(let data):
            let cell = mediaCell(in: tableView)
            cell.representedItem = filteredItems[row]
            let preview = imagePreview(for: data)
            cell.imageView?.image = preview
            cell.textField?.stringValue = Self.imageLabel(for: preview)
            return cell
        case .files(let urls):
            let showsPath = AppPreferences.showsFilePaths
            let cell = showsPath ? fileCell(in: tableView) : mediaCell(in: tableView)
            cell.representedItem = filteredItems[row]
            cell.textField?.stringValue = Self.filesLabel(for: urls)
            cell.detailField?.stringValue = Self.folderLabel(for: urls)
            if let url = urls.first {
                loadFileThumbnail(for: url, into: cell)
            }
            return cell
        }
    }

    /* A real cell container, not a bare text field: a bare field is
       stretched to the full row height and draws its text top-aligned, so
       it would sit visibly high inside the selection pill. The container
       centers the label vertically and pads it horizontally clear of the
       pill's rounded ends. */
    private func textCell(in tableView: NSTableView) -> HistoryCellView {
        let identifier = NSUserInterfaceItemIdentifier("TextCell")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? HistoryCellView
        {
            return reused
        }
        let cell = HistoryCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        let icon = addSourceIcon(to: cell)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: icon.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /* Image and file rows: a rounded thumbnail ahead of the label. */
    private func mediaCell(in tableView: NSTableView) -> HistoryCellView {
        let identifier = NSUserInterfaceItemIdentifier("MediaCell")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? HistoryCellView
        {
            reused.imageView?.image = nil
            return reused
        }
        let cell = HistoryCellView()
        cell.identifier = identifier
        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 3
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(thumbnail)
        cell.addSubview(label)
        cell.imageView = thumbnail
        cell.textField = label
        let icon = addSourceIcon(to: cell)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 22),
            thumbnail.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: icon.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /* File rows: a larger thumbnail beside two lines, the name and, in
       small secondary text, the folder it's in. */
    private func fileCell(in tableView: NSTableView) -> HistoryCellView {
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? HistoryCellView
        {
            reused.imageView?.image = nil
            return reused
        }
        let cell = HistoryCellView()
        cell.identifier = identifier
        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        /* Middle truncation keeps both ends of a long path: where it
           starts and the folder itself. */
        let detail = NSTextField(labelWithString: "")
        detail.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(thumbnail)
        cell.addSubview(label)
        cell.addSubview(detail)
        cell.imageView = thumbnail
        cell.textField = label
        cell.detailField = detail
        let icon = addSourceIcon(to: cell)
        let side = Self.fileThumbnailSide
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: side),
            thumbnail.heightAnchor.constraint(equalToConstant: side),
            label.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: icon.leadingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(
                lessThanOrEqualTo: icon.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
        ])
        return cell
    }

    /* The copying app's icon at the row's right end (named in its
       tooltip); hidden when the app isn't known. */
    private func addSourceIcon(to cell: HistoryCellView) -> NSImageView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.sourceIconView = icon
        let width = icon.widthAnchor.constraint(equalToConstant: Self.sourceIconSide)
        cell.sourceIconWidth = width
        NSLayoutConstraint.activate([
            icon.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            width,
            icon.heightAnchor.constraint(equalToConstant: Self.sourceIconSide),
        ])
        return icon
    }

    /* An app that's no longer installed has no icon to show: no badge,
       rather than a generic one. */
    private func sourceApp(for bundleID: String?) -> (icon: NSImage, name: String)? {
        guard let bundleID else { return nil }
        if let known = sourceApps[bundleID] { return known }
        var app: (icon: NSImage, name: String)?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            app = (
                NSWorkspace.shared.icon(forFile: url.path),
                (name as NSString).deletingPathExtension
            )
        }
        sourceApps[bundleID] = app
        return app
    }

    /* The folder of a file copy, home abbreviated to ~; for files from
       several folders, the first one's. */
    private static func folderLabel(for urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        let folder = first.absoluteURL.deletingLastPathComponent().path
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    private func imagePreview(for data: Data) -> NSImage? {
        if let cached = imagePreviews.object(forKey: data as NSData) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        imagePreviews.setObject(image, forKey: data as NSData)
        return image
    }

    private static func imageLabel(for preview: NSImage?) -> String {
        guard let rep = preview?.representations.first as? NSBitmapImageRep else {
            return L("Image")
        }
        return L("Image") + " \(rep.pixelsWide)\u{2009}×\u{2009}\(rep.pixelsHigh)"
    }

    private static func filesLabel(for urls: [URL]) -> String {
        guard let first = urls.first else { return L("Files") }
        return urls.count == 1
            ? first.lastPathComponent
            : "\(first.lastPathComponent) +\(urls.count - 1)"
    }

    /* The Finder icon shows instantly; QuickLook's real preview (an image's
       pixels, a video's poster frame, a PDF's first page) replaces it when
       it arrives — unless the cell was reused for another item meanwhile. */
    private func loadFileThumbnail(for url: URL, into cell: HistoryCellView) {
        if let cached = fileThumbnails.object(forKey: url as NSURL) {
            cell.imageView?.image = cached
            return
        }
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        let expected = cell.representedItem
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: Self.fileThumbnailSide, height: Self.fileThumbnailSide),
            scale: panel.backingScaleFactor, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak self, weak cell] representation, _ in
            guard let representation else { return }
            DispatchQueue.main.async {
                let image = representation.nsImage
                self?.fileThumbnails.setObject(image, forKey: url as NSURL)
                guard let cell, cell.representedItem == expected else { return }
                cell.imageView?.image = image
            }
        }
    }

    // MARK: - Thumbnail preview

    /* Named for Objective-C by hand: the tracking area sends mouseMoved:,
       and a non-responder's Swift method would export as
       mouseMovedWithEvent: and never hear from it. */
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        updateHover(at: event.locationInWindow)
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    /* The previewed row slides away from its preview (and from the
       pointer), so a scroll closes it; the next move re-evaluates. */
    @objc private func listScrolled() {
        hidePreview()
    }

    /* Tracks which row's thumbnail is under the pointer. Resting on one
       opens its preview after previewDelay (at once while warm); moving to
       another switches it, and leaving every thumbnail closes it. */
    private func updateHover(at windowPoint: NSPoint?) {
        let point = windowPoint.map { tableView.convert($0, from: nil) }
        let row = point.map(thumbnailRow(at:)) ?? -1
        if let sticky = menuPreviewRow {
            if row < 0 || row == sticky { return }
            menuPreviewRow = nil
        }
        if let dismissed = dismissedRow {
            if row == dismissed { return }
            dismissedRow = nil
        }
        guard row != hoveredRow else { return }
        hoverTimer?.invalidate()
        guard row >= 0 else {
            hoveredRow = -1
            if preview.isVisible {
                scheduleLeaveCheck()
            } else {
                hidePreview()
            }
            return
        }
        leaveTimer?.invalidate()
        hoveredRow = row
        if preview.isVisible || Date().timeIntervalSince(previewClosedAt) < Self.previewWarmth {
            showPreview(forRow: row)
        } else {
            hoverTimer = Timer.scheduledTimer(
                withTimeInterval: Self.previewDelay, repeats: false
            ) { [weak self] _ in
                guard let self, self.hoveredRow == row else { return }
                self.showPreview(forRow: row)
            }
        }
    }

    /* After the pointer leaves the previewed thumbnail: the preview stays
       while the pointer is in it (or dragging from it), or still on the
       previewed row (on its way across the card to a preview on the right
       side); anywhere else, it closes. */
    private func scheduleLeaveCheck() {
        leaveTimer?.invalidate()
        leaveTimer = Timer.scheduledTimer(
            withTimeInterval: Self.previewLeaveGrace, repeats: false
        ) { [weak self] _ in
            self?.checkPreviewLeave()
        }
    }

    private func checkPreviewLeave() {
        guard preview.isVisible, hoveredRow < 0, menuPreviewRow == nil else { return }
        /* The popover reports the pointer leaving it, which checks again. */
        if preview.isPointerInside || preview.isDragging { return }
        let point = tableView.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        if previewRow >= 0, tableView.row(at: point) == previewRow {
            scheduleLeaveCheck()
            return
        }
        hidePreview()
    }

    /* The row whose thumbnail (a little generously) contains the point,
       or -1: text rows have none. */
    private func thumbnailRow(at point: NSPoint) -> Int {
        let row = tableView.row(at: point)
        guard row >= 0, row < filteredItems.count, !isConfirmingClear,
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? HistoryCellView,
            let thumbnail = cell.imageView
        else { return -1 }
        let rect = thumbnail.convert(thumbnail.bounds, to: tableView).insetBy(dx: -3, dy: -3)
        return rect.contains(point) ? row : -1
    }

    private func showPreview(forRow row: Int) {
        guard row < filteredItems.count, panel.isVisible, let root = panel.contentView
        else { return }
        previewGeneration += 1
        let generation = previewGeneration
        /* The arrow lands on the row's height at the card's edge, where
           the popover leaves the card. */
        let card = root.bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        let rowRect = tableView.convert(tableView.rect(ofRow: row), to: root)
        let item = filteredItems[row]
        let present = { [weak self] (image: NSImage) in
            guard let self, generation == self.previewGeneration, self.hoveredRow == row
            else { return }
            self.previewRow = row
            self.preview.show(
                image, beside: card, rowRect: rowRect, of: root,
                makeWriters: { ItemDrag.writers(for: item) })
        }
        switch item {
        case .text:
            return
        case .image(let data):
            if let image = imagePreview(for: data) { present(image) }
        case .files(let urls):
            guard let url = urls.first else { return }
            if let cached = filePreviews.object(forKey: url as NSURL) {
                present(cached)
                return
            }
            /* QuickLook's rendering at the preview's size: an image's
               pixels, a video's poster frame, a PDF's first page, or the
               Finder icon for anything without one. */
            let side = 280.0
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: side, height: side),
                scale: panel.backingScaleFactor, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                [weak self] representation, _ in
                guard let representation else { return }
                DispatchQueue.main.async {
                    let image = representation.nsImage
                    self?.filePreviews.setObject(image, forKey: url as NSURL)
                    present(image)
                }
            }
        }
    }

    /* Escape's close: the pointer is still resting on the thumbnail, so
       that row stays quiet until the pointer leaves it, and the warmth is
       spent so the next thumbnail waits out the delay again. */
    private func dismissPreview() {
        let row = menuPreviewRow ?? (hoveredRow >= 0 ? hoveredRow : previewRow)
        hidePreview()
        dismissedRow = row
        previewClosedAt = .distantPast
    }

    /* Also forgets the hovered row, so after a reload or scroll the
       pointer's next move counts as arriving on whatever is under it. */
    private func hidePreview() {
        hoverTimer?.invalidate()
        leaveTimer?.invalidate()
        hoveredRow = -1
        previewRow = -1
        menuPreviewRow = nil
        dismissedRow = nil
        previewGeneration += 1
        guard preview.isVisible else { return }
        preview.hide()
        previewClosedAt = Date()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        hidePreview()
        preview.hideNow()
        /* Closed while the preview popover is still fading out (a second
           Escape right after the first), the window server keeps the panel
           on screen, inactive, until the fade ends (~0.2 s more, measured
           2026-10-09; ordering out first doesn't help). An alpha change
           goes through at once, so the panel vanishes when asked; show()
           restores it. */
        panel.alphaValue = 0
    }

    /* Moves after the strip is grabbed are the user's: remember each one.
       performDrag returns at once and the window server reports the drag
       here every ~100 ms, the last report sometimes after the button is up
       (measured 2026-10-09), so a move with the button up is taken as the
       drag's end: saved, then the flag cleared so a later system nudge (a
       display rearranged) doesn't count. Otherwise the next programmatic
       placement clears it. */
    func windowDidMove(_ notification: Notification) {
        guard isUserDragging else { return }
        savedGlassTopLeft = glassTopLeft
        updatePinButton()
        if NSEvent.pressedMouseButtons & 1 == 0 {
            isUserDragging = false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        /* The row context menu takes key status while it's up; that's not
           the user leaving. */
        guard !isContextMenuOpen else { return }
        /* The debug hook needs the panel to survive focus loss so it can be
           screenshotted from a script; real runs dismiss like a menu. */
        guard ProcessInfo.processInfo.environment["COFFER_DEBUG_PANEL"] != "1" else { return }
        panel.close()
    }
}

/* The in-window menu shadow (see configurePanel for why the window-server
   shadow is off). A subclass because the explicit shadowPath must track the
   view's size through live resizes. */
private final class MenuShadowView: NSView {
    private let cornerRadius: CGFloat

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        if let layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 16
            layer.shadowOffset = CGSize(width: 0, height: -8)
        }
        updateShadowPath()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil)
        CATransaction.commit()
    }
}

/* Covers the whole window, shadow margin included, with one cursor rect
   while a resize drag runs (see ResizeGripView.mouseDown); otherwise
   inert. Never hit-tested.

   The rect alone held the shape only while the card shrank. Growing, the
   pointer runs ahead of the edge into the shadow margin, and a fully
   transparent pixel belongs to the window below even mid-drag, so the
   arrow came back on every step outward (measured 2026-10-09). For the
   drag the view fills the window at alpha 1/255: invisible, but no longer
   transparent to the window server, so the pointer stays on Coffer's
   window and inside the rect. */
/* The panel's root. The band rects stay registered during a resize drag
   (dropping them counts as leaving them, and the arrow wins), but the
   window's resize keeps sliding them across the pointer. Each crossing
   sends a cursor update to whichever view is under the pointer, and it
   climbs the superview chain to AppKit's default, which sets the arrow:
   the top band did so one step in three (measured 2026-10-09). Every such
   update passes through here, so the drag's shape answers it instead. */
private final class PanelRootView: NSView {
    weak var dragCursorView: DragCursorView?

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = dragCursorView?.cursor {
            cursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }
}

/* The unpin button: a pin while it sits there, a struck-through pin while
   the pointer is over it. The tracking area is active always, as the panel
   never makes Coffer the active app. */
private final class PinButton: NSButton {
    var pinImage: NSImage? { didSet { image = pinImage } }
    var unpinImage: NSImage?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { image = unpinImage }
    override func mouseExited(with event: NSEvent) { image = pinImage }

    /* Hidden by its own click, with the pointer still over it: no exit
       follows, so the pin comes back here for the next time it shows. */
    override func viewDidHide() {
        super.viewDidHide()
        image = pinImage
    }
}

private final class DragCursorView: NSView {
    var cursor: NSCursor? {
        didSet {
            guard cursor !== oldValue else { return }
            layer?.backgroundColor =
                cursor == nil ? nil : NSColor(white: 0, alpha: 1 / 255).cgColor
            window?.invalidateCursorRects(for: self)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        guard let cursor else { return }
        addCursorRect(bounds, cursor: cursor)
    }
}

/* The drag strip above the search field. performDrag hands the gesture to
   the window server, as a title bar does; the controller notices the move
   through windowDidMove. */
private final class DragHandleView: NSView {
    var onDragBegan: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?()
        window?.performDrag(with: event)
    }
}

/* Invisible resize handles along the card's four edges and corners. The
   window's own edges sit shadowMargin outside the visible card, so the
   system's borderless-resize border would be floating in transparent
   space — hence manual tracking on the card boundary itself. Dragging an
   edge moves only that edge; the opposite one stays put. */
private final class ResizeGripView: NSView {
    /* Narrow enough to leave most of the overlay scroller, which lives in
       the same right-edge strip, clickable — and the search field and
       clear button, 10pt in from the top, untouched. */
    private static let band: CGFloat = 6
    /* Thinner on top: the rest of the padding above the search field is
       the drag strip (DragHandleView). */
    static let topBand: CGFloat = 4
    /* The diagonal zones at the corners, where both axes resize at once.
       Much larger than the bands' 6×6 overlap: that square is too small to
       aim at, and half of it lies outside the rounded corner. */
    private static let cornerZone: CGFloat = 18

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    var minSize = NSSize.zero
    /* The full-window cursor rect used while a resize drag runs. */
    weak var dragCursorView: DragCursorView?
    var onProposeFrame: ((NSRect) -> Void)?
    var onDragEnded: (() -> Void)?

    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var dragging: Edges = []

    /* Which edges a point grabs: a corner zone grabs both of its edges,
       a band one. Empty means the point belongs to the list below. */
    private func edges(at point: NSPoint) -> Edges {
        guard bounds.contains(point) else { return [] }
        let nearLeft = point.x <= Self.cornerZone
        let nearRight = point.x >= bounds.maxX - Self.cornerZone
        let nearBottom = point.y <= Self.cornerZone
        let nearTop = point.y >= bounds.maxY - Self.cornerZone
        if (nearLeft || nearRight) && (nearBottom || nearTop) {
            return [nearLeft ? .left : .right, nearBottom ? .bottom : .top]
        }
        var edges: Edges = []
        if point.x <= Self.band { edges.insert(.left) }
        if point.x >= bounds.maxX - Self.band { edges.insert(.right) }
        if point.y <= Self.band { edges.insert(.bottom) }
        if point.y >= bounds.maxY - Self.topBand { edges.insert(.top) }
        return edges
    }

    /* Only the edge bands and corners are interactive; everything else
       falls through to the list below. */
    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: convert(point, from: superview)).isEmpty ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /* The card's corner rounding, so the corner cursor zones can start
       where the glass does. */
    var cornerRadius: CGFloat = 0

    /* Cursors go through cursor rects: with Coffer never the active app,
       AppKit's cursor machinery is the only way a cursor takes. A plain
       NSCursor.set() from a move handler is ignored (measured 2026-10-09
       with a probe reading the system cursor: five mouseMoved calls on a
       corner, arrow throughout). Two things made the rects miss when the
       pointer came from outside:
       - Corners: a rect reaching into the transparent rounded corner was
         entered over a pixel that belongs to the window below, so its
         cursor never took, and the pointer was already inside it by the
         time it reached the glass. The corner rects now start where the
         arc does, so they are entered over the card.
       - Edges, now and then: the app under the transparent shadow margin
         had the pointer a moment earlier and set its own cursor after
         ours (seen 4 ms later with a Chromium browser underneath). Hence
         the re-apply below. */
    override func resetCursorRects() {
        let zone = Self.cornerZone
        let band = Self.band
        /* Where the arc meets the corner square's diagonal. */
        let arcInset = cornerRadius * (1 - 1 / 2.squareRoot())
        let corner = zone - arcInset
        let midWidth = bounds.width - zone * 2
        let midHeight = bounds.height - zone * 2
        addCursorRect(
            NSRect(x: 0, y: zone, width: band, height: midHeight), cursor: .resizeLeftRight)
        addCursorRect(
            NSRect(x: bounds.maxX - band, y: zone, width: band, height: midHeight),
            cursor: .resizeLeftRight)
        addCursorRect(
            NSRect(x: zone, y: 0, width: midWidth, height: band), cursor: .resizeUpDown)
        addCursorRect(
            NSRect(
                x: zone, y: bounds.maxY - Self.topBand, width: midWidth, height: Self.topBand),
            cursor: .resizeUpDown)
        let corners: [(NSPoint, NSCursor.FrameResizePosition)] = [
            (NSPoint(x: arcInset, y: arcInset), .bottomLeft),
            (NSPoint(x: bounds.maxX - zone, y: arcInset), .bottomRight),
            (NSPoint(x: arcInset, y: bounds.maxY - zone), .topLeft),
            (NSPoint(x: bounds.maxX - zone, y: bounds.maxY - zone), .topRight),
        ]
        for (origin, position) in corners {
            addCursorRect(
                NSRect(origin: origin, size: NSSize(width: corner, height: corner)),
                cursor: .frameResize(position: position, directions: .all))
        }
    }

    /* Re-applying the rects a few times just after the pointer reaches a
       band outlasts a late setter underneath: invalidating them makes
       AppKit set the cursor for wherever the pointer is, through the same
       path the rects use. The tracking area only notices the arrival. */
    private var isOverBand = false
    private var reapplyGeneration = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { noteBand(for: event) }
    override func mouseMoved(with event: NSEvent) { noteBand(for: event) }
    override func mouseExited(with event: NSEvent) { isOverBand = false }

    private func noteBand(for event: NSEvent) {
        let overBand = !edges(at: convert(event.locationInWindow, from: nil)).isEmpty
        defer { isOverBand = overBand }
        guard overBand, !isOverBand, dragging.isEmpty else { return }
        reapplyGeneration += 1
        let generation = reapplyGeneration
        for delay in [0.03, 0.1, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == reapplyGeneration, isOverBand,
                    dragging.isEmpty
                else { return }
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = edges(at: convert(event.locationInWindow, from: nil))
        /* Screen coordinates, not window-local: the window itself moves and
           resizes during the drag, which would shift the local frame of
           reference mid-gesture. */
        startMouse = NSEvent.mouseLocation
        startFrame = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        /* Every resize step changes the window's frame, and AppKit rebuilds
           the cursor rects for each. The edge trails the pointer by a step,
           so the rebuild found the pointer off the band and showed the
           arrow about half the time (measured 2026-10-09, 22–30 of 60
           samples per drag). Setting the cursor directly doesn't take while
           Coffer is inactive, and disabling the rects left the arrow on
           (57 of 60), so instead the whole window carries the drag's shape
           for the duration: wherever the pointer is, ahead of the edge,
           behind it, or past a card stopped at its minimum size. */
        dragCursorView?.cursor = Self.cursor(for: dragging)
    }

    private static func cursor(for edges: Edges) -> NSCursor? {
        switch edges {
        case [.left], [.right]: .resizeLeftRight
        case [.top], [.bottom]: .resizeUpDown
        case [.left, .bottom]: .frameResize(position: .bottomLeft, directions: .all)
        case [.right, .bottom]: .frameResize(position: .bottomRight, directions: .all)
        case [.left, .top]: .frameResize(position: .topLeft, directions: .all)
        case [.right, .top]: .frameResize(position: .topRight, directions: .all)
        default: nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        /* Each dragged edge follows the mouse until the card hits its
           minimum size; the edges not being dragged never move. */
        var minX = startFrame.minX
        var maxX = startFrame.maxX
        var minY = startFrame.minY
        var maxY = startFrame.maxY
        if dragging.contains(.left) { minX = min(minX + dx, maxX - minSize.width) }
        if dragging.contains(.right) { maxX = max(maxX + dx, minX + minSize.width) }
        if dragging.contains(.bottom) { minY = min(minY + dy, maxY - minSize.height) }
        if dragging.contains(.top) { maxY = max(maxY + dy, minY + minSize.height) }
        onProposeFrame?(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragging.isEmpty else { return }
        dragging = []
        onDragEnded?()
        /* Back to the band rects, applied for wherever the pointer was
           let go: still a resize shape on the band, the arrow off it. */
        dragCursorView?.cursor = nil
        window?.invalidateCursorRects(for: self)
    }
}

/* The progressive blur under the sticky search field — the blur half of a
   scroll-pocket treatment (FadingScrollView's mask supplies the dissolve).
   A private CABackdropLayer with a gaussian blur samples whatever renders
   behind it — the rows sliding under the strip, glass included — masked by
   a vertical gradient so the blur decays through the fade ramp, with its
   radius driven by how far content has actually scrolled under. Defensive:
   if the private class or filter ever vanish, the view does nothing and
   the fade alone carries the effect. */
private final class ProgressiveBlurView: NSView {
    private static let maxRadius: Double = 12
    private let stripHeight: CGFloat
    private var backdrop: CALayer?
    private let gradientMask = CAGradientLayer()

    var strength: CGFloat = 0 {
        didSet {
            guard strength != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop?.setValue(
                Double(strength) * Self.maxRadius,
                forKeyPath: "filters.blur.inputRadius")
            CATransaction.commit()
        }
    }

    init(stripHeight: CGFloat) {
        self.stripHeight = stripHeight
        super.init(frame: .zero)
        wantsLayer = true
        guard
            let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
            let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
            let blur = filterClass.perform(
                NSSelectorFromString("filterWithName:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject
        else { return }
        blur.setValue("blur", forKey: "name")
        blur.setValue(0.0, forKey: "inputRadius")

        gradientMask.startPoint = CGPoint(x: 0.5, y: 1)
        gradientMask.endPoint = CGPoint(x: 0.5, y: 0)
        gradientMask.colors = [
            NSColor.black.cgColor, NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
        ]

        let backdrop = backdropClass.init()
        backdrop.filters = [blur]
        backdrop.mask = gradientMask
        layer?.addSublayer(backdrop)
        self.backdrop = backdrop
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        guard let backdrop else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        gradientMask.frame = CGRect(origin: .zero, size: bounds.size)
        /* Full blur through the search strip, decaying to nothing across
           the dissolve ramp below it. */
        gradientMask.locations = [
            0, NSNumber(value: bounds.height > 0 ? stripHeight / bounds.height : 0), 1,
        ]
        CATransaction.commit()
    }

    /* Purely decorative: never swallow clicks meant for the list. */
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/* Soft scroll-edge fades, like the settings sidebars in the other Domus
   apps: rows dissolve over the last ~16pt at the top and bottom instead of
   cropping hard against the edge. The system's scroll-edge effect only
   exists under a title bar, which this borderless glass panel doesn't
   have — so it's a gradient layer mask instead. Each side's fade strength
   is proportional to how much content is actually scrolled past it, so the
   fade grows in smoothly with the first points of scrolling and the list
   stays entirely un-faded while everything fits. */
private final class FadingScrollView: NSScrollView {
    static let fadeHeight: CGFloat = 16
    /* The dissolve ramp hanging from the header fade top — short, hugging
       the search field the way the System Settings sidebar fade hugs its
       search field. */
    static let headerFadeHeight: CGFloat = 14
    /* How much scrolling fully engages the header fade: short, so a row
       tip never lingers half-visible behind the search field. */
    private static let headerEngageDistance: CGFloat = 8
    /* How much of a row still shows through at the search field's bottom
       edge when the fade is fully engaged — the glassy show-through; the
       blur strip smears it so it reads as frosting, not clutter. */
    private static let headerResidualAlpha: CGFloat = 0.45
    /* Breathing room under the last row at rest. A content inset, not a
       frame inset: the list itself must reach the card's bottom edge so
       the bottom fade dissolves into it instead of cropping above it. */
    private static let bottomRestInset: CGFloat = 6
    private let fadeMask = CAGradientLayer()

    /* Reports the header fade strength (0–1) as it changes, for the blur
       layer that accompanies the dissolve. */
    var onHeaderIntrusion: ((CGFloat) -> Void)?

    /* Height reserved for a sticky header laid over the scroll view's top:
       the content starts below it at rest (via the content inset) but
       scrolls underneath it. */
    var stickyHeaderInset: CGFloat = 0 {
        didSet {
            automaticallyAdjustsContentInsets = false
            contentInsets = NSEdgeInsets(
                top: stickyHeaderInset, left: 0, bottom: Self.bottomRestInset, right: 0)
            updateFades()
        }
    }

    /* Where rows stop being fully hidden and the dissolve ramp begins —
       the search field's bottom edge, which can sit above the header
       inset (the inset keeps a rest gap between field and first row that
       the fade shouldn't extend into). Defaults to the full inset. */
    var headerFadeTop: CGFloat? {
        didSet { updateFades() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        /* NSScrollView is a flipped view and its backing layer inherits
           that geometry: unit-space y = 0 is the TOP edge here. */
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.mask = fadeMask
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        updateFades()
    }

    @objc private func scrolled() {
        updateFades()
    }

    private func updateFades() {
        let height = bounds.height
        guard height > 0 else { return }

        /* The table view is flipped, so the clip origin is the offset from
           the top; what remains below is the document height past the
           visible bottom edge. */
        let visible = contentView.bounds
        let documentHeight = documentView?.frame.height ?? 0
        func strength(_ overflow: CGFloat, over span: CGFloat) -> CGFloat {
            min(max(overflow / span, 0), 1)
        }
        /* At rest the clip origin sits at -stickyHeaderInset. */
        let top = strength(
            visible.minY + stickyHeaderInset, over: Self.headerEngageDistance)
        let bottom = strength(documentHeight - visible.maxY, over: Self.fadeHeight)
        onHeaderIntrusion?(top)

        /* The scroll-pocket treatment: rows sliding under the search field
           keep a faint residual visibility — the progressive blur strip
           turns that residue into the frosted show-through of glass — rising
           from nothing at the card's top edge, then a short linear ramp
           recovers full visibility right below the field (the System
           Settings sidebar fade). The bottom edge keeps its plain fade. */
        let topAlpha = 1 - top
        let fieldAlpha = 1 - top * (1 - Self.headerResidualAlpha)
        let fadeTop = headerFadeTop ?? stickyHeaderInset
        let headerStop = fadeTop / height
        let topFadeStop = (fadeTop + Self.headerFadeHeight) / height

        /* Tracks live scrolling: implicit animations would make the mask
           trail behind the rows. Re-attach the mask each pass — AppKit owns
           a layer-backed view's layer and may hand out a fresh one after
           the view joins a window. */
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer?.mask !== fadeMask {
            layer?.mask = fadeMask
        }
        fadeMask.frame = CGRect(origin: .zero, size: bounds.size)
        fadeMask.colors = [
            NSColor.black.withAlphaComponent(topAlpha).cgColor,
            NSColor.black.withAlphaComponent(fieldAlpha).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(1 - bottom).cgColor,
        ]
        fadeMask.locations = [
            0, NSNumber(value: headerStop), NSNumber(value: topFadeStop),
            NSNumber(value: 1 - Self.fadeHeight / height), 1,
        ]
        CATransaction.commit()
    }
}

/* The rim NSPopover draws (measured against the thumbnail preview's): one
   0.5pt bright line just inside the edge. The dark outer line comes from
   the glass itself, so no outline is added here; a second, darker ring
   read heavier than any system popover. The window-server shadow, which
   would give the native outer edge, is off (see the panel setup): its
   snapshot of the rounded glass came out stepped at the corners.
   Colors re-resolve on appearance changes via updateLayer. */
private final class HairlineBorderView: NSView {
    private let ring = CALayer()

    init(frame: NSRect, cornerRadius: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        ring.frame = bounds
        ring.cornerRadius = cornerRadius
        ring.cornerCurve = .continuous
        ring.borderWidth = 0.5
        layer?.addSublayer(ring)
    }

    /* Keep the ring glued to the bounds through live resizes. */
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        CATransaction.commit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ring.borderColor = NSColor.white.withAlphaComponent(isDark ? 0.12 : 0.22).cgColor
    }

    /* Purely decorative: never swallow clicks meant for the list. */
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/* A nonactivating panel that can take keyboard focus, intercepting Return,
   Escape and ↑/↓ before the responder chain: key focus lives in the search
   field's editor, which would otherwise consume all four (caret movement,
   completion, insertion) instead of driving the list. */
private final class KeyCapturePanel: NSPanel {
    var onCommit: ((NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    /* While a confirmation is up, plain typing is dropped instead of
       reaching the hidden search field; the routed keys above still work. */
    var capturesAllKeys = false

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                onCommit?(event.modifierFlags)
                return
            case kVK_Escape:
                onCancel?()
                return
            case kVK_UpArrow:
                onMoveSelection?(-1)
                return
            case kVK_DownArrow:
                onMoveSelection?(1)
                return
            default:
                if capturesAllKeys { return }
            }
        }
        super.sendEvent(event)
    }
}

/* Cell for every row, with the copying app's icon at its right end.
   Image and file rows remember what they currently show so the async
   QuickLook thumbnail can tell whether the cell was reused for a
   different item while it rendered. */
private final class HistoryCellView: NSTableCellView {
    var representedItem: ClipboardItem?
    weak var sourceIconView: NSImageView?
    /* Zero while there's no icon, so the text can run to the edge. */
    var sourceIconWidth: NSLayoutConstraint?
    /* The file row's folder line. The table hands the selection's style
       to textField only, so this one follows it here. */
    weak var detailField: NSTextField?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            detailField?.textColor =
                backgroundStyle == .emphasized
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
                : .secondaryLabelColor
        }
    }
}

/* Selection pills stay in the accent color even though the table is never
   first responder (see rowViewForRow). */
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
