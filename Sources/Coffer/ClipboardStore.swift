import Foundation

/* The app's single source of truth for the history. All mutation goes
   through the pure `ClipboardHistory` model; observers (the panel) hear
   about real changes via NotificationCenter. */
final class ClipboardStore {
    static let changed = Notification.Name("Coffer.ClipboardStoreChanged")

    /* One history entry: what was copied, and the app it came from, the
       frontmost one when the copy was seen (nil when unknown: copies kept
       from before Coffer noted the app, or Coffer's own). */
    struct Entry: Equatable, Codable {
        var item: ClipboardItem
        var source: String?
    }

    private(set) var entries: [Entry] = []
    var items: [ClipboardItem] { entries.map(\.item) }

    /* nil (the test default) keeps the store fully in-memory. */
    private let persistence: HistoryPersistence?
    private var pendingSave: DispatchWorkItem?

    private var limit: Int {
        didSet {
            guard limit != oldValue else { return }
            let updated = ClipboardHistory.trimming(entries, to: limit)
            guard updated != entries else { return }
            entries = updated
            didChange()
        }
    }

    init(limit: Int = AppPreferences.historyLimit, persistence: HistoryPersistence? = nil) {
        self.limit = limit
        self.persistence = persistence
        entries = ClipboardHistory.trimming(persistence?.load() ?? [], to: limit)
        /* Follow the preference live, so lowering the cap in Settings trims
           the history right away instead of on the next copy. */
        NotificationCenter.default.addObserver(
            forName: AppPreferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.limit = AppPreferences.historyLimit
        }
    }

    /// `source` is the copying app's bundle ID. An unknown source (nil)
    /// keeps the one already noted for the item, so re-copying from
    /// Coffer itself doesn't forget where it first came from.
    func add(_ item: ClipboardItem, source: String? = nil) {
        let known = source ?? entries.first { $0.item == item }?.source
        let updated = ClipboardHistory.adding(
            Entry(item: item, source: known), to: entries, limit: limit, by: \.item)
        guard updated != entries else { return }
        entries = updated
        didChange()
    }

    func remove(_ item: ClipboardItem) {
        let updated = entries.filter { $0.item != item }
        guard updated != entries else { return }
        entries = updated
        didChange()
    }

    /// Wipes the whole history. A no-op on an empty store, so observers
    /// hear about real changes only, like `add` and `remove`.
    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        didChange()
    }

    /// Flushes any debounced save synchronously — for app termination,
    /// where the delayed write would never fire.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence?.save(entries)
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
        let snapshot = entries
        let work = DispatchWorkItem { persistence.save(snapshot) }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}
