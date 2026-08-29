import Foundation

/* The app's single source of truth for the history. All mutation goes
   through the pure `ClipboardHistory` model; observers (the panel) hear
   about real changes via NotificationCenter. */
final class ClipboardStore {
    static let changed = Notification.Name("Coffer.ClipboardStoreChanged")

    private(set) var items: [ClipboardItem] = []

    /* nil (the test default) keeps the store fully in-memory. */
    private let persistence: HistoryPersistence?
    private var pendingSave: DispatchWorkItem?

    private var limit: Int {
        didSet {
            guard limit != oldValue else { return }
            let updated = ClipboardHistory.trimming(items, to: limit)
            guard updated != items else { return }
            items = updated
            didChange()
        }
    }

    init(limit: Int = AppPreferences.historyLimit, persistence: HistoryPersistence? = nil) {
        self.limit = limit
        self.persistence = persistence
        items = ClipboardHistory.trimming(persistence?.load() ?? [], to: limit)
        /* Follow the preference live, so lowering the cap in Settings trims
           the history right away instead of on the next copy. */
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.limit = AppPreferences.historyLimit
        }
    }

    func add(_ item: ClipboardItem) {
        let updated = ClipboardHistory.adding(item, to: items, limit: limit)
        guard updated != items else { return }
        items = updated
        didChange()
    }

    func remove(_ item: ClipboardItem) {
        let updated = items.filter { $0 != item }
        guard updated != items else { return }
        items = updated
        didChange()
    }

    /// Flushes any debounced save synchronously — for app termination,
    /// where the delayed write would never fire.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence?.save(items)
    }

    private func didChange() {
        NotificationCenter.default.post(name: Self.changed, object: self)
        scheduleSave()
    }

    /* Copies arrive in bursts (and image histories are megabytes), so the
       write is debounced and runs off the main thread on a snapshot. */
    private func scheduleSave() {
        guard let persistence else { return }
        pendingSave?.cancel()
        let snapshot = items
        let work = DispatchWorkItem { persistence.save(snapshot) }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}
