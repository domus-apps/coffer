import Foundation
import Testing

@testable import Coffer

/* In-memory stores (no persistence) — the store's own behavior, not the
   file round-trip, which HistoryPersistence tests cover. */

@Test func clearingEmptiesTheHistoryAndNotifies() {
    let store = ClipboardStore(limit: 10)
    store.add(.text("a"))
    store.add(.text("b"))
    var changes = 0
    let observer = NotificationCenter.default.addObserver(
        forName: ClipboardStore.changed, object: store, queue: nil
    ) { _ in changes += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.clear()

    #expect(store.items.isEmpty)
    #expect(changes == 1)
}

@Test func clearingAnEmptyStoreIsSilent() {
    let store = ClipboardStore(limit: 10)
    var changes = 0
    let observer = NotificationCenter.default.addObserver(
        forName: ClipboardStore.changed, object: store, queue: nil
    ) { _ in changes += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    store.clear()

    #expect(store.items.isEmpty)
    #expect(changes == 0)
}

@Test func recopyingFromAnotherAppTakesThatAppWithoutDuplicating() {
    let store = ClipboardStore(limit: 10)
    store.add(.text("a"), source: "com.apple.Notes")
    store.add(.text("b"), source: "com.apple.Safari")
    store.add(.text("a"), source: "com.apple.TextEdit")
    #expect(store.items == [.text("a"), .text("b")])
    #expect(store.entries.map(\.source) == ["com.apple.TextEdit", "com.apple.Safari"])
}

/* Coffer's own re-copy carries no source: the item keeps the app it
   first came from. */
@Test func recopyingWithAnUnknownSourceKeepsTheKnownOne() {
    let store = ClipboardStore(limit: 10)
    store.add(.text("a"), source: "com.apple.Notes")
    store.add(.text("b"), source: "com.apple.Safari")
    store.add(.text("a"))
    #expect(store.items == [.text("a"), .text("b")])
    #expect(store.entries.first?.source == "com.apple.Notes")
}
