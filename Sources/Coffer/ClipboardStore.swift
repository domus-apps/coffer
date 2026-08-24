import Foundation

/* The app's single source of truth for the history. All mutation goes
   through the pure `ClipboardHistory` model; observers (the panel) hear
   about real changes via NotificationCenter. */
final class ClipboardStore {
    static let changed = Notification.Name("Coffer.ClipboardStoreChanged")

    private(set) var items: [String] = []
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    func add(_ item: String) {
        let updated = ClipboardHistory.adding(item, to: items, limit: limit)
        guard updated != items else { return }
        items = updated
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
