import Foundation

/* The app's single source of truth for the history. All mutation goes
   through the pure `ClipboardHistory` model; observers (the panel) hear
   about real changes via NotificationCenter. */
final class ClipboardStore {
    static let changed = Notification.Name("Coffer.ClipboardStoreChanged")

    private(set) var items: [ClipboardItem] = []

    private var limit: Int {
        didSet {
            guard limit != oldValue else { return }
            let updated = ClipboardHistory.trimming(items, to: limit)
            guard updated != items else { return }
            items = updated
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    init(limit: Int = AppPreferences.historyLimit) {
        self.limit = limit
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
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func remove(_ item: ClipboardItem) {
        let updated = items.filter { $0 != item }
        guard updated != items else { return }
        items = updated
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
