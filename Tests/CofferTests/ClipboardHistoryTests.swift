import Testing

@testable import Coffer

@Test func newestCopyGoesFirst() {
    let history = ClipboardHistory.adding("b", to: ["a"], limit: 10)
    #expect(history == ["b", "a"])
}

@Test func recopyingTheCurrentItemIsANoOp() {
    let history = ClipboardHistory.adding("a", to: ["a", "b"], limit: 10)
    #expect(history == ["a", "b"])
}

@Test func recopyingAnOlderItemPromotesItWithoutDuplicating() {
    let history = ClipboardHistory.adding("c", to: ["a", "b", "c"], limit: 10)
    #expect(history == ["c", "a", "b"])
}

@Test func historyIsCappedByDroppingTheOldest() {
    let history = ClipboardHistory.adding("d", to: ["c", "b", "a"], limit: 3)
    #expect(history == ["d", "c", "b"])
}

@Test func nonPositiveLimitYieldsEmptyHistory() {
    #expect(ClipboardHistory.adding("a", to: ["b"], limit: 0) == [])
}

@Test func previewCollapsesWhitespaceRunsToSingleSpaces() {
    #expect(ClipboardHistory.previewLine(for: "  a\n\n  b\tc ") == "a b c")
}

@Test func previewIsCappedAtMaxLength() {
    let long = String(repeating: "x", count: 10)
    #expect(ClipboardHistory.previewLine(for: long, maxLength: 4) == "xxxx")
}
