import Foundation

/* Carries the history across launches. Binary plist, because image entries
   are raw PNG data: plists store Data natively, where JSON would inflate
   every image by a third with base64. */
struct HistoryPersistence {
    let fileURL: URL

    init(fileURL: URL = Self.defaultURL()) {
        self.fileURL = fileURL
    }

    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coffer", isDirectory: true)
            .appendingPathComponent("history.plist")
    }

    /// A missing or unreadable file (first launch, or a future format
    /// change) is an empty history, never an error. A file from before
    /// entries noted their app (a bare item list) loads with no sources.
    func load() -> [ClipboardStore.Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = PropertyListDecoder()
        if let entries = try? decoder.decode([ClipboardStore.Entry].self, from: data) {
            return entries
        }
        let items = (try? decoder.decode([ClipboardItem].self, from: data)) ?? []
        return items.map { ClipboardStore.Entry(item: $0, source: nil) }
    }

    func save(_ items: [ClipboardStore.Entry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try (try encoder.encode(items)).write(to: fileURL, options: .atomic)
            /* Clipboard contents are private by nature; keep the file
               owner-only even if the parent directory is ever laxer. */
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Coffer: history save failed: \(error)")
        }
    }
}
