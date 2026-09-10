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
