import Foundation
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

@Test func filteringMatchesCaseInsensitiveSubstrings() {
    let items: [ClipboardItem] = [.text("Hello World"), .text("swift build"), .text("hello there")]
    #expect(
        ClipboardHistory.filtering(items, with: "hello")
            == [.text("Hello World"), .text("hello there")])
}

@Test func filteringKeepsOrderAndDropsNonMatches() {
    let items: [ClipboardItem] = [.text("b1"), .text("a"), .text("b2")]
    #expect(ClipboardHistory.filtering(items, with: "b") == [.text("b1"), .text("b2")])
}

@Test func emptyOrWhitespaceQueryMatchesEverything() {
    let items: [ClipboardItem] = [.text("a"), .image(Data([1])), .files([URL(fileURLWithPath: "/tmp/a.png")])]
    #expect(ClipboardHistory.filtering(items, with: "") == items)
    #expect(ClipboardHistory.filtering(items, with: "  \n") == items)
}

@Test func imagesNeverMatchATextQuery() {
    let items: [ClipboardItem] = [.text("image"), .image(Data([1]))]
    #expect(ClipboardHistory.filtering(items, with: "image") == [.text("image")])
}

@Test func fileCopiesMatchByFileName() {
    let report: ClipboardItem = .files([URL(fileURLWithPath: "/tmp/Report.pdf")])
    let items: [ClipboardItem] = [report, .text("unrelated")]
    #expect(ClipboardHistory.filtering(items, with: "report") == [report])
}

@Test func previewCollapsesWhitespaceRunsToSingleSpaces() {
    #expect(ClipboardHistory.previewLine(for: "  a\n\n  b\tc ") == "a b c")
}

@Test func previewIsCappedAtMaxLength() {
    let long = String(repeating: "x", count: 10)
    #expect(ClipboardHistory.previewLine(for: long, maxLength: 4) == "xxxx")
}
