import Foundation

/// The pure history model behind the clipboard store: newest-first ordering,
/// re-copy promotion, and a hard cap. The pasteboard watcher feeds copies
/// into this; keeping it pure keeps it testable.
enum ClipboardHistory {
    /// Returns `history` with `item` as the newest entry.
    ///
    /// Re-copying something already in the history moves it to the front
    /// instead of duplicating it (the classic clipboard-manager behavior,
    /// which also makes re-copying the current item a no-op). The result
    /// never exceeds `limit`; the oldest entries fall off.
    static func adding<Item: Equatable>(_ item: Item, to history: [Item], limit: Int) -> [Item] {
        guard limit > 0 else { return [] }
        var result = history.filter { $0 != item }
        result.insert(item, at: 0)
        if result.count > limit {
            result.removeLast(result.count - limit)
        }
        return result
    }

    /// Returns `history` capped at `limit` by dropping the oldest entries —
    /// what happens to an existing history when the cap is lowered in
    /// Settings.
    static func trimming<Item>(_ history: [Item], to limit: Int) -> [Item] {
        Array(history.prefix(max(limit, 0)))
    }

    /// Returns the items matching `query` (case- and diacritic-insensitive),
    /// preserving order: text by content, file copies by their names.
    /// Images only appear in an unfiltered list — they carry no text to
    /// search. An empty or whitespace-only query matches everything.
    static func filtering(_ items: [ClipboardItem], with query: String) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        func matches(_ text: String) -> Bool {
            text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return items.filter { item in
            switch item {
            case .text(let text): matches(text)
            case .image: false
            case .files(let urls): urls.contains { matches($0.lastPathComponent) }
            }
        }
    }

    /// Collapses an item to a single display line for the history list:
    /// runs of whitespace and newlines become one space, surrounding
    /// whitespace is trimmed, and the result is capped at `maxLength`.
    static func previewLine(for item: String, maxLength: Int = 300) -> String {
        let collapsed =
            item
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }
}
