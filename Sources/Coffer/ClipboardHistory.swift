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
    static func adding(_ item: String, to history: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var result = history.filter { $0 != item }
        result.insert(item, at: 0)
        if result.count > limit {
            result.removeLast(result.count - limit)
        }
        return result
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
