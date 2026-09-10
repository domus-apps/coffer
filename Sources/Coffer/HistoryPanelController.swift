import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing

/* The ⌘⌥C palette: a floating, nonactivating panel listing the history
   newest-first under a sticky search field. Typing filters the list live,
   ↑/↓ move the selection, Return (or a double-click) copies it back to the
   pasteboard, Escape clears the search — or, already empty, dismisses (as
   does clicking elsewhere). A trash button beside the search field offers
   Clear History, confirmed inside the panel itself. */
final class HistoryPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate, NSSearchFieldDelegate, NSMenuDelegate
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
    private let confirmView = NSStackView()
    private let confirmLabel = NSTextField(labelWithString: "")
    private var isConfirmingClear = false
    /* What the table shows: the store filtered by the current query. The
       search field owns key focus, so the table renders every row in its
       unemphasized (gray-pill) style unless told otherwise — hence the row
       delegate below forcing the emphasized look. */
    private var filteredItems: [ClipboardItem] = []
    /* Decoded previews are cached so scrolling never re-decodes: raster
       copies keyed by their PNG bytes, file thumbnails by URL. */
    private let imagePreviews = NSCache<NSData, NSImage>()
    private let fileThumbnails = NSCache<NSURL, NSImage>()

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
        panel.onCommit = { [weak self] in self?.commit() }
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

        /* Right-click on a row: NSTableView pops this up and records the
           row in clickedRow. The delegate hookup guards against the panel's
           close-on-resign-key while the menu is up (see menuWillOpen). */
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(copyClickedRow), keyEquivalent: "")
        copyItem.target = self
        let deleteItem = NSMenuItem(
            title: "Delete", action: #selector(deleteClickedRow), keyEquivalent: "")
        deleteItem.target = self
        contextMenu.addItem(copyItem)
        contextMenu.addItem(deleteItem)
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        /* Sticky by construction: the field sits above the scroll view on
           the glass, so the list scrolls beneath it. */
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 13)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        /* Clear History: a bare trash glyph at the search field's right,
           the field's height, in the same secondary tone as the field's
           own icon. Dimmed rather than removed when there's nothing to
           clear, so the header never shifts. */
        clearButton.image = NSImage(
            systemSymbolName: "trash", accessibilityDescription: "Clear History")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.toolTip = "Clear History"
        clearButton.setAccessibilityLabel("Clear History")
        clearButton.target = self
        clearButton.action = #selector(clearHistoryClicked)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        /* The confirmation takes the list's place rather than opening an
           alert: a second window would take key status from this
           nonactivating panel and close it (see windowDidResignKey). Return
           confirms, Escape cancels — routed through the panel, so the
           default-button key equivalent below only supplies the look. */
        confirmLabel.font = .systemFont(ofSize: 13)
        confirmLabel.alignment = .center
        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelClearClicked))
        cancelButton.bezelStyle = .rounded
        let confirmButton = NSButton(
            title: "Clear", target: self, action: #selector(confirmClearClicked))
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
        content.addSubview(clearButton)
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
        grip.onProposeSize = { [weak self] size in self?.applyGlassSize(size) }
        grip.onDragEnded = { [weak self] in self?.saveGlassSize() }

        /* The root must already have its final size when the autoresizing
           subviews are added: contentView assignment resizes it to the
           window, and springs added while it was zero-sized would misread
           that first resize as a (huge) delta to distribute. */
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        let hairline = HairlineBorderView(frame: glassFrame, cornerRadius: Self.cornerRadius)
        for view in [shadow, glass, hairline, grip] {
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        panel.contentView = root

        scrollView.stickyHeaderInset = Self.searchAreaHeight
        scrollView.headerFadeTop = Self.searchFieldBottom
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(
                equalTo: clearButton.leadingAnchor, constant: -6),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 28),
            clearButton.heightAnchor.constraint(equalToConstant: 28),
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
    }

    /* Matches the corner rounding of Tahoe's context menus. */
    private static let cornerRadius: CGFloat = 18
    /* The sticky search strip: 10pt top padding + 28pt field + 6pt gap to
       the first row at rest. The list scrolls underneath it (see
       stickyHeaderInset on FadingScrollView). */
    private static let searchAreaHeight: CGFloat = 44
    /* The field's bottom edge (10pt top padding + 28pt field): where rows
       must be fully hidden, and where the dissolve ramp hangs from. */
    private static let searchFieldBottom: CGFloat = 38
    /* The visible glass card; the window is larger by shadowMargin on every
       side so the in-window shadow has room to render. The card is
       resizable by its right/bottom edges (see ResizeGripView) and the
       chosen size persists across launches. */
    private static let defaultGlassSize = NSSize(width: 360, height: 320)
    private static let minGlassSize = NSSize(width: 240, height: 160)
    private static let shadowMargin: CGFloat = 40
    private static let glassWidthKey = "panel.glassWidth"
    private static let glassHeightKey = "panel.glassHeight"

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

    /* Live resize from the grip: the card's top-left corner stays put (the
       panel opens anchored there, at the cursor), so growth goes right and
       down like a context menu submenu would. */
    private func applyGlassSize(_ proposed: NSSize) {
        let clamped = NSSize(
            width: max(proposed.width, Self.minGlassSize.width),
            height: max(proposed.height, Self.minGlassSize.height))
        var frame = panel.frame
        let height = clamped.height + Self.shadowMargin * 2
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: clamped.width + Self.shadowMargin * 2, height: height)
        panel.setFrame(frame, display: true)
    }

    private func saveGlassSize() {
        UserDefaults.standard.set(glassSize.width, forKey: Self.glassWidthKey)
        UserDefaults.standard.set(glassSize.height, forKey: Self.glassHeightKey)
    }

    private func show() {
        /* Each open starts fresh, like a menu: no leftover query, no
           pending confirmation. */
        endClearConfirmation()
        searchField.stringValue = ""
        refilter()
        tableView.sizeLastColumnToFit()
        position()
        /* Nonactivating: the panel takes key focus for its own keyboard
           handling while the frontmost app stays active underneath. Focus
           lands on the search field so typing filters immediately; the
           list is driven from the panel's key interception instead. */
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
        filteredItems = ClipboardHistory.filtering(store.items, with: searchField.stringValue)
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

    /* Return answers the confirmation while it's up; otherwise it copies. */
    private func commit() {
        if isConfirmingClear {
            performClear()
        } else {
            copySelection()
        }
    }

    /* Escape backs out one level at a time: the confirmation, then the
       query, then the panel. */
    private func cancel() {
        if isConfirmingClear {
            endClearConfirmation()
        } else if searchField.stringValue.isEmpty {
            panel.close()
        } else {
            searchField.stringValue = ""
            refilter()
        }
    }

    /* Context-menu-style placement (à la Maccy): the glass card opens with
       its top-left corner at the mouse cursor, nudged back onto the screen
       when the cursor sits near an edge. The window itself extends
       shadowMargin past the card on every side. */
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = glassSize
        var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        panel.setFrameOrigin(
            NSPoint(x: origin.x - Self.shadowMargin, y: origin.y - Self.shadowMargin))
    }

    private func copySelection() {
        copyItem(at: tableView.selectedRow)
    }

    private func copyItem(at row: Int) {
        guard row >= 0, row < filteredItems.count else { return }
        let item = filteredItems[row]
        panel.close()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .image(let data):
            pasteboard.setData(data, forType: .png)
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
        /* The watcher sees this write and promotes the item to the front —
           exactly the re-copy behavior the history model already defines. */
    }

    // MARK: - Row context menu

    @objc private func copyClickedRow() {
        copyItem(at: tableView.clickedRow)
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
        panel.makeFirstResponder(nil)
        panel.capturesAllKeys = true
        updateConfirmLabel()
        for view in [scrollView, blurStrip, searchField, clearButton] as [NSView] {
            view.isHidden = true
        }
        updateEmptyState()
        confirmView.isHidden = false
    }

    private func endClearConfirmation() {
        guard isConfirmingClear else { return }
        isConfirmingClear = false
        confirmView.isHidden = true
        for view in [scrollView, blurStrip, searchField, clearButton] as [NSView] {
            view.isHidden = false
        }
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
            count == 1 ? "Clear the only item?" : "Clear all \(count) items?"
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

    /* The placeholder and the trash button both follow the store: nothing
       to show and nothing to clear when it's empty. */
    private func updateEmptyState() {
        emptyLabel.isHidden = !filteredItems.isEmpty || isConfirmingClear
        emptyLabel.stringValue = store.items.isEmpty ? "Nothing copied yet" : "No Results"
        clearButton.isEnabled = !store.items.isEmpty
    }

    @objc private func rowDoubleClicked() {
        copySelection()
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

    /* Key focus lives on the search field, so the table would render its
       selection in the inactive gray style; force the emphasized (accent
       color) look the palette should always have. */
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
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
            let cell = mediaCell(in: tableView)
            cell.representedItem = filteredItems[row]
            cell.textField?.stringValue = Self.filesLabel(for: urls)
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
    private func textCell(in tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("TextCell")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? NSTableCellView
        {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /* Image and file rows: a rounded thumbnail ahead of the label. */
    private func mediaCell(in tableView: NSTableView) -> MediaCellView {
        let identifier = NSUserInterfaceItemIdentifier("MediaCell")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? MediaCellView
        {
            reused.imageView?.image = nil
            return reused
        }
        let cell = MediaCellView()
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
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 22),
            thumbnail.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func imagePreview(for data: Data) -> NSImage? {
        if let cached = imagePreviews.object(forKey: data as NSData) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        imagePreviews.setObject(image, forKey: data as NSData)
        return image
    }

    private static func imageLabel(for preview: NSImage?) -> String {
        guard let rep = preview?.representations.first as? NSBitmapImageRep else {
            return "Image"
        }
        return "Image \(rep.pixelsWide)\u{2009}×\u{2009}\(rep.pixelsHigh)"
    }

    private static func filesLabel(for urls: [URL]) -> String {
        guard let first = urls.first else { return "Files" }
        return urls.count == 1
            ? first.lastPathComponent
            : "\(first.lastPathComponent) +\(urls.count - 1)"
    }

    /* The Finder icon shows instantly; QuickLook's real preview (an image's
       pixels, a video's poster frame, a PDF's first page) replaces it when
       it arrives — unless the cell was reused for another item meanwhile. */
    private func loadFileThumbnail(for url: URL, into cell: MediaCellView) {
        if let cached = fileThumbnails.object(forKey: url as NSURL) {
            cell.imageView?.image = cached
            return
        }
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        let expected = cell.representedItem
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 22, height: 22),
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

    // MARK: - NSWindowDelegate

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

/* Invisible resize handles along the card's right and bottom edges. The
   window's own edges sit shadowMargin outside the visible card, so the
   system's borderless-resize border would be floating in transparent
   space — hence manual tracking on the card boundary itself. The top-left
   stays anchored (that's where the panel opens, at the cursor), so only
   right/bottom/corner resize. */
private final class ResizeGripView: NSView {
    /* Narrow enough to leave most of the overlay scroller, which lives in
       the same right-edge strip, clickable. */
    private static let band: CGFloat = 6
    /* The diagonal zone at the bottom-right corner, where both axes resize
       at once. Much larger than the bands' 6×6 overlap: that square is too
       small to aim at, and half of it lies outside the rounded corner. */
    private static let cornerZone: CGFloat = 18

    private func isInCorner(_ point: NSPoint) -> Bool {
        point.x >= bounds.maxX - Self.cornerZone && point.y <= Self.cornerZone
    }

    var onProposeSize: ((NSSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var startMouse = NSPoint.zero
    private var startSize = NSSize.zero
    private var resizesRight = false
    private var resizesDown = false

    /* Only the edge bands are interactive; everything else falls through
       to the list below. */
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let inBand =
            isInCorner(local) || local.x >= bounds.maxX - Self.band
            || local.y <= Self.band
        return inBand ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(
            NSRect(
                x: bounds.maxX - Self.band, y: Self.cornerZone,
                width: Self.band, height: bounds.height - Self.cornerZone),
            cursor: .resizeLeftRight)
        addCursorRect(
            NSRect(x: 0, y: 0, width: bounds.width - Self.cornerZone, height: Self.band),
            cursor: .resizeUpDown)
        addCursorRect(
            NSRect(
                x: bounds.maxX - Self.cornerZone, y: 0,
                width: Self.cornerZone, height: Self.cornerZone),
            cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let corner = isInCorner(local)
        resizesRight = corner || local.x >= bounds.maxX - Self.band
        resizesDown = corner || local.y <= Self.band
        /* Screen coordinates, not window-local: the window itself moves and
           resizes during the drag, which would shift the local frame of
           reference mid-gesture. */
        startMouse = NSEvent.mouseLocation
        startSize = bounds.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard resizesRight || resizesDown else { return }
        let mouse = NSEvent.mouseLocation
        onProposeSize?(
            NSSize(
                width: startSize.width + (resizesRight ? mouse.x - startMouse.x : 0),
                height: startSize.height + (resizesDown ? startMouse.y - mouse.y : 0)))
    }

    override func mouseUp(with event: NSEvent) {
        if resizesRight || resizesDown {
            onDragEnded?()
        }
        resizesRight = false
        resizesDown = false
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

    /* Keep the rings glued to the bounds through live resizes. */
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outerRing.frame = bounds
        innerRing.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        CATransaction.commit()
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

/* A nonactivating panel that can take keyboard focus, intercepting Return,
   Escape and ↑/↓ before the responder chain: key focus lives in the search
   field's editor, which would otherwise consume all four (caret movement,
   completion, insertion) instead of driving the list. */
private final class KeyCapturePanel: NSPanel {
    var onCommit: (() -> Void)?
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
                onCommit?()
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

/* Cell for image and file rows; remembers what it currently shows so the
   async QuickLook thumbnail can tell whether the cell was reused for a
   different item while it rendered. */
private final class MediaCellView: NSTableCellView {
    var representedItem: ClipboardItem?
}

/* Selection pills stay in the accent color even though the table is never
   first responder (see rowViewForRow). */
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
